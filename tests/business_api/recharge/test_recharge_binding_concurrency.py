"""Real PostgreSQL 16 serialization of recharge submission and wallet rebinding.

Set SUPPORT_ORDER_POSTGRES_URL only to a disposable, migrated loopback test DB.
"""

import os
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from decimal import Decimal
from threading import Event
from time import monotonic
from types import SimpleNamespace
from uuid import uuid4

import pytest
from coincurve import PrivateKey
from sqlalchemy import create_engine, func, inspect, select, text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import sessionmaker

import app.main  # noqa: F401 - register the mapped application models
from app.core.errors import AppError
from app.core.idempotency import IdempotencyRecord
from app.core.outbox import OutboxEvent
from app.integrations.tron.message_signature import address_from_public_key
from app.modules.audit.models import AuditEvent
from app.modules.identity.models import User
from app.modules.ledger.service import LedgerService
from app.modules.recharge.models import RechargeRequest
from app.modules.recharge.service import RechargeService
from app.modules.wallet.binding import WalletBindingService
from app.modules.wallet.binding_models import WalletBindingState
from binding_fixture import seed_active_binding


@pytest.fixture
def pg_binding():
    raw_url = os.environ.get("SUPPORT_ORDER_POSTGRES_URL")
    if not raw_url:
        pytest.skip("explicit isolated PostgreSQL URL required")
    url = make_url(raw_url)
    assert url.drivername == "postgresql+psycopg"
    assert url.host in {"127.0.0.1", "localhost", "::1"}
    assert url.database and url.database.startswith("wallet_gate")
    engine = create_engine(raw_url, pool_size=10,
        connect_args={"options": "-c statement_timeout=15000"})
    try:
        assert inspect(engine).has_table("alembic_version"), "migrate disposable DB first"
        with engine.connect() as connection:
            assert 160000 <= int(connection.exec_driver_sql("SHOW server_version_num").scalar_one()) < 170000
        factory = sessionmaker(engine, expire_on_commit=False)
        now = datetime.now(timezone.utc)
        user_ids = ["pg-" + uuid4().hex[:24] for _ in range(2)]
        with factory.begin() as session:
            for user_id in user_ids:
                session.add(User(id=user_id, username=user_id, username_normalized=user_id,
                    password_hash="unused", status="ACTIVE", created_at=now, updated_at=now))
                seed_active_binding(session, user_id=user_id, now=now)
        recharge = RechargeService(factory, ledger=LedgerService(factory), now=lambda: now,
            official_config=SimpleNamespace(address="isolated-fixture-official", version="fixture-v1"))
        binding = WalletBindingService(factory, domain="wallet.example.test", clock=lambda: now)
        binding.address_registration_enabled = True
        yield engine, factory, recharge, binding, user_ids
    finally:
        engine.dispose()


def _counts(factory, user_id):
    with factory() as session:
        requests = session.scalar(select(func.count()).select_from(RechargeRequest).where(
            RechargeRequest.user_id == user_id))
        claims = session.scalar(select(func.count()).select_from(IdempotencyRecord).where(
            IdempotencyRecord.scope == "recharge.submit:" + user_id))
        audits = session.scalar(select(func.count()).select_from(AuditEvent).where(
            AuditEvent.actor_id == user_id, AuditEvent.action == "recharge.submitted"))
        outbox = sum(event.payload.get("user_id") == user_id for event in session.scalars(
            select(OutboxEvent).where(OutboxEvent.event_type == "recharge.submitted")))
        return requests, claims, audits, outbox


def _new_address():
    return address_from_public_key(PrivateKey().public_key.format(compressed=False))


def _register_pending(binding, user_id, key):
    return binding.register_address(user_id=user_id, session_id="isolated-pg-session",
        address=_new_address(), expected_version=1, idempotency_key=key)


def _submit(recharge, user_id, key):
    return recharge.submit(user_id=user_id, amount_usdt=Decimal("10"), idempotency_key=key)


def _blocking_pids(engine, waiter_pid):
    deadline = monotonic() + 10
    while monotonic() < deadline:
        with engine.connect() as connection:
            blockers = connection.scalar(text("SELECT pg_blocking_pids(:pid)"), {"pid": waiter_pid})
        if blockers:
            return blockers
    pytest.fail(f"PostgreSQL never reported a row-lock blocker for backend {waiter_pid}")


def test_order_lock_serializes_pending_rebind_after_commit(pg_binding):
    engine, factory, recharge, binding, (user_id, _) = pg_binding
    order_holds_state = Event()
    release_order = Event()
    rebind_attempting = Event()
    pids = {}
    original_gate = recharge.recharge_binding_gate.require_active
    original_lock = binding._lock

    def hold_after_gate(session, target_user):
        version = original_gate(session, target_user)
        pids["order"] = session.scalar(text("SELECT pg_backend_pid()"))
        order_holds_state.set()
        assert release_order.wait(10), "test did not release the order transaction"
        return version

    def observe_rebind(session, target_user):
        pids["rebind"] = session.scalar(text("SELECT pg_backend_pid()"))
        rebind_attempting.set()
        return original_lock(session, target_user)

    recharge.recharge_binding_gate.require_active = hold_after_gate
    binding._lock = observe_rebind
    with ThreadPoolExecutor(max_workers=2) as pool:
        order_future = pool.submit(_submit, recharge, user_id, "same-key")
        try:
            assert order_holds_state.wait(10)
            rebind_future = pool.submit(_register_pending, binding, user_id, "rebind-after")
            assert rebind_attempting.wait(10)
            assert pids["order"] in _blocking_pids(engine, pids["rebind"])
            assert _counts(factory, user_id) == (0, 0, 0, 0)
        finally:
            release_order.set()
        created = order_future.result(timeout=10)
        assert rebind_future.result(timeout=10)["status"] == "PENDING"

    recharge.recharge_binding_gate.require_active = original_gate
    assert _counts(factory, user_id) == (1, 1, 1, 1)
    with ThreadPoolExecutor(max_workers=2) as pool:
        replays = list(pool.map(lambda _: _submit(recharge, user_id, "same-key"), range(2)))
    assert all(replay["id"] == created["id"] for replay in replays)
    with pytest.raises(AppError) as denied:
        _submit(recharge, user_id, "new-after-pending")
    assert denied.value.code == "WALLET_BINDING_PENDING"
    assert _counts(factory, user_id) == (1, 1, 1, 1)


def test_pending_rebind_commit_fences_later_new_order(pg_binding):
    engine, factory, recharge, binding, (user_id, _) = pg_binding
    pending_staged = Event()
    release_rebind = Event()
    order_attempting = Event()
    pids = {}
    original_record = binding._record
    original_gate = recharge.recharge_binding_gate.require_active

    def hold_pending(session, *args):
        result = original_record(session, *args)
        pids["rebind"] = session.scalar(text("SELECT pg_backend_pid()"))
        pending_staged.set()
        assert release_rebind.wait(10), "test did not release the binding transaction"
        return result

    def observe_order(session, target_user):
        pids["order"] = session.scalar(text("SELECT pg_backend_pid()"))
        order_attempting.set()
        return original_gate(session, target_user)

    binding._record = hold_pending
    recharge.recharge_binding_gate.require_active = observe_order
    with ThreadPoolExecutor(max_workers=2) as pool:
        rebind_future = pool.submit(_register_pending, binding, user_id, "rebind-first")
        try:
            assert pending_staged.wait(10)
            order_future = pool.submit(_submit, recharge, user_id, "denied-key")
            assert order_attempting.wait(10)
            assert pids["rebind"] in _blocking_pids(engine, pids["order"])
            assert _counts(factory, user_id) == (0, 0, 0, 0)
        finally:
            release_rebind.set()
        assert rebind_future.result(timeout=10)["status"] == "PENDING"
        with pytest.raises(AppError) as denied:
            order_future.result(timeout=10)
    assert denied.value.code == "WALLET_BINDING_PENDING"
    assert denied.value.status_code == 409
    assert _counts(factory, user_id) == (0, 0, 0, 0)
    with factory() as session:
        assert session.get(WalletBindingState, user_id).pending_binding_id is not None


def test_same_key_is_account_scoped_and_cross_account_request_is_hidden(pg_binding):
    _, factory, recharge, _, (alice, bob) = pg_binding
    with ThreadPoolExecutor(max_workers=2) as pool:
        alice_future = pool.submit(_submit, recharge, alice, "shared-key")
        bob_future = pool.submit(_submit, recharge, bob, "shared-key")
        alice_order = alice_future.result(timeout=10)
        bob_order = bob_future.result(timeout=10)
    assert alice_order["id"] != bob_order["id"]
    assert {item["id"] for item in recharge.list_mine(user_id=alice)} == {alice_order["id"]}
    assert {item["id"] for item in recharge.list_mine(user_id=bob)} == {bob_order["id"]}
    assert _counts(factory, alice) == (1, 1, 1, 1)
    assert _counts(factory, bob) == (1, 1, 1, 1)
    with pytest.raises(AppError) as hidden:
        recharge.submit_evidence(request_id=alice_order["id"], user_id=bob,
            txid="a" * 64, idempotency_key="cross-account")
    assert hidden.value.status_code == 404
    assert hidden.value.code == "RECHARGE_NOT_FOUND"
    assert _counts(factory, alice) == (1, 1, 1, 1)
    assert _counts(factory, bob) == (1, 1, 1, 1)
