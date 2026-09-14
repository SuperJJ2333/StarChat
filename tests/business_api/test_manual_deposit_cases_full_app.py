"""Mounted HTTP authorization and execution checks for manual deposit cases."""
from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from types import SimpleNamespace

import httpx
import jwt
from coincurve import PrivateKey
from sqlalchemy import func, select

from app.core.config import Settings
from app.integrations.tron.finality import SolidHead, TransactionEvidence, TransferEvidence
from app.integrations.tron.message_signature import address_from_public_key
from app.main import create_app
from app.modules.identity.enums import RoleCode
from app.modules.identity.models import AccountStatus, AdminSession, Device, RefreshTokenFamily, User, UserRole
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.wallet.binding_models import WalletAddressOwner, WalletBinding, WalletBindingState
from app.modules.wallet.funding import OfficialFundingConfig
from app.modules.wallet.manual_deposit_cases import ManualDepositCaseService  # noqa: F401
from app.modules.wallet.models import WalletControl, WalletLedgerTransaction
from app.modules.wallet.receipts import DepositReceiptService
from app.modules.wallet.runtime import ManualWalletRuntime
from app.modules.wallet.safety import usdt_liability
from tests.business_api.identity.test_wallet_access_grant import grant_context  # noqa: F401


def test_mounted_manual_case_enforces_grant_owner_confirmation_and_write_gate(grant_context, monkeypatch):
    _, factory, _, claims, _ = grant_context
    now = datetime.now(timezone.utc)
    source, official = [address_from_public_key(PrivateKey().public_key.format(compressed=False)) for _ in range(2)]
    with factory.begin() as session:
        session.add(User(id="alice", username="alice", username_normalized="alice", email="alice@example.test",
            email_normalized="alice@example.test", password_hash="synthetic-only", status=AccountStatus.ACTIVE,
            created_at=now, updated_at=now))
        session.add(User(id="other", username="other", username_normalized="other", email="other@example.test",
            email_normalized="other@example.test", password_hash="synthetic-only", status=AccountStatus.ACTIVE,
            created_at=now, updated_at=now))
        session.add(UserRole(id="other-role", user_id="other", role_code=RoleCode.SUPER_ADMIN,
            assigned_by="fixture", assigned_at=now))
        session.add(Device(id="other-device", user_id="other", device_key="other-fixture", display_name="other fixture",
            created_at=now, last_seen_at=now))
        session.add(RefreshTokenFamily(id="other-family", user_id="other", device_id="other-device", created_at=now))
        session.add(AdminSession(user_id="other", family_id="other-family", authenticated_at=now, created_at=now,
            expires_at=now + timedelta(hours=24)))
        session.add(WalletControl(id="global", withdrawals_paused=False))
        session.add(RedeemabilityReserve(id="global", eligible_usdt=Decimal("1000"), usdt_liability=0,
            version=1, pending_payouts=0, outgoing_restricted=False, observed_at=now))
        session.add(WalletAddressOwner(address=source, user_id="alice", created_at=now - timedelta(hours=1)))
        session.flush()
        session.add(WalletBinding(id="binding", user_id="alice", address=source, version=1, status="ACTIVE",
            created_at=now - timedelta(hours=1), activated_at=now - timedelta(hours=1), effective_from_block=101,
            barrier_height=100, barrier_block_id="a" * 64, barrier_source_ids=["fixture"],
            barrier_observed_at=now))
        session.add(WalletBindingState(user_id="alice", version=1, active_binding_id="binding"))

    transfer_ms = int((now - timedelta(minutes=3)).timestamp() * 1000)
    transfer = TransferEvidence("b" * 64, 0, 102, "c" * 64, transfer_ms, source, official, 10_000_000)
    proof = TransactionEvidence("b" * 64, 102, "c" * 64, transfer_ms,
        SolidHead(103, "d" * 64, int(now.timestamp() * 1000), now), (transfer,), now)
    adapter = SimpleNamespace(transaction_evidence=lambda txid: proof, close=lambda: None)
    receipts = DepositReceiptService(factory, finality_adapter=adapter,
        official_config=OfficialFundingConfig(official, "test-v1"), activation_baseline_time=now - timedelta(days=1),
        activation_baseline_height=100, clock=lambda: datetime.now(timezone.utc))
    receipt = receipts.ingest("b" * 64, actor_id="fixture-worker")[0]
    runtime = ManualWalletRuntime(None, None, receipts, SimpleNamespace(), adapter, True)
    monkeypatch.setattr("app.main.create_manual_wallet_runtime", lambda *args: runtime)
    monkeypatch.setattr("app.api.admin.ClockHealth", lambda: SimpleNamespace(trusted=lambda: True))
    settings = Settings(_env_file=None, environment="test", database_url="sqlite://",
        jwt_secret="integration-test-wallet-secret-at-least-thirty-two", wallet_access_grant_enabled=True,
        wallet_admin_auth_mode="operation_password", wallet_manual_owner_admin_id="owner",
        wallet_access_policy_version="v1", wallet_manual_repairs_enabled=True)
    app = create_app(settings, session_factory=factory)
    settings.wallet_real_mode = "manual_tron"

    def headers(subject="owner", key="http-command"):
        token_claims = claims if subject == "owner" else claims | {"sub": "other", "device_id": "other-device", "family_id": "other-family"}
        token = jwt.encode(token_claims | {"iss": settings.jwt_issuer}, settings.jwt_secret, algorithm="HS256")
        return {"Authorization": "Bearer " + token, "Idempotency-Key": key}

    base = "/api/v1/admin/wallet/manual/manual-deposit-cases"
    create_payload = {"receipt_id": receipt["id"], "user_id": "alice", "reason_detail": "HTTP集成测试核对历史归属",
                      "ownership_attestation": True}

    async def run():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            assert (await client.get(base + "/context", params={"txid": "b" * 64, "log_index": 0})).status_code == 401
            forbidden = await client.get(base + "/context", headers=headers("other"), params={"txid": "b" * 64, "log_index": 0})
            assert forbidden.status_code == 403 and forbidden.json()["error"]["code"] == "PERMISSION_DENIED"
            ungranted = await client.post(base, headers=headers(key="create-ungranted"), json=create_payload)
            assert ungranted.status_code == 403 and ungranted.json()["error"]["code"] == "WALLET_ACCESS_REQUIRED"
            verified = await client.post("/api/v1/wallet/manual/access/verify", headers=headers(),
                json={"operation_password": "operation-password-123"})
            assert verified.status_code == 200, verified.text

            context = await client.get(base + "/context", headers=headers(), params={"txid": "b" * 64, "log_index": 0})
            assert context.status_code == 200, context.text
            created = await client.post(base, headers=headers(key="case-create"), json=create_payload)
            assert created.status_code == 200, created.text
            case_id = created.json()["case_id"]

            bad_decision = await client.post(base + f"/{case_id}/decision", headers=headers(key="decision-bad"),
                json={"decision": "APPROVED", "reason_detail": "负责人确认", "confirmed": False})
            assert bad_decision.status_code == 422
            decision = await client.post(base + f"/{case_id}/decision", headers=headers(key="decision-ok"),
                json={"decision": "APPROVED", "reason_detail": "负责人确认", "confirmed": True})
            assert decision.status_code == 200, decision.text
            preview = await client.post(base + f"/{case_id}/preview", headers=headers())
            assert preview.status_code == 200 and preview.json()["status"] == "VALIDATED", preview.text
            command = {key: preview.json()[key] for key in ("preview_id", "digest", "expected_version")}
            command.update(operation_id="manual-http-operation", confirmed=False)
            bad_execute = await client.post(base + f"/{case_id}/execute", headers=headers(key="execute-bad"), json=command)
            assert bad_execute.status_code == 422
            command["confirmed"] = True
            executed = await client.post(base + f"/{case_id}/execute", headers=headers(key="execute-ok"), json=command)
            assert executed.status_code == 200 and executed.json()["status"] == "EXECUTED", executed.text
            operation = executed.json()["operation_id"]
            replay = await client.post(base + f"/{case_id}/execute", headers=headers(key="execute-ok"), json=command)
            assert replay.status_code == 200 and replay.json() == executed.json()

            settings.wallet_manual_repairs_enabled = False
            disabled = await client.post(base, headers=headers(key="write-disabled"), json=create_payload)
            assert disabled.status_code == 503 and disabled.json()["error"]["code"] == "MANUAL_REPAIRS_DISABLED"
            status = await client.get(base + "/operations/" + operation, headers=headers())
            assert status.status_code == 200 and status.json() == executed.json()
            assert status.headers["cache-control"] == "no-store"
            revoked = await client.post("/api/v1/wallet/manual/access/revoke", headers=headers())
            assert revoked.status_code == 200
            denied = await client.get(base + "/operations/" + operation, headers=headers())
            assert denied.status_code == 403 and denied.json()["error"]["code"] == "WALLET_ACCESS_REQUIRED"

    asyncio.run(run())
    assert receipts.wallet_ledger.balance("alice") == Decimal("10")
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(WalletLedgerTransaction)) == 1
        assert usdt_liability(session) == Decimal("10")
