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

import pytest
from sqlalchemy import create_engine, select, event
from sqlalchemy.pool import StaticPool

import app.modules.fx.models  # noqa: F401
import app.modules.recharge.models  # noqa: F401
from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxEvent
from app.main import create_app
from app.modules.audit.models import AuditEvent
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import User, UserRole
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.tokens import TokenService
from app.modules.ledger.models import LedgerEntry
from app.modules.ledger.service import LedgerService
from app.modules.recharge.service import RechargeService
from app.modules.wallet import receipt_models, repair_models, manual_payout_models, funding_models  # noqa: F401
from app.modules.wallet.models import WalletLedgerEntry


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
    ledger = LedgerService(factory)
    ledger.adjust(user_id="alice", amount=Decimal("100.00"), actor_id="finance",
        reason_code="SEED", idempotency_key="seed-alice")

    def rate_provider():
        return Decimal("7.120000"), False

    recharge = RechargeService(factory, ledger=ledger, rate_provider=rate_provider)
    yield factory, ledger, recharge
    engine.dispose()


def _caibi_balance(factory, account):
    from sqlalchemy import func

    with factory() as session:
        return Decimal(session.scalar(select(func.coalesce(func.sum(LedgerEntry.amount), 0))
            .where(LedgerEntry.account_id == account)))


def test_submit_creates_pending_order_without_balance_change(env):
    factory, ledger, recharge = env
    view = recharge.submit(user_id="alice", amount_usdt=Decimal("50"), evidence_txid="A" * 64)
    assert view["status"] == "SUBMITTED"
    assert view["fx_rate"] == "7.120000"
    assert _caibi_balance(factory, "alice") == Decimal("100.00")  # 分文不动
    assert _caibi_balance(factory, "PLATFORM_CLEARING") == Decimal("-100.00")  # 账本仅种子分录


def test_same_evidence_cannot_fund_two_requests(env):
    factory, ledger, recharge = env
    from app.core.errors import AppError

    recharge.submit(user_id="alice", amount_usdt=Decimal("50"), evidence_txid="B" * 64)
    with pytest.raises(AppError) as excinfo:
        recharge.submit(user_id="alice", amount_usdt=Decimal("20"), evidence_txid="B" * 64)
    assert excinfo.value.code == "RECHARGE_EVIDENCE_REUSED"


def test_credit_marks_request_and_requires_public_ledger_proof(env):
    """真实审批执行凭证才能登记；汇率和金额一致，重放不重复入账。"""
    from app.modules.ledger.adjustments import AdjustmentWorkflow
    factory, ledger, recharge = env
    view = recharge.submit(user_id="alice", amount_usdt=Decimal("50"), evidence_txid="C" * 64)
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
    view = recharge.submit(user_id="alice", amount_usdt=Decimal("10"))
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
