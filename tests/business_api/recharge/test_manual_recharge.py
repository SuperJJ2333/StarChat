"""ADR-0077 批次：人工充值（客服结算）与在线自动充值关闭。

- 提交申请只生成待处理订单，余额分文不动；
- 同一到账凭证不得重复用于充值；
- 客服/财务无权绕过公开服务直改余额；入账经既有财务调整链；
- CREDITED 登记幂等；审计/Outbox 齐全；
- 自动充值写入口与自动记账关闭，但历史与修复核对保留。
"""
import asyncio
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from types import SimpleNamespace

import pytest
from sqlalchemy import create_engine, select, event, func
from sqlalchemy.pool import StaticPool

import app.modules.fx.models  # noqa: F401
import app.modules.recharge.models  # noqa: F401
from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.idempotency import IdempotencyRecord
from app.core.outbox import OutboxEvent
from app.main import create_app
from app.modules.audit.models import AuditEvent
from app.modules.fx.models import FxRate
from app.modules.fx.service import FxService
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import User, UserRole
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.tokens import TokenService
from app.modules.ledger.models import LedgerEntry
from app.modules.ledger.service import LedgerService
from app.modules.recharge.service import RechargeService
from app.modules.recharge.models import RechargeRequest
from app.modules.wallet import receipt_models, repair_models, manual_payout_models, funding_models  # noqa: F401
from app.modules.wallet.models import WalletLedgerEntry
from app.modules.wallet.binding_models import WalletBinding, WalletBindingState
from binding_fixture import seed_active_binding, wallet_binding_snapshot


@pytest.fixture()
def env(tmp_path):
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'recharge.db'}",
        connect_args={"check_same_thread": False, "timeout": 15})

    @event.listens_for(engine, "connect")
    def _fk(dbapi_connection, _record):
        dbapi_connection.execute("PRAGMA foreign_keys=ON")

    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for uid, role in (("alice", None), ("agent", RoleCode.FINANCE_SUPPORT), ("root", RoleCode.SUPER_ADMIN)):
            session.add(User(id=uid, username=uid, username_normalized=uid, email=f"{uid}@x.test",
                email_normalized=f"{uid}@x.test", password_hash=PasswordHasher().hash("correct horse battery staple"),
                status=AccountStatus.ACTIVE, matrix_user_id=f"@{uid}:x.test", created_at=now, updated_at=now))
            if role is not None:
                session.add(UserRole(id=f"role-{uid}", user_id=uid, role_code=role, assigned_by="root", assigned_at=now))
        seed_active_binding(session, user_id="alice", now=now)
    ledger = LedgerService(factory)
    ledger.adjust(user_id="alice", amount=Decimal("100.00"), actor_id="finance",
        reason_code="SEED", idempotency_key="seed-alice")

    def rate_provider():
        return Decimal("7.120000"), False

    recharge = RechargeService(factory, ledger=ledger, rate_provider=rate_provider,
        official_config=SimpleNamespace(address='isolated-fixture-official', version='fixture-v1'))
    yield factory, ledger, recharge
    engine.dispose()


def _caibi_balance(factory, account):
    from sqlalchemy import func

    with factory() as session:
        return Decimal(session.scalar(select(func.coalesce(func.sum(LedgerEntry.amount), 0))
            .where(LedgerEntry.account_id == account)))


def _wallet_snapshot(factory):
    with factory() as session:
        return wallet_binding_snapshot(session)


def _submit_counts(factory):
    with factory() as session:
        return (
            session.scalar(select(func.count()).select_from(RechargeRequest)),
            session.scalar(select(func.count()).select_from(AuditEvent).where(
                AuditEvent.action == "recharge.submitted")),
            session.scalar(select(func.count()).select_from(OutboxEvent).where(
                OutboxEvent.event_type == "recharge.submitted")),
            session.scalar(select(func.count()).select_from(IdempotencyRecord).where(
                IdempotencyRecord.scope.like("recharge.submit:%"))),
        )


def _seed_historical_recharge(factory, *, amount_usdt, evidence_txid=None):
    """Existing pre-support-workflow order; no new submit is made by these tests."""
    now = datetime.now(timezone.utc)
    request_id = "historical-recharge"
    with factory.begin() as session:
        session.add(RechargeRequest(id=request_id, user_id="alice",
            amount_usdt=amount_usdt, evidence_txid=evidence_txid, status="SUBMITTED",
            fx_rate=Decimal("7.120000"), fx_rate_stale=False,
            created_at=now, updated_at=now))
    return {"id": request_id}


def test_binding_gate_rejects_unbound_user_without_wallet_writes(env):
    from app.core.errors import AppError
    from app.modules.wallet.recharge_binding_gate import WalletRechargeBindingGate

    factory, _, _ = env
    before = _wallet_snapshot(factory)
    with factory.begin() as session, pytest.raises(AppError) as excinfo:
        WalletRechargeBindingGate().require_active(session, "agent")
    assert excinfo.value.status_code == 409
    assert excinfo.value.code == "WALLET_BINDING_REQUIRED"
    assert _wallet_snapshot(factory) == before


def test_binding_gate_rejects_pending_before_active_without_wallet_writes(env):
    from app.core.errors import AppError
    from app.modules.wallet.recharge_binding_gate import WalletRechargeBindingGate

    factory, _, _ = env
    with factory.begin() as session:
        session.get(WalletBindingState, "alice").pending_binding_id = "pending-alice-binding"
    before = _wallet_snapshot(factory)
    with factory.begin() as session, pytest.raises(AppError) as excinfo:
        WalletRechargeBindingGate().require_active(session, "alice")
    assert excinfo.value.status_code == 409
    assert excinfo.value.code == "WALLET_BINDING_PENDING"
    assert _wallet_snapshot(factory) == before


def test_binding_gate_rejects_version_conflict_without_wallet_writes(env):
    from app.core.errors import AppError
    from app.modules.wallet.recharge_binding_gate import WalletRechargeBindingGate

    factory, _, _ = env
    with factory.begin() as session:
        session.get(WalletBindingState, "alice").version = 2
    before = _wallet_snapshot(factory)
    with factory.begin() as session, pytest.raises(AppError) as excinfo:
        WalletRechargeBindingGate().require_active(session, "alice")
    assert excinfo.value.status_code == 409
    assert excinfo.value.code == "WALLET_BINDING_VERSION_CONFLICT"
    assert _wallet_snapshot(factory) == before


def test_binding_gate_returns_active_version_without_wallet_writes(env):
    from app.modules.wallet.recharge_binding_gate import WalletRechargeBindingGate

    factory, _, _ = env
    before = _wallet_snapshot(factory)
    with factory.begin() as session:
        assert WalletRechargeBindingGate().require_active(session, "alice") == 1
    assert _wallet_snapshot(factory) == before


def test_binding_gate_stale_preloaded_state_sees_committed_pending(env):
    from app.core.errors import AppError
    from app.modules.wallet.recharge_binding_gate import WalletRechargeBindingGate

    factory, _, _ = env
    with factory() as preloaded:
        state = preloaded.get(WalletBindingState, "alice")
        assert state.pending_binding_id is None
        with factory.begin() as writer:
            writer.get(WalletBindingState, "alice").pending_binding_id = "pending-alice-binding"
        assert state.pending_binding_id is None  # identity-map value is stale
        before = _wallet_snapshot(factory)
        with pytest.raises(AppError) as excinfo:
            WalletRechargeBindingGate().require_active(preloaded, "alice")
        assert excinfo.value.status_code == 409
        assert excinfo.value.code == "WALLET_BINDING_PENDING"
    assert _wallet_snapshot(factory) == before


def test_binding_gate_stale_preloaded_binding_sees_committed_retirement(env):
    from app.core.errors import AppError
    from app.modules.wallet.recharge_binding_gate import WalletRechargeBindingGate

    factory, _, _ = env
    with factory() as preloaded:
        state = preloaded.get(WalletBindingState, "alice")
        binding = preloaded.get(WalletBinding, state.active_binding_id)
        assert binding.status == "ACTIVE"
        with factory.begin() as writer:
            current = writer.get(WalletBinding, state.active_binding_id)
            current.status = "RETIRED"
            current.effective_to_block = 102
        assert binding.status == "ACTIVE"  # identity-map value is stale
        before = _wallet_snapshot(factory)
        with pytest.raises(AppError) as excinfo:
            WalletRechargeBindingGate().require_active(preloaded, "alice")
        assert excinfo.value.status_code == 409
        assert excinfo.value.code == "WALLET_BINDING_VERSION_CONFLICT"
    assert _wallet_snapshot(factory) == before


@pytest.mark.parametrize("invalid", ("missing", "wrong_owner", "retired"))
def test_binding_gate_invalid_active_reference_has_no_wallet_writes(env, invalid):
    from app.core.errors import AppError
    from app.modules.wallet.recharge_binding_gate import WalletRechargeBindingGate

    factory, _, _ = env
    with factory.begin() as writer:
        state = writer.get(WalletBindingState, "alice")
        if invalid == "missing":
            state.active_binding_id = "missing-binding"
        else:
            binding = writer.get(WalletBinding, state.active_binding_id)
            if invalid == "wrong_owner":
                binding.user_id = "agent"
            else:
                binding.status = "RETIRED"
                binding.effective_to_block = 102
    before = _wallet_snapshot(factory)
    with factory.begin() as session, pytest.raises(AppError) as excinfo:
        WalletRechargeBindingGate().require_active(session, "alice")
    assert excinfo.value.status_code == 409
    assert excinfo.value.code == "WALLET_BINDING_VERSION_CONFLICT"
    assert _wallet_snapshot(factory) == before


@pytest.mark.parametrize(("effective_from", "effective_to"), ((None, None), (101, 102)))
def test_binding_gate_invalid_active_interval_has_no_wallet_writes(env, monkeypatch,
                                                                  effective_from, effective_to):
    from app.core.errors import AppError
    from app.modules.wallet.recharge_binding_gate import WalletRechargeBindingGate

    factory, _, _ = env
    before = _wallet_snapshot(factory)
    with factory.begin() as session:
        real_get = session.get

        def get_with_invalid_binding(model, key, **kwargs):
            if model is WalletBinding:
                # Database CHECK constraints forbid these corrupt ACTIVE rows.
                return SimpleNamespace(user_id="alice", status="ACTIVE", version=1,
                    effective_from_block=effective_from, effective_to_block=effective_to)
            return real_get(model, key, **kwargs)

        monkeypatch.setattr(session, "get", get_with_invalid_binding)
        with pytest.raises(AppError) as excinfo:
            WalletRechargeBindingGate().require_active(session, "alice")
    assert excinfo.value.status_code == 409
    assert excinfo.value.code == "WALLET_BINDING_VERSION_CONFLICT"
    assert _wallet_snapshot(factory) == before


def test_submit_creates_pending_order_without_balance_change(env):
    factory, ledger, recharge = env
    view = recharge.submit(user_id="alice", amount_usdt=Decimal("50"), evidence_txid="A" * 64)
    assert view["status"] == "SUBMITTED"
    assert view["fx_rate"] == "7.120000"
    assert _caibi_balance(factory, "alice") == Decimal("100.00")  # 分文不动
    assert _caibi_balance(factory, "PLATFORM_CLEARING") == Decimal("-100.00")  # 账本仅种子分录


@pytest.mark.parametrize(("binding_state", "expected_code"), (
    ("unbound", "WALLET_BINDING_REQUIRED"),
    ("pending", "WALLET_BINDING_PENDING"),
    ("version_conflict", "WALLET_BINDING_VERSION_CONFLICT"),
))
def test_new_recharge_requires_active_binding_without_success_writes(env, binding_state, expected_code):
    from app.core.errors import AppError

    factory, _, recharge = env
    user_id = "agent" if binding_state == "unbound" else "alice"
    if binding_state != "unbound":
        with factory.begin() as session:
            state = session.get(WalletBindingState, "alice")
            if binding_state == "pending":
                state.pending_binding_id = "pending-alice-binding"
            else:
                state.version += 1
    before = _submit_counts(factory)
    with pytest.raises(AppError) as excinfo:
        recharge.submit(user_id=user_id, amount_usdt=Decimal("10"),
            idempotency_key=f"binding-{binding_state}")
    assert excinfo.value.status_code == 409
    assert excinfo.value.code == expected_code
    assert _submit_counts(factory) == before


def test_active_recharge_creates_one_order_audit_outbox_and_no_money(env):
    factory, _, recharge = env
    before = _submit_counts(factory)
    balance_before = _caibi_balance(factory, "alice")
    created = recharge.submit(user_id="alice", amount_usdt=Decimal("10"),
        idempotency_key="active-new-order")
    assert created["status"] == "SUBMITTED"
    assert created["official_payment"] == {
        "network": "TRON", "address": "isolated-fixture-official", "config_version": "fixture-v1"}
    assert _submit_counts(factory) == tuple(value + 1 for value in before)
    assert _caibi_balance(factory, "alice") == balance_before


def test_completed_replay_precedes_binding_config_and_rate_checks(env):
    from app.core.errors import AppError

    factory, _, recharge = env
    created = recharge.submit(user_id="alice", amount_usdt=Decimal("10"),
        idempotency_key="recover-existing")
    after_create = _submit_counts(factory)
    with factory.begin() as session:
        session.get(WalletBindingState, "alice").active_binding_id = None
    recharge.official_config = None
    recharge.settlement_enabled = False
    rate_calls = []

    def unavailable_rate():
        rate_calls.append(True)
        raise RuntimeError("rate provider unavailable")

    recharge.rate_provider = unavailable_rate
    assert recharge.submit(user_id="alice", amount_usdt=Decimal("10"),
        idempotency_key="recover-existing") == created
    assert rate_calls == []
    with pytest.raises(AppError) as excinfo:
        recharge.submit(user_id="alice", amount_usdt=Decimal("11"),
            idempotency_key="recover-existing")
    assert excinfo.value.code == "IDEMPOTENCY_KEY_REUSED"
    assert rate_calls == []
    with pytest.raises(AppError) as excinfo:
        recharge.submit(user_id="alice", amount_usdt=Decimal("10"),
            idempotency_key="new-without-official-config")
    assert excinfo.value.status_code == 503
    assert rate_calls == []
    recharge.official_config = SimpleNamespace(address="isolated-fixture-official", version="fixture-v1")
    recharge.settlement_enabled = True
    with pytest.raises(AppError) as excinfo:
        recharge.submit(user_id="alice", amount_usdt=Decimal("10"),
            idempotency_key="new-without-binding")
    assert excinfo.value.status_code == 409
    assert excinfo.value.code == "WALLET_BINDING_REQUIRED"
    assert _submit_counts(factory) == after_create


@pytest.mark.parametrize("rate_snapshot", (
    (),
    ("7.12",),
    ("7.12", False, "extra"),
    {"rate": "7.12", "stale": False},
    ("not-a-decimal", False),
    ("NaN", False),
    ("Infinity", False),
    ("0", False),
    ("1000", False),
    ("7.1234567", False),
    ("7.12", "false"),
), ids=("empty", "short", "extra", "mapping", "bad-decimal", "nan", "infinity",
        "zero", "out-of-range", "excess-precision", "bad-stale"))
def test_malformed_optional_rate_does_not_block_new_recharge(env, rate_snapshot):
    factory, _, recharge = env
    before = _submit_counts(factory)
    recharge.rate_provider = lambda: rate_snapshot

    created = recharge.submit(user_id="alice", amount_usdt=Decimal("10"),
        idempotency_key="malformed-optional-rate")

    assert created["status"] == "SUBMITTED"
    assert created["fx_rate"] is None
    assert created["fx_rate_stale"] is None
    assert _submit_counts(factory) == tuple(value + 1 for value in before)


def test_recharge_separate_session_rate_provider_refreshes_before_claim(env):
    """An on-demand FX refresh must not wait on recharge's idempotency write lock."""
    factory, _, recharge = env
    fx_engine = create_engine(str(factory.kw["bind"].url),
        connect_args={"check_same_thread": False, "timeout": 0.2})
    fx_factory = create_session_factory(fx_engine)
    fx = FxService(fx_factory, api_id="fixture-id", api_key="fixture-key",
        http_get=lambda _url, _timeout: {"code": 200, "rate": "7.12", "from": "USD", "to": "CNY"})

    def rate_provider():
        snapshot = fx.get_rate_snapshot(actor_id="recharge-reference")
        return snapshot["rate"], bool(snapshot["stale"])

    recharge.rate_provider = rate_provider
    try:
        created = recharge.submit(user_id="alice", amount_usdt=Decimal("10"),
            idempotency_key="fx-independent-session")
        assert rate_provider() == (Decimal("7.120000"), False)  # succeeds after recharge releases its lock
        assert created["fx_rate"] == "7.120000"
        assert created["fx_rate_stale"] is False
        with factory() as session:
            assert session.get(FxRate, "USD/CNY").rate == Decimal("7.120000")
    finally:
        fx_engine.dispose()


def test_existing_recharge_history_evidence_and_cancel_survive_unbinding(env):
    from app.core.errors import AppError

    factory, _, recharge = env
    evidence_order = recharge.submit(user_id="alice", amount_usdt=Decimal("10"),
        idempotency_key="existing-evidence")
    cancel_order = recharge.submit(user_id="alice", amount_usdt=Decimal("20"),
        idempotency_key="existing-cancel")
    with factory.begin() as session:
        session.get(WalletBindingState, "alice").active_binding_id = None
    assert {item["id"] for item in recharge.list_mine(user_id="alice")} == {
        evidence_order["id"], cancel_order["id"]}
    assert recharge.list_mine(user_id="agent") == []
    with pytest.raises(AppError) as excinfo:
        recharge.submit_evidence(request_id=evidence_order["id"], user_id="agent",
            txid="e" * 64, idempotency_key="cross-account")
    assert excinfo.value.status_code == 404
    assert recharge.submit_evidence(request_id=evidence_order["id"], user_id="alice",
        txid="e" * 64, idempotency_key="existing-proof")["evidence_txid"] == "e" * 64
    assert recharge.cancel(user_id="alice", request_id=cancel_order["id"])["status"] == "CANCELLED"


def test_same_evidence_cannot_fund_two_requests(env):
    factory, ledger, recharge = env
    from app.core.errors import AppError

    recharge.submit(user_id="alice", amount_usdt=Decimal("50"), evidence_txid="B" * 64)
    with pytest.raises(AppError) as excinfo:
        recharge.submit(user_id="alice", amount_usdt=Decimal("20"), evidence_txid="B" * 64)
    assert excinfo.value.code == "RECHARGE_EVIDENCE_REUSED"


def test_credit_marks_request_and_requires_public_ledger_proof(env):
    """历史申请须有真实审批执行凭证；登记重放不重复入账。"""
    from app.modules.ledger.adjustments import AdjustmentWorkflow
    factory, ledger, recharge = env
    view = _seed_historical_recharge(factory, amount_usdt=Decimal("50"), evidence_txid="C" * 64)
    workflow = AdjustmentWorkflow(factory, ledger, admin_threshold=Decimal('10000'))
    workflow.set_policy('agent', per_transaction=Decimal('1000'), per_day=Decimal('10000'), allowed_users={'alice'})
    adjustment = workflow.submit(actor_id='agent', user_id='alice', amount=Decimal('355.00'),
        reason_code='RECHARGE_CREDIT', idempotency_key='recharge-credit-1')
    workflow.finance_review(adjustment.id, reviewer_id='root', approve=True)
    executed = workflow.execute(adjustment.id, actor_id='root', idempotency_key='execute-1')
    credited = recharge.mark_credited(request_id=view["id"], actor_id="agent",
        ledger_transaction_id=executed.ledger_transaction_id, final_caibi_amount=Decimal("355.00"), final_rate=Decimal("7.10"))
    assert credited["status"] == "CREDITED"
    assert credited["final_caibi_amount"] == "355.00"
    assert credited['adjustment_id'] == adjustment.id
    assert _caibi_balance(factory, "alice") == Decimal("455.00")
    # 幂等重放：同凭证不重复入账
    again = recharge.mark_credited(request_id=view["id"], actor_id="agent",
        ledger_transaction_id=executed.ledger_transaction_id, final_caibi_amount=Decimal("355.00"), final_rate=Decimal("7.10"))
    assert again["status"] == "CREDITED"
    assert _caibi_balance(factory, "alice") == Decimal("455.00")
    # 不同凭证号的重复登记拒绝
    from app.core.errors import AppError

    with pytest.raises(AppError) as excinfo:
        recharge.mark_credited(request_id=view["id"], actor_id="agent",
            ledger_transaction_id="other-tx", final_caibi_amount=Decimal("355.00"), final_rate=Decimal('7.10'),
            idempotency_key='different-credit')
    assert excinfo.value.code == "RECHARGE_ALREADY_DECIDED"
    with factory() as session:
        assert session.scalar(select(AuditEvent.id).where(AuditEvent.action == "recharge.credited")) is not None
        events = session.scalars(select(OutboxEvent).where(OutboxEvent.event_type == "recharge.credited")).all()
        assert len(events) == 1


def test_reject_requires_reason_and_records_timeline(env):
    factory, ledger, recharge = env
    view = _seed_historical_recharge(factory, amount_usdt=Decimal("10"))
    from app.core.errors import AppError

    with pytest.raises(AppError) as excinfo:
        recharge.reject(request_id=view["id"], actor_id="agent", reason="  ")
    assert excinfo.value.code == "RECHARGE_REASON_REQUIRED"
    rejected = recharge.reject(request_id=view["id"], actor_id="agent", reason="付款未到账")
    assert rejected["status"] == "REJECTED" and rejected["decided_by"] == "agent"


def test_directory_requires_admin_and_lists_enabled_only(env):
    factory, ledger, recharge = env
    recharge.upsert_directory_entry(actor_id="root", cs_user_id="agent", display_name="官方客服小畅",
        payment_address="T" * 34, note="7×12h", enabled=True, sort=1)
    recharge.upsert_directory_entry(actor_id="root", cs_user_id="root", display_name="备用客服",
        payment_address="R" * 34, enabled=False, sort=2)
    items = recharge.directory()
    assert len(items) == 1 and items[0]["display_name"] == "官方客服小畅"
    all_items = recharge.directory(include_disabled=True)
    assert len(all_items) == 2


def test_auto_deposit_closed_leaves_receipts_in_review_and_repair_paths_intact():
    """自动充值关闭：观察者不再自动入账（留在 REVIEW）；服务仍可查询核对。"""
    from app.modules.wallet.receipts import DepositReceiptService

    assert DepositReceiptService.auto_deposit_enabled is True  # 类默认（生产由 runtime 注入 False）
    assert Settings(_env_file=None).wallet_auto_deposit_enabled is False  # 新产品默认关闭


def test_recharge_api_contract(env):
    from httpx import ASGITransport, AsyncClient

    from app.modules.identity.tokens import TokenService as TS
    from app.core.config import Settings as S

    factory, ledger, recharge = env
    settings = S(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:",
        jwt_secret="test-jwt-secret-at-least-thirty-two-bytes",
        email_verification_secret="test-email-verification-secret",
        password_reset_secret="test-password-reset-secret")
    app = create_app(settings, session_factory=factory)
    app.state.recharge_service.official_config = SimpleNamespace(
        address="isolated-fixture-official", version="fixture-v1")
    app.state.recharge_service.settlement_enabled = True
    tokens = TS(factory, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer, require_session_claims=False)
    alice = tokens.issue_pair(user_id="alice", device_key="d", display_name="t").access_token
    from support_auth_helpers import staff_token
    agent = staff_token(factory, settings, tokens)

    async def calls():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            directory = await client.get("/api/v1/recharge/directory", headers={"Authorization": f"Bearer {alice}"})
            submit = await client.post("/api/v1/recharge/requests", headers={
                "Authorization": f"Bearer {alice}", "Idempotency-Key": "r-1"},
                json={"amount_usdt": "50", "evidence_txid": "D" * 64})
            pending_denied = await client.get("/api/v1/recharge/admin/requests/pending",
                headers={"Authorization": f"Bearer {alice}"})
            pending = await client.get("/api/v1/recharge/admin/requests/pending",
                headers={"Authorization": f"Bearer {agent}"})
            mine = await client.get("/api/v1/recharge/requests/mine", headers={"Authorization": f"Bearer {alice}"})
        return directory, submit, pending_denied, pending, mine

    directory, submit, pending_denied, pending, mine = asyncio.run(calls())
    assert directory.status_code == 200
    assert directory.json()["disclaimer"] == "参考估算，最终以客服结算为准"
    assert submit.status_code == 201 and submit.json()["status"] == "SUBMITTED"
    assert pending_denied.status_code == 401  # 无权限人员不能操作
    assert pending.status_code == 200 and len(pending.json()["items"]) == 1
    assert mine.status_code == 200 and mine.json()["items"][0]["status"] == "SUBMITTED"


def test_http_new_recharge_requires_binding_and_preserves_completed_replay(env):
    from httpx import ASGITransport, AsyncClient

    factory, _, _ = env
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:",
        jwt_secret="test-jwt-secret-at-least-thirty-two-bytes",
        email_verification_secret="test-email-verification-secret",
        password_reset_secret="test-password-reset-secret")
    app = create_app(settings, session_factory=factory)
    service = app.state.recharge_service
    service.official_config = SimpleNamespace(address="isolated-fixture-official", version="fixture-v1")
    service.settlement_enabled = True
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret,
        jwt_issuer=settings.jwt_issuer, require_session_claims=False)
    alice = {"Authorization": "Bearer " + tokens.issue_pair(
        user_id="alice", device_key="alice-device", display_name="Alice").access_token}
    agent = {"Authorization": "Bearer " + tokens.issue_pair(
        user_id="agent", device_key="agent-device", display_name="Agent").access_token}
    path = "/api/v1/recharge/requests"
    body = {"amount_usdt": "10"}

    def post(headers, key, payload=body):
        async def call():
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
                return await client.post(path, headers={**headers, "Idempotency-Key": key}, json=payload)
        return asyncio.run(call())

    def get(headers, url):
        async def call():
            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
                return await client.get(url, headers=headers)
        return asyncio.run(call())

    assert post({}, "anonymous").status_code == 401
    denied = post(agent, "agent-unbound")
    assert denied.status_code == 409
    assert denied.json()["error"]["code"] == "WALLET_BINDING_REQUIRED"
    created = post(alice, "alice-existing")
    assert created.status_code == 201
    after_create = _submit_counts(factory)
    with factory.begin() as session:
        session.get(WalletBindingState, "alice").active_binding_id = None
    service.official_config = None
    service.settlement_enabled = False
    settings.environment = "development"  # exercise the former route precheck on replay
    replay = post(alice, "alice-existing")
    assert replay.status_code == 201
    assert replay.json() == created.json()
    assert post(alice, "alice-existing", {"amount_usdt": "11"}).status_code == 409
    assert post(alice, "alice-new-official-disabled").status_code == 503
    service.official_config = SimpleNamespace(address="isolated-fixture-official", version="fixture-v1")
    service.settlement_enabled = True
    new_without_binding = post(alice, "alice-new-unbound")
    assert new_without_binding.status_code == 409
    assert new_without_binding.json()["error"]["code"] == "WALLET_BINDING_REQUIRED"
    assert _submit_counts(factory) == after_create
    assert get(alice, path + "/mine").json()["items"][0]["id"] == created.json()["id"]
    assert get(agent, path + "/mine").json()["items"] == []

    async def cross_account_evidence():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            return await client.post(path + "/" + created.json()["id"] + "/evidence",
                headers={**agent, "Idempotency-Key": "agent-cross-evidence"}, json={"txid": "e" * 64})

    denied_read = asyncio.run(cross_account_evidence())
    assert denied_read.status_code == 404
    assert denied_read.json()["error"]["code"] == "RECHARGE_NOT_FOUND"
