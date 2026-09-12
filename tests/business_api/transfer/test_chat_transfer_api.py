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


@pytest.fixture()
def context():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:", redis_url="redis://localhost:6379/15", jwt_secret="r" * 32, totp_issuer="六合通")
    app = create_app(settings, session_factory=factory)
    LedgerService(factory).adjust(user_id="sender", amount=Decimal("300.00"), actor_id="finance", reason_code="INITIAL_CREDIT", idempotency_key="api-seed")
    yield app, factory, settings
    engine.dispose()


def bearer(settings, user_id):
    now = datetime.now(timezone.utc)
    value = jwt.encode({"sub": user_id, "iss": settings.jwt_issuer, "iat": int(now.timestamp()), "exp": int((now + timedelta(minutes=5)).timestamp())}, settings.jwt_secret, algorithm="HS256")
    return {"Authorization": f"Bearer {value}"}


@pytest.mark.asyncio
async def test_chat_transfer_create_accept_and_decline_flow(context):
    app, factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        created = await client.post("/api/v1/chat-transfers", headers={**bearer(settings, "sender"), "Idempotency-Key": "tr-api-1"}, json={"receiver_id": "receiver", "amount": "20.00", "note": "午饭"})
        assert created.status_code == 201
        body = created.json()
        assert body["status"] == "PENDING"
        assert body["fee"] == "0.10"
        assert body["bill_id"]
        assert body["accepted_at"] is None
        transfer_id = body["id"]
        detail = await client.get(f"/api/v1/chat-transfers/{transfer_id}", headers=bearer(settings, "receiver"))
        assert detail.status_code == 200
        assert detail.json()["amount"] == "20.00"
        accepted = await client.post(f"/api/v1/chat-transfers/{transfer_id}/accept", headers={**bearer(settings, "receiver"), "Idempotency-Key": "tr-api-accept"})
        assert accepted.status_code == 200
        assert accepted.json()["status"] == "ACCEPTED"
        assert accepted.json()["bill_id"]
        assert accepted.json()["accepted_at"]


@pytest.mark.asyncio
async def test_chat_transfer_insufficient_balance_message(context):
    app, factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        created = await client.post("/api/v1/chat-transfers", headers={**bearer(settings, "sender"), "Idempotency-Key": "tr-api-2"}, json={"receiver_id": "receiver", "amount": "99999.00", "note": None})
        assert created.status_code == 422
        assert created.json()["error"]["code"] == "CHAT_TRANSFER_BALANCE_INSUFFICIENT"
        assert created.json()["error"]["message"] == "转账失败，账户余额不足"


@pytest.mark.asyncio
async def test_chat_transfer_only_recipient_can_accept(context):
    app, factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        created = await client.post("/api/v1/chat-transfers", headers={**bearer(settings, "sender"), "Idempotency-Key": "tr-api-3"}, json={"receiver_id": "receiver", "amount": "5.00", "note": None})
        transfer_id = created.json()["id"]
        forbidden = await client.post(f"/api/v1/chat-transfers/{transfer_id}/accept", headers={**bearer(settings, "mallory"), "Idempotency-Key": "tr-api-bad"})
        assert forbidden.status_code in (403, 422)


@pytest.mark.asyncio
async def test_decline_refunds_principal_and_fee_in_full(context):
    """退还时本金与手续费全额退回转出方（不变量钉死）。

    分录：escrow -amount, PLATFORM_FEE -fee, sender +(amount+fee)。
    平台手续费不因退还而留存。
    """
    app, factory, settings = context
    from sqlalchemy import select, func
    from app.modules.ledger.models import LedgerEntry

    created = await AsyncClient(transport=ASGITransport(app=app), base_url="http://test")         if False else None
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        body = (await client.post(
            "/api/v1/chat-transfers",
            headers={**bearer(settings, "sender"), "Idempotency-Key": "tr-fee-1"},
            json={"receiver_id": "receiver", "amount": "10.00"},
        )).json()
        assert body["fee"] == "0.05"
        transfer_id = body["id"]

        declined = await client.post(
            f"/api/v1/chat-transfers/{transfer_id}/decline",
            headers={**bearer(settings, "receiver"), "Idempotency-Key": "tr-fee-decline"},
        )
        assert declined.status_code == 200
        assert declined.json()["status"] == "DECLINED"

    with factory() as session:
        escrow = f"PLATFORM_TRANSFER_ESCROW:{transfer_id}"
        escrow_total = session.scalar(
            select(func.coalesce(func.sum(LedgerEntry.amount), 0))
            .where(LedgerEntry.account_id == escrow))
        fee_total = session.scalar(
            select(func.coalesce(func.sum(LedgerEntry.amount), 0))
            .where(LedgerEntry.account_id == "PLATFORM_FEE", LedgerEntry.asset == "CAIBI"))
        sender_total = session.scalar(
            select(func.coalesce(func.sum(LedgerEntry.amount), 0))
            .where(LedgerEntry.account_id == "sender", LedgerEntry.asset == "CAIBI"))
        # 托管清零；平台手续费净变动不含该笔 0.05；转出方回到种子余额
        # 300.00（10.05 扣 + 10.05 退，本金与手续费全额退回）。
        assert escrow_total == 0
        assert fee_total == 0
        assert sender_total == Decimal('300.00')
