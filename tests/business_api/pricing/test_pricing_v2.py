"""ADR-0076 批次2：点钻人民币计价 v2——兑换关闭、自动兑换关闭、储备口径修正。"""
import asyncio
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, event, select
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

import app.modules.fx.models  # noqa: F401
import app.modules.wallet.models  # noqa: F401
import app.modules.wallet.funding_models  # noqa: F401
import app.modules.wallet.receipt_models  # noqa: F401
import app.modules.wallet.manual_payout_models  # noqa: F401
from app.core.database import Base
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.ledger.reserve import RedeemabilityReserve


def make_db():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)

    @event.listens_for(engine, "connect")
    def _fk(dbapi_connection, _record):
        dbapi_connection.execute("PRAGMA foreign_keys=ON")

    Base.metadata.create_all(engine)
    return engine, sessionmaker(bind=engine, expire_on_commit=False)


NOW = datetime(2026, 9, 21, 12, 0, 0, tzinfo=timezone.utc)


def seed_reserve(factory, *, eligible="40.00", usdt_liability="0.00"):
    # 储备证据新鲜度以真实时钟判定（120s 窗口），用真实 now 作 observed_at。
    with factory.begin() as session:
        session.add(RedeemabilityReserve(id="global", eligible_usdt=Decimal(eligible), usdt_liability=Decimal(usdt_liability),
            version=1, pending_payouts=0, outgoing_restricted=False, observed_at=datetime.now(timezone.utc)))


def seed_caibi_liability(factory, account="alice", amount="100.00"):
    with factory.begin() as session:
        tx = LedgerTransaction(id="tx-liab-1", asset="CAIBI", scope="test.seed", idempotency_key="seed-1",
            actor_id="system", reason_code="SEED", created_at=NOW)
        session.add(tx)
        session.flush()
        session.add(LedgerEntry(id="e1", transaction_id=tx.id, account_id=account, asset="CAIBI", amount=Decimal(amount), created_at=NOW))
        session.add(LedgerEntry(id="e2", transaction_id=tx.id, account_id="PLATFORM_CLEARING", asset="CAIBI", amount=-Decimal(amount), created_at=NOW))


def seed_fx(factory, *, rate="7.120000", fresh=True):
    """以真实当前时间为锚生成新鲜窗口（fixed NOW 只用于断言，
    fresh 判定用真实时钟——避免长套件运行中种子过期造成顺序依赖）。"""
    from app.modules.fx.models import FxRate

    with factory.begin() as session:
        anchor = datetime.now(timezone.utc)
        fetched = anchor if fresh else anchor - timedelta(hours=3)
        session.add(FxRate(pair="USD/CNY", rate=Decimal(rate), fetched_at=fetched,
            expires_at=fetched + timedelta(seconds=3600), fetch_state="idle"))


def make_authed_app(factory):
    """构造带 ACTIVE 用户与合法 Bearer 的测试应用（避免 401 掩盖业务码）。"""
    from datetime import datetime as _dt

    from app.core.config import Settings
    from app.core.database import create_session_factory
    from app.main import create_app
    from app.modules.identity.enums import AccountStatus
    from app.modules.identity.models import User
    from app.modules.identity.passwords import PasswordHasher
    from app.modules.identity.tokens import TokenService

    engine2, _ = make_db()
    factory2 = create_session_factory(engine2)
    now = _dt.now(timezone.utc)
    with factory2.begin() as session:
        session.add(User(id="alice", username="alice", username_normalized="alice",
            email="alice@example.com", email_normalized="alice@example.com",
            password_hash=PasswordHasher().hash("correct horse battery staple"),
            status=AccountStatus.ACTIVE, matrix_user_id="@alice:matrix.localhost",
            email_verified_at=now, created_at=now, updated_at=now))
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:",
        jwt_secret="test-jwt-secret-at-least-thirty-two-bytes")
    app = create_app(settings, session_factory=factory2)
    tokens = TokenService(factory2, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer, require_session_claims=False)
    pair = tokens.issue_pair(user_id="alice", device_key="device-1", display_name="test")
    return app, factory2, pair.access_token


# ---------------------------------------------------------------- 配置与开关

def test_user_conversions_closed_by_default():
    from app.core.config import Settings

    assert Settings(_env_file=None).wallet_user_conversions_closed is True
    assert Settings(_env_file=None).caibi_pricing_version == "caibi-cny-v1"


def test_deposit_auto_conversion_conflicts_with_closed_conversions():
    from pydantic import ValidationError

    from app.core.config import Settings

    with pytest.raises(ValidationError):
        Settings(_env_file=None, wallet_deposit_auto_conversion_enabled=True, wallet_user_conversions_closed=True)
    # 显式回退（历史兼容演练）允许同时声明旧组合
    Settings(_env_file=None, wallet_conversions_enabled=True,
        wallet_deposit_auto_conversion_enabled=True, wallet_user_conversions_closed=False)


def test_convert_endpoint_reports_clear_business_error_when_closed():
    """旧客户端（带合法登录态）对关闭的兑换收到明确业务错误，而不是按钮隐藏或 500。"""
    from httpx import ASGITransport, AsyncClient

    app, factory2, token = make_authed_app(None)
    import asyncio

    async def call():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            return await client.post("/api/v1/wallet/conversions", json={"direction": "CAIBI_TO_USDT", "amount": "1.00"},
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "k1"})

    response = asyncio.run(call())
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "CONVERSIONS_CLOSED"
    assert "兑换" in response.json()["error"]["message"]


def test_balances_and_historical_conversion_unchanged_after_closed_attempt():
    """关闭只挡新写：历史兑换记录可查、余额数字不变、旧订单不重写。"""
    from httpx import ASGITransport, AsyncClient

    from app.modules.wallet.models import WalletConversion, WalletLedgerEntry, WalletLedgerTransaction

    app, factory2, token = make_authed_app(None)
    with factory2.begin() as session:
        session.add(WalletConversion(id="old-conv-1", user_id="alice", idempotency_key="convert:old",
            direction="CAIBI_TO_USDT", requested_amount=Decimal("5.00"), source_amount=Decimal("5.00"),
            target_amount=Decimal("5.00"), status="COMPLETED", created_at=NOW))
        tx = WalletLedgerTransaction(id="wt-1", asset="USDT-TRC20", scope="wallet.conversion", idempotency_key="convert:old",
            actor_id="alice", reason_code="CAIBI_TO_USDT", created_at=NOW)
        session.add(tx)
        session.flush()
        session.add(WalletLedgerEntry(id="we1", transaction_id=tx.id, account_id="alice", asset="USDT-TRC20", amount=Decimal("5.000000"), created_at=NOW))
        session.add(WalletLedgerEntry(id="we2", transaction_id=tx.id, account_id="PLATFORM_CONVERSION", asset="USDT-TRC20", amount=Decimal("-5.000000"), created_at=NOW))

    async def calls():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            post = await client.post("/api/v1/wallet/conversions", json={"direction": "CAIBI_TO_USDT", "amount": "1.00"},
                headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "new-k"})
            history = await client.get("/api/v1/wallet/conversions/old-conv-1", headers={"Authorization": f"Bearer {token}"})
            balance = await client.get("/api/v1/wallet/balances/me", headers={"Authorization": f"Bearer {token}"})
        return post, history, balance

    post, history, balance = asyncio.run(calls())
    assert post.status_code == 422
    assert post.json()["error"]["code"] == "CONVERSIONS_CLOSED"
    assert history.status_code == 200
    assert history.json()["status"] == "COMPLETED" and history.json()["source_amount"] == "5.00"
    assert balance.status_code == 200
    assert Decimal(balance.json()["balance"]) == Decimal("5.000000")  # 余额数字不变
    with factory2() as session:
        row = session.get(WalletConversion, "old-conv-1")
        assert row.status == "COMPLETED" and row.source_amount == Decimal("5.00")
        assert session.scalar(select(func_count(WalletLedgerEntry))) == 2


def func_count(model):
    from sqlalchemy import func

    return func.count(model.id)


# ---------------------------------------------------------------- 储备口径

def test_full_backing_coverage_no_longer_adds_caibi_to_usdt_units():
    """有新鲜汇率：点钻按参考估值折算，不再与 USDT 负债直接相加。"""
    from app.modules.ledger.reserve import require_coverage

    engine, factory = make_db()
    seed_reserve(factory, eligible="40.00", usdt_liability="0.00")
    seed_caibi_liability(factory, amount="100.00")  # ¥100 负债
    seed_fx(factory, rate="7.120000")  # 100/7.12 ≈ 14.04 USDT
    with factory.begin() as session:
        reserve = session.get(RedeemabilityReserve, "global")
        require_coverage(session, reserve, caibi_delta=Decimal("0"), policy="full_backing")  # 40 ≥ 14.05 → 通过
    engine.dispose()


def test_full_backing_coverage_without_fresh_rate_fails_closed():
    """无新鲜汇率：不能核验人民币计价负债，拒绝放行。"""
    from app.modules.ledger.reserve import require_coverage

    engine, factory = make_db()
    seed_reserve(factory, eligible="40.00", usdt_liability="0.00")
    seed_caibi_liability(factory, amount="100.00")
    with factory.begin() as session:
        reserve = session.get(RedeemabilityReserve, "global")
        with pytest.raises(__import__("app.core.errors", fromlist=["AppError"]).AppError) as exc:
            require_coverage(session, reserve, caibi_delta=Decimal("0"), policy="full_backing")
        assert exc.value.code == "RESERVE_VALUATION_UNAVAILABLE"
    engine.dispose()


def test_manual_payout_coverage_uses_same_valuation():
    from app.modules.ledger.manual_payout_reserve import require_manual_payout_coverage

    engine, factory = make_db()
    seed_reserve(factory, eligible="40.00", usdt_liability="58.91")
    seed_caibi_liability(factory, amount="100.00")
    seed_fx(factory, rate="7.120000")
    with factory.begin() as session:
        reserve = session.get(RedeemabilityReserve, "global")
        require_manual_payout_coverage(session, reserve, now=datetime.now(timezone.utc) + timedelta(seconds=30), policy="manual_liquidity")
    engine.dispose()


def test_reconcile_expected_is_usdt_obligation_only_and_records_valuation():
    """USDT 托管核对不再把点钻负债并入义务；三类数量分开记录。"""
    from app.modules.wallet.safety import usdt_liability
    from app.modules.ledger.reserve import reserve_valuation_snapshot

    engine, factory = make_db()
    seed_caibi_liability(factory, amount="100.00")
    seed_fx(factory, rate="7.120000")
    with factory.begin() as session:
        # 构造 USDT 负债（含 HOLD 冻结 = 已批准未支付义务）
        from app.modules.wallet.models import WalletLedgerEntry, WalletLedgerTransaction

        tx = WalletLedgerTransaction(id="wt-hold", asset="USDT-TRC20", scope="t", idempotency_key="k",
            actor_id="alice", reason_code="HOLD", created_at=NOW)
        session.add(tx)
        session.flush()
        session.add(WalletLedgerEntry(id="w1", transaction_id=tx.id, account_id="HOLD:alice", asset="USDT-TRC20", amount=Decimal("12.000000"), created_at=NOW))
        session.add(WalletLedgerEntry(id="w2", transaction_id=tx.id, account_id="alice", asset="USDT-TRC20", amount=Decimal("-12.000000"), created_at=NOW))
        session.flush()

        snapshot = reserve_valuation_snapshot(session)
        assert snapshot["usdt_obligation"] == Decimal("12.000000")  # HOLD 即真实 USDT 义务
        assert snapshot["caibi_face"] == Decimal("100.00")
        assert snapshot["valuation_rate"] == Decimal("7.120000")
        assert snapshot["caibi_reference_usdt"] == Decimal("14.044944")  # 100/7.12 向上 6 位
        assert snapshot["approved_unpaid_usdt"] == Decimal("0.000000")
    engine.dispose()


def test_valuation_rate_absent_reports_none_not_one():
    from app.modules.ledger.reserve import reserve_valuation_snapshot

    engine, factory = make_db()
    seed_caibi_liability(factory, amount="100.00")
    with factory() as session:
        snapshot = reserve_valuation_snapshot(session)
    assert snapshot["valuation_rate"] is None
    assert snapshot["caibi_reference_usdt"] is None  # 不伪造估值
    engine.dispose()
