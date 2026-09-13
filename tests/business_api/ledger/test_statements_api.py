from datetime import datetime, timedelta, timezone
from decimal import Decimal

import jwt
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.ledger.service import LedgerService
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.transfer.service import ChatTransferService
from app.modules.wallet.service import WalletLedger
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.profile import ProfileService
from app.modules.ledger.statements import StatementService


@pytest.fixture()
def context():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:", redis_url="redis://localhost:6379/15", jwt_secret="r" * 32, totp_issuer="六合通")
    ledger = LedgerService(factory)
    ledger.adjust(user_id="alice", amount=Decimal("100.00"), actor_id="finance", reason_code="INITIAL_CREDIT", idempotency_key="statement-seed")
    yield create_app(settings, session_factory=factory), factory, settings, ledger
    engine.dispose()


def bearer(settings, user_id):
    now = datetime.now(timezone.utc)
    token = jwt.encode({"sub": user_id, "iss": settings.jwt_issuer, "iat": int(now.timestamp()), "exp": int((now + timedelta(minutes=5)).timestamp())}, settings.jwt_secret, algorithm="HS256")
    return {"Authorization": f"Bearer {token}"}


@pytest.mark.asyncio
async def test_statement_projects_only_authorized_counterparty_public_identity(context):
    app, factory, settings, ledger = context
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for user_id, username, nickname in [
            ("alice", "alice", "Alice"), ("bob", "bob-account", "Bob"),
            ("mallory", "mallory", "Mallory"),
        ]:
            session.add(User(id=user_id, username=username,
                username_normalized=username, email=f"{username}@test.invalid",
                email_normalized=f"{username}@test.invalid", password_hash="x",
                status=AccountStatus.ACTIVE, matrix_user_id=f"@{username}:test",
                nickname=nickname, created_at=now, updated_at=now,
                profile_updated_at=now,
                avatar_object_key=("avatars/bob/avatar.png" if user_id == "bob" else None)))
    visible = ledger.post(entries={"alice": Decimal("-2.00"), "bob": Decimal("2.00")}, actor_id="alice", reason_code="USER_TRANSFER", idempotency_key="identity-visible", scope="caibi.transfer")
    ledger.adjust(user_id="mallory", amount=Decimal("3.00"), actor_id="finance", reason_code="IDENTITY_TEST_SEED", idempotency_key="identity-mallory-seed")
    hidden = ledger.post(entries={"mallory": Decimal("-3.00"), "bob": Decimal("3.00")}, actor_id="mallory", reason_code="USER_TRANSFER", idempotency_key="identity-hidden", scope="caibi.transfer")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(f"/api/v1/ledger/transactions/me/{visible.id}", headers=bearer(settings, "alice"))
        assert response.status_code == 200
        assert response.json()["counterparty_nickname"] == "Bob"
        assert response.json()["counterparty_username"] == "bob-account"
        assert "counterparty_remark" not in response.json()
        assert (await client.get(f"/api/v1/ledger/transactions/me/{hidden.id}", headers=bearer(settings, "alice"))).status_code == 404


def test_statement_counterparty_names_do_not_require_avatar_storage(context):
    _app, factory, _settings, ledger = context
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add_all([
            User(id="alice", username="alice", username_normalized="alice",
                email="alice@test.invalid", email_normalized="alice@test.invalid",
                password_hash="x", status=AccountStatus.ACTIVE, nickname="Alice",
                created_at=now, updated_at=now, profile_updated_at=now),
            User(id="bob", username="bob-account", username_normalized="bob-account",
                email="bob@test.invalid", email_normalized="bob@test.invalid",
                password_hash="x", status=AccountStatus.ACTIVE, nickname="Bob",
                avatar_object_key="avatars/bob/avatar.png", created_at=now,
                updated_at=now, profile_updated_at=now),
        ])
    transaction = ledger.post(
        entries={"alice": Decimal("-2.00"), "bob": Decimal("2.00")},
        actor_id="alice", reason_code="USER_TRANSFER",
        idempotency_key="identity-no-avatar-storage", scope="caibi.transfer")

    detail = StatementService(
        factory, profile_reader=ProfileService(factory, storage=None)).get(
            user_id="alice", transaction_id=transaction.id)

    assert detail["counterparty_nickname"] == "Bob"
    assert detail["counterparty_username"] == "bob-account"


@pytest.mark.asyncio
async def test_my_statement_is_caibi_scoped_filterable_and_private(context):
    app, _factory, settings, ledger = context
    redpacket = ledger.post(entries={"alice": Decimal("-3.00"), "PLATFORM_REDPACKET_ESCROW:test": Decimal("3.00")}, actor_id="alice", reason_code="RED_PACKET_CREATE", idempotency_key="statement-red", scope="redpacket.create")
    transfer = ledger.post(entries={"alice": Decimal("-5.05"), "bob": Decimal("5.00"), "PLATFORM_FEE": Decimal("0.05")}, actor_id="alice", reason_code="USER_TRANSFER", idempotency_key="statement-transfer", scope="caibi.transfer")
    deposit = ledger.post(entries={"alice": Decimal("1.00"), "PLATFORM_CLEARING": Decimal("-1.00")}, actor_id="alice", reason_code="USDT_TO_CAIBI", idempotency_key="statement-deposit", scope="wallet.conversion")
    withdrawal = ledger.post(entries={"alice": Decimal("-1.00"), "PLATFORM_CLEARING": Decimal("1.00")}, actor_id="alice", reason_code="CAIBI_TO_USDT", idempotency_key="statement-withdrawal", scope="wallet.conversion")
    unknown = ledger.post(entries={"alice": Decimal("1.00"), "PLATFORM_CLEARING": Decimal("-1.00")}, actor_id="alice", reason_code="UNKNOWN_CONVERSION", idempotency_key="statement-unknown", scope="wallet.conversion")
    reversal = ledger.post(entries={"alice": Decimal("1.00"), "PLATFORM_CLEARING": Decimal("-1.00")}, actor_id="alice", reason_code="MANUAL_PAYOUT_CANCELLED", idempotency_key="statement-reversal", scope="wallet.conversion_reversal", reversal_of_id=withdrawal.id)
    ledger.post(entries={"mallory": Decimal("10.00"), "PLATFORM_CLEARING": Decimal("-10.00")}, actor_id="finance", reason_code="OTHER_USER", idempotency_key="statement-other", scope="ledger.adjustment")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        page = await client.get("/api/v1/ledger/transactions/me?kind=transfer&q=USER", headers=bearer(settings, "alice"))
        assert page.status_code == 200
        assert page.headers["cache-control"] == "private, no-store"
        assert [item["id"] for item in page.json()["items"]] == [transfer.id]
        assert page.json()["items"][0]["amount"] == "-5.05"
        assert page.json()["items"][0]["kind"] == "transfer"
        assert (await client.get(f"/api/v1/ledger/transactions/me/{redpacket.id}", headers=bearer(settings, "alice"))).status_code == 200
        assert (await client.get(f"/api/v1/ledger/transactions/me/{redpacket.id}", headers=bearer(settings, "mallory"))).status_code == 404
        assert (await client.get("/api/v1/ledger/transactions/me?cursor=bad", headers=bearer(settings, "alice"))).status_code == 422
        assert (await client.get("/api/v1/ledger/transactions/me?limit=101", headers=bearer(settings, "alice"))).status_code == 422
        assert (await client.get("/api/v1/ledger/transactions/me?start_at=2026-01-02T00:00:00Z&end_at=2026-01-01T00:00:00Z", headers=bearer(settings, "alice"))).status_code == 422
        assert (await client.get("/api/v1/ledger/transactions/me?start_at=2026-01-01T00:00:00&end_at=2026-01-02T00:00:00Z", headers=bearer(settings, "alice"))).status_code == 422
        type_search = await client.get("/api/v1/ledger/transactions/me?q=转账", headers=bearer(settings, "alice"))
        assert [item["id"] for item in type_search.json()["items"]] == [transfer.id]
        assert (await client.get("/api/v1/ledger/transactions/me?kind=deposit", headers=bearer(settings, "alice"))).json()["items"][0]["id"] == deposit.id
        withdrawal_items = (await client.get("/api/v1/ledger/transactions/me?kind=withdrawal", headers=bearer(settings, "alice"))).json()["items"]
        assert {item["id"] for item in withdrawal_items} == {withdrawal.id, reversal.id}
        all_items = (await client.get("/api/v1/ledger/transactions/me", headers=bearer(settings, "alice"))).json()["items"]
        by_id = {item["id"]: item for item in all_items}
        assert by_id[unknown.id]["kind"] == "other"
        assert by_id[reversal.id]["kind"] == "withdrawal"
        assert by_id[reversal.id]["reversal_of_id"] == withdrawal.id


def test_transfer_snapshot_uses_actual_participant_ledger_bill(context):
    _app, factory, _settings, ledger = context
    service = ChatTransferService(factory, ledger)
    transfer = service.create(sender_id="alice", receiver_id="bob", amount=Decimal("10.00"), note="lunch", room_id=None, idempotency_key="statement-chat", expires_at=datetime.now(timezone.utc) + timedelta(hours=1))
    sender = service.detail(transfer.id, user_id="alice")
    sender_bill = sender["bill_id"]
    assert sender_bill
    assert service.detail(transfer.id, user_id="bob")["bill_id"] is None
    service.accept(transfer.id, user_id="bob", idempotency_key="statement-chat-accept")
    received = service.detail(transfer.id, user_id="bob")
    assert received["accepted_at"] is not None
    assert received["bill_id"]
    assert service.detail(transfer.id, user_id="alice")["bill_id"] == sender_bill
    with pytest.raises(ValueError, match="not visible"):
        service.detail(transfer.id, user_id="mallory")


@pytest.mark.asyncio
async def test_statement_search_and_range(context):
    app, factory, settings, ledger = context
    service = ChatTransferService(factory, ledger)
    transfer = service.create(sender_id="alice", receiver_id="bob", amount=Decimal("10.00"), note="红包餐费50%_A", room_id=None, idempotency_key="search-chat", expires_at=datetime.now(timezone.utc) + timedelta(hours=1))
    ordinary = ChatTransferService(factory, ledger).create(sender_id="alice", receiver_id="carol", amount=Decimal("2.00"), note="ordinary", room_id=None, idempotency_key="search-ordinary", expires_at=datetime.now(timezone.utc) + timedelta(hours=1))
    bill_id = service.detail(transfer.id, user_id="alice")["bill_id"]
    ordinary_bill_id = ChatTransferService(factory, ledger).detail(ordinary.id, user_id="alice")["bill_id"]
    with factory() as session:
        created = session.get(LedgerTransaction, bill_id).created_at
        end = session.get(LedgerTransaction, ordinary_bill_id).created_at
    created = created.replace(tzinfo=timezone.utc)
    end = end.replace(tzinfo=timezone.utc)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        for query in ("红包", "%_", bill_id):
            result = await client.get("/api/v1/ledger/transactions/me", params={"q": query}, headers=bearer(settings, "alice"))
            ids = {item["id"] for item in result.json()["items"]}
            assert ids == {bill_id}
        boundary = await client.get("/api/v1/ledger/transactions/me", params={"kind": "transfer", "start_at": created.isoformat(), "end_at": end.isoformat()}, headers=bearer(settings, "alice"))
        assert bill_id in {item["id"] for item in boundary.json()["items"]}
        assert ordinary_bill_id not in {item["id"] for item in boundary.json()["items"]}
        combined = await client.get("/api/v1/ledger/transactions/me", params={"kind": "transfer", "start_at": created.isoformat(), "end_at": end.isoformat(), "q": "餐费"}, headers=bearer(settings, "alice"))
        assert len(combined.json()["items"]) == 1
        assert combined.json()["items"][0]["id"] == bill_id


@pytest.mark.asyncio
async def test_statement_excludes_usdt_and_lists_unknown_other(context):
    app, factory, settings, ledger = context
    usdt = WalletLedger(factory).post(entries={"alice": Decimal("1.000000"), "PLATFORM_CUSTODY": Decimal("-1.000000")}, actor_id="finance", reason_code="USDT_SEED", idempotency_key="usdt-statement", scope="wallet.deposit")
    unknown = ledger.post(entries={"alice": Decimal("1.00"), "PLATFORM_CLEARING": Decimal("-1.00")}, actor_id="alice", reason_code="UNKNOWN", idempotency_key="unknown-other", scope="wallet.conversion")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        all_items = (await client.get("/api/v1/ledger/transactions/me", headers=bearer(settings, "alice"))).json()["items"]
        assert usdt.id not in {item["id"] for item in all_items}
        other = (await client.get("/api/v1/ledger/transactions/me", params={"kind": "other"}, headers=bearer(settings, "alice"))).json()["items"]
        assert unknown.id in {item["id"] for item in other}


@pytest.mark.asyncio
async def test_transfer_bill_detail_exact_fields_and_refund_identity(context):
    app, factory, settings, ledger = context
    service = ChatTransferService(factory, ledger)
    declined = service.create(sender_id="alice", receiver_id="bob", amount=Decimal("3.00"), note="refund", room_id=None, idempotency_key="bill-decline", expires_at=datetime.now(timezone.utc) + timedelta(hours=1))
    declined_sender_bill = service.detail(declined.id, user_id="alice")["bill_id"]
    service.decline(declined.id, user_id="bob", reason_code="CHAT_TRANSFER_DECLINED", idempotency_key="bill-decline-refund")
    assert service.detail(declined.id, user_id="alice")["bill_id"] == declined_sender_bill
    with factory() as session:
        assert session.get(LedgerTransaction, declined_sender_bill).scope == "chat_transfer.create"

    accepted = service.create(sender_id="alice", receiver_id="bob", amount=Decimal("10.00"), note="lunch", room_id=None, idempotency_key="bill-accept", expires_at=datetime.now(timezone.utc) + timedelta(hours=1))
    service.accept(accepted.id, user_id="bob", idempotency_key="bill-accept-release")
    receiver_bill = service.detail(accepted.id, user_id="bob")["bill_id"]
    sender_bill = service.detail(accepted.id, user_id="alice")["bill_id"]
    with factory() as session:
        accepted_business = session.get(type(accepted), accepted.id)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        receiver = await client.get(f"/api/v1/ledger/transactions/me/{receiver_bill}", headers=bearer(settings, "bob"))
        assert receiver.status_code == 200
        body = receiver.json()
        assert body["amount"] == "10.00"
        assert body["transfer_amount"] == "10.00"
        assert body["fee"] == "0.05"
        assert body["note"] == "lunch"
        assert datetime.fromisoformat(body["transfer_created_at"]) == accepted_business.created_at.replace(tzinfo=timezone.utc)
        assert datetime.fromisoformat(body["accepted_at"]) == accepted_business.updated_at.replace(tzinfo=timezone.utc)
        sender = await client.get(f"/api/v1/ledger/transactions/me/{sender_bill}", headers=bearer(settings, "alice"))
        assert sender.status_code == 200
        assert sender.json()["amount"] == "-10.05"
    with factory() as session:
        assert session.get(LedgerTransaction, receiver_bill).scope == "chat_transfer.accept"
