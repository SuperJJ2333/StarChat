from typing import Annotated
from fastapi import APIRouter, Depends, Header, Request
from pydantic import BaseModel, ConfigDict, Field
from decimal import Decimal
from sqlalchemy import func, select
from datetime import datetime, timedelta, timezone
from app.core.config import Settings
from app.core.errors import AppError
from app.modules.identity.tokens import TokenService
from app.modules.identity.rbac import Permission, RbacService
from app.modules.identity.models import User, UserRole, Device
from app.modules.identity.enums import AccountStatus
from app.modules.admin.models import AdminBan, OfficialNotice, NoticeReceipt, NativeAdCampaign
from app.modules.support.service import SupportAgentPresence
from app.modules.audit.writer import AuditWriter
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.ledger.adjustment_models import AdjustmentRequest
from app.modules.wallet.models import Withdrawal
from app.modules.moments.models import NativeMomentAd
from app.modules.admin.service import AdminControlService
from app.modules.identity.enums import RoleCode
from app.modules.ledger.service import LedgerService
from app.modules.ledger.adjustments import AdjustmentWorkflow
from app.modules.settings.service import (
    APP_APK_URL_KEY,
    APP_LATEST_BUILD_KEY,
    APP_LATEST_VERSION_KEY,
    APP_MIN_SUPPORTED_BUILD_KEY,
    APP_UPDATE_NOTES_KEY,
    APP_UPDATE_SETTING_KEYS,
    RED_PACKET_MAX_TOTAL_KEY,
    SettingService,
)
from app.modules.wallet.service import WalletService
from app.integrations.custody.sandbox import SandboxCustodyProvider

class BanBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    target_type: str
    target: str
    reason_code: str
    duration_minutes: int | None = Field(default=None, ge=1)
class RoleBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    role_code: RoleCode
class NoticeBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str = Field(min_length=1, max_length=160)
    content: str = Field(min_length=1)
    audience: str = Field(min_length=1, max_length=40)
    publish_at: datetime | None = None
class AdBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    advertiser_name: str = Field(min_length=1, max_length=128)
    text: str = Field(min_length=1)
    link_url: str = Field(min_length=1, max_length=2048)
class AdScheduleBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    starts_at: datetime
    ends_at: datetime
    audience: dict = Field(default_factory=dict)
class RetractBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    reason_code: str = Field(min_length=1, max_length=100)
class DirectCaibiGrantBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    user_id: str = Field(min_length=1, max_length=36)
    amount: Decimal = Field(gt=0, decimal_places=2)
    reason_code: str = Field(min_length=1, max_length=100)
class AppUpdateSettingsBody(BaseModel):
    latest_version: str = Field(min_length=1, max_length=32)
    latest_build: int = Field(ge=1)
    min_supported_build: int = Field(ge=0)
    notes: str = Field(min_length=1, max_length=2000)
    apk_url: str = Field(min_length=1, max_length=500)

class RedPacketSettingsBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    max_total: Decimal = Field(gt=0, decimal_places=2)
MODULE_PERMISSIONS = {
    "finance": Permission.FINANCE_REVIEW,
    "security": Permission.SYSTEM_ADMIN,
    "support-role": Permission.SUPPORT_SCOPE_MANAGE,
    "analytics": Permission.AUDIT_VIEW,
    "online": Permission.SUPPORT_TICKET_ASSIGN,
    "ads": Permission.SYSTEM_ADMIN,
    "notice": Permission.SYSTEM_ADMIN,
    "ledger": Permission.AUDIT_VIEW,
    "wallet": Permission.FINANCE_REVIEW,
}

def create_admin_router(settings: Settings, session_factory) -> APIRouter:
    router = APIRouter(prefix="/admin", tags=["admin"])
    tokens = TokenService(session_factory, jwt_secret=settings.jwt_secret or "development-jwt-secret-at-least-thirty-two-bytes", jwt_issuer=settings.jwt_issuer, require_session_claims=settings.environment != "test")
    rbac = RbacService(session_factory)
    audit = AuditWriter(session_factory)
    controls = AdminControlService(session_factory)
    adjustment_workflow = AdjustmentWorkflow(session_factory, LedgerService(session_factory), admin_threshold=Decimal(str(getattr(settings, "adjustment_admin_threshold", "10000.00"))))
    wallet_service = WalletService(session_factory, SandboxCustodyProvider(secret=settings.wallet_webhook_secret or "development-wallet-webhook-secret"), withdrawal_admin_threshold=Decimal(str(getattr(settings, "adjustment_admin_threshold", "10000.00"))))

    def actor(authorization: Annotated[str | None, Header()] = None) -> str:
        if not authorization or not authorization.startswith("Bearer "):
            raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
        return str(tokens.decode_access_token(authorization[7:])["sub"])

    def require(actor_id: str, permission: Permission):
        if Permission.SYSTEM_ADMIN in rbac.permissions_for(actor_id):
            return
        rbac.require(actor_id, permission)

    def trace(request: Request) -> str:
        return getattr(request.state, "trace_id", "admin-command")

    @router.post("/security/bans", status_code=201)
    def create_ban(body: BanBody, request: Request, idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        return controls.ban(actor_id=user_id, target_type=body.target_type, target=body.target, reason_code=body.reason_code, duration_minutes=body.duration_minutes, idempotency_key=idempotency_key, trace_id=trace(request))

    @router.post("/security/bans/{ban_id}/revoke")
    def revoke_ban(ban_id: str, request: Request, body: dict, idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        return controls.unban(actor_id=user_id, ban_id=ban_id, reason_code=str(body.get("reason_code", "BAN_REVOKE")), idempotency_key=idempotency_key, trace_id=trace(request))

    @router.post("/support-roles/{target_user_id}", status_code=201)
    def assign_support_role(target_user_id: str, body: RoleBody, request: Request, idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        return controls.set_support_role(actor_id=user_id, user_id=target_user_id, role_code=body.role_code, idempotency_key=idempotency_key, trace_id=trace(request))

    @router.post("/notices", status_code=201)
    def create_notice(body: NoticeBody, request: Request, idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        return controls.create_notice(actor_id=user_id, title=body.title, content=body.content, audience=body.audience, publish_at=body.publish_at, idempotency_key=idempotency_key, trace_id=trace(request))

    @router.post("/ads", status_code=201)
    def create_ad(body: AdBody, request: Request, idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        return controls.create_ad(actor_id=user_id, advertiser_name=body.advertiser_name, text=body.text, link_url=body.link_url, idempotency_key=idempotency_key, trace_id=trace(request))

    @router.put("/notices/{notice_id}")
    def update_notice(notice_id: str, body: NoticeBody, request: Request, idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        return controls.update_notice(actor_id=user_id, notice_id=notice_id, title=body.title, content=body.content, audience=body.audience, publish_at=body.publish_at, idempotency_key=idempotency_key, trace_id=trace(request))

    @router.post("/notices/{notice_id}/retract")
    def retract_notice(notice_id: str, body: RetractBody, request: Request, idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        return controls.retract_notice(actor_id=user_id, notice_id=notice_id, reason_code=body.reason_code, idempotency_key=idempotency_key, trace_id=trace(request))

    @router.delete("/support-roles/{target_user_id}/{role_code}")
    def revoke_support_role(target_user_id: str, role_code: RoleCode, request: Request, idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        return controls.revoke_support_role(actor_id=user_id, user_id=target_user_id, role_code=role_code, idempotency_key=idempotency_key, trace_id=trace(request))

    @router.post("/ads/{ad_id}/schedule")
    def schedule_ad(ad_id: str, body: AdScheduleBody, request: Request, idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        return controls.schedule_ad(actor_id=user_id, ad_id=ad_id, starts_at=body.starts_at, ends_at=body.ends_at, audience=body.audience, idempotency_key=idempotency_key, trace_id=trace(request))

    @router.post("/ads/{ad_id}/events/{event_type}")
    def ad_event(ad_id: str, event_type: str):
        # Public client telemetry contains no user identity or chat content.
        return controls.record_ad_event(ad_id=ad_id, event_type=event_type)

    @router.get("/internal/access/ip")
    def gateway_ip_access(x_original_forwarded_for: Annotated[str | None, Header()] = None):
        candidate = (x_original_forwarded_for or "").split(",")[0].strip()
        if not candidate:
            return {"allowed": True}
        now = datetime.now(timezone.utc)
        with session_factory() as session:
            ban = session.scalar(select(AdminBan).where(AdminBan.subject_type == "ip", AdminBan.subject_value == candidate, AdminBan.revoked_at.is_(None), AdminBan.starts_at <= now).order_by(AdminBan.created_at.desc()))
            if ban is not None and (ban.ends_at is None or ban.ends_at > now):
                raise AppError(code="IP_BANNED", message="访问已被限制", status_code=403)
        return {"allowed": True}

    @router.post("/notices/{notice_id}/read", status_code=204)
    def read_notice(notice_id: str, idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id: str = Depends(actor)):
        controls.record_notice_read(user_id=user_id, notice_id=notice_id, idempotency_key=idempotency_key)

    @router.post("/finance/adjustments/{request_id}/review")
    def review_adjustment(request_id: str, body: dict, request: Request, idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        try:
            row = adjustment_workflow.admin_review(request_id, reviewer_id=user_id, approve=bool(body.get("approve", True)))
        except ValueError as exc:
            raise AppError(code="ADJUSTMENT_TRANSITION_INVALID", message="点钻申请不存在或当前状态不能处理", status_code=409) from exc
        audit.record(actor_id=user_id, subject_type="adjustment_request", subject_id=request_id, action="admin.adjustment.reviewed", result="SUCCESS", reason_code="ADJUSTMENT_REVIEW", trace_id=trace(request))
        return {"id": row.id, "status": row.status, "idempotency_key": idempotency_key}

    @router.post("/finance/adjustments", status_code=201)
    def grant_caibi_to_support(body: DirectCaibiGrantBody, request: Request, idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        with session_factory() as session:
            roles = set(session.scalars(select(UserRole.role_code).where(UserRole.user_id == body.user_id)))
        if RoleCode.SUPPORT_AGENT not in roles:
            raise AppError(code="SUPPORT_ROLE_REQUIRED", message="仅可向已配置的客服账号发放点钻", status_code=422)
        try:
            transaction = adjustment_workflow.ledger.adjust(user_id=body.user_id, amount=body.amount, actor_id=user_id, reason_code=body.reason_code, idempotency_key=idempotency_key)
        except ValueError as exc:
            raise AppError(code="CAIBI_GRANT_INVALID", message="点钻发放请求无效", status_code=422) from exc
        audit.record(actor_id=user_id, subject_type="ledger_transaction", subject_id=transaction.id, action="admin.caibi.granted", result="SUCCESS", reason_code=body.reason_code, trace_id=trace(request))
        return {"transaction_id": transaction.id, "user_id": body.user_id, "amount": f"{body.amount:.2f}", "status": "POSTED", "idempotency_key": idempotency_key}

    @router.post("/finance/withdrawals/{withdrawal_id}/review")
    def review_withdrawal(withdrawal_id: str, body: dict, request: Request, idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        try:
            row = wallet_service.admin_approve(withdrawal_id, user_id)
        except ValueError as exc:
            raise AppError(code="WITHDRAWAL_TRANSITION_INVALID", message="提现申请不存在或当前状态不能处理", status_code=409) from exc
        audit.record(actor_id=user_id, subject_type="withdrawal", subject_id=withdrawal_id, action="admin.withdrawal.reviewed", result="SUCCESS", reason_code="WITHDRAWAL_REVIEW", trace_id=trace(request))
        return {"id": row.id, "status": row.status, "idempotency_key": idempotency_key}

    @router.get("/red-packet-settings")
    def get_red_packet_settings(user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        stored = SettingService(session_factory).get(RED_PACKET_MAX_TOTAL_KEY)
        return {"key": RED_PACKET_MAX_TOTAL_KEY, "max_total": stored or settings.red_packet_max_total, "source": "database" if stored else "environment"}

    @router.put("/red-packet-settings")
    def update_red_packet_settings(body: RedPacketSettingsBody, request: Request, idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        if body.max_total < Decimal("0.01"):
            raise AppError(code="RED_PACKET_SETTING_INVALID", message="单个红包上限必须大于 0", status_code=422)
        row = SettingService(session_factory).set(RED_PACKET_MAX_TOTAL_KEY, f"{body.max_total:.2f}", actor_id=user_id, trace_id=trace(request))
        return {"key": row.key, "max_total": row.value, "updated_by": row.updated_by, "updated_at": row.updated_at}

    @router.get("/app-update-settings")
    def get_app_update_settings(user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        service = SettingService(session_factory)
        values = service.get_many(APP_UPDATE_SETTING_KEYS)
        return {
            "latest_version": values[APP_LATEST_VERSION_KEY],
            "latest_build": int(values[APP_LATEST_BUILD_KEY]) if values[APP_LATEST_BUILD_KEY] else None,
            "min_supported_build": int(values[APP_MIN_SUPPORTED_BUILD_KEY]) if values[APP_MIN_SUPPORTED_BUILD_KEY] else None,
            "notes": values[APP_UPDATE_NOTES_KEY],
            "apk_url": values[APP_APK_URL_KEY],
        }

    @router.put("/app-update-settings")
    def update_app_update_settings(body: AppUpdateSettingsBody, request: Request, idempotency_key: Annotated[str, Header(alias="Idempotency-Key", min_length=1, max_length=128)], user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        if body.min_supported_build > body.latest_build:
            raise AppError(code="APP_UPDATE_SETTING_INVALID", message="最低支持版本不能高于最新版本", status_code=422)
        service = SettingService(session_factory)
        payload = {
            APP_LATEST_VERSION_KEY: body.latest_version,
            APP_LATEST_BUILD_KEY: str(body.latest_build),
            APP_MIN_SUPPORTED_BUILD_KEY: str(body.min_supported_build),
            APP_UPDATE_NOTES_KEY: body.notes,
            APP_APK_URL_KEY: body.apk_url,
        }
        service.set_many(payload, actor_id=user_id, trace_id=trace(request))
        return {"status": "OK", "latest_version": body.latest_version, "latest_build": body.latest_build, "min_supported_build": body.min_supported_build, "idempotency_key": idempotency_key}

    @router.get("/session")
    def session_info(user_id: str = Depends(actor)):
        with session_factory() as session:
            user = session.get(User, user_id)
            if user is None or user.status != AccountStatus.ACTIVE:
                raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
            roles = [r.value for r in session.scalars(select(UserRole.role_code).where(UserRole.user_id == user_id))]
        return {"user_id": user_id, "username": user.username, "roles": roles, "permissions": sorted(p.value for p in rbac.permissions_for(user_id)), "brand": "ChatFlow", "display_name": "畅聊"}

    @router.get("/context")
    def context(request: Request, user_id: str = Depends(actor)):
        info = session_info(user_id)
        actual = set(info["permissions"])
        is_admin = "system.admin" in actual
        frontend_map = {
            "admin.finance.read": "finance.review",
            "admin.bans.read": "system.admin",
            "admin.support_roles.read": "support.scope.manage",
            "admin.analytics.read": "audit.view",
            "admin.presence.read": "support.ticket.assign",
            "admin.ads.read": "system.admin",
            "admin.notices.read": "system.admin",
            "admin.ledger.read": "audit.view",
            "admin.withdrawals.read": "finance.review",
            "admin.operations.create": "system.admin",
        }
        permissions = ["*"] if is_admin else [name for name, required in frontend_map.items() if required in actual]
        overview_data = {}
        if is_admin:
            overview_data = overview(request, user_id)
        modules = {}
        for name, required in MODULE_PERMISSIONS.items():
            if is_admin or required in actual:
                modules[name] = module_data(name, user_id).get("items", [])
        return {"actor": {"id": info["user_id"], "username": info["username"], "display_name": "畅聊管理员", "roles": info["roles"]}, "permissions": permissions, "overview": overview_data, "modules": modules}
    @router.get("/overview")
    def overview(request: Request, user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        with session_factory() as session:
            registered = session.scalar(select(func.count()).select_from(User)) or 0
            active = session.scalar(select(func.count()).select_from(User).where(User.status == AccountStatus.ACTIVE)) or 0
            online_cutoff = datetime.now(timezone.utc) - timedelta(minutes=5)
            online = session.scalar(select(func.count(func.distinct(Device.user_id))).join(User, User.id == Device.user_id).where(User.status == AccountStatus.ACTIVE, Device.revoked_at.is_(None), Device.last_seen_at >= online_cutoff)) or 0
            pending_withdrawals = session.scalar(select(func.count()).select_from(Withdrawal).where(Withdrawal.status.in_(("REQUESTED", "FINANCE_APPROVED")))) or 0
            today_start = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
            today_point_volume = session.scalar(select(func.coalesce(func.sum(func.abs(LedgerEntry.amount)), 0)).join(LedgerTransaction, LedgerEntry.transaction_id == LedgerTransaction.id).where(LedgerEntry.account_id.notlike("PLATFORM_%"), LedgerTransaction.created_at >= today_start)) or 0
        audit.record(actor_id=user_id, subject_type="admin", subject_id=user_id, action="admin.overview.viewed", result="SUCCESS", reason_code="ADMIN_DASHBOARD_VIEW", trace_id=getattr(request.state, "trace_id", "unknown"), source_ip=request.client.host if request.client else None)
        return {"registered_users": registered, "active_users": active, "online_customers": online, "pending_withdrawals": pending_withdrawals, "today_point_volume": f"{today_point_volume:.2f}", "brand": "ChatFlow"}

    @router.get("/modules/{module}")
    def module_data(module: str, user_id: str = Depends(actor)):
        permission = MODULE_PERMISSIONS.get(module)
        if permission is None:
            raise AppError(code="ADMIN_MODULE_NOT_FOUND", message="模块不存在", status_code=404)
        require(user_id, permission)
        with session_factory() as session:
            if module == "online":
                cutoff = datetime.now(timezone.utc) - timedelta(minutes=5)
                rows = session.execute(select(User, Device.last_seen_at).join(Device, Device.user_id == User.id).where(User.status == AccountStatus.ACTIVE, Device.revoked_at.is_(None), Device.last_seen_at >= cutoff).order_by(Device.last_seen_at.desc()).limit(100)).all()
                seen = set(); items = []
                for u, last_seen in rows:
                    if u.id in seen: continue
                    seen.add(u.id); items.append({"id": u.id, "username": u.username, "status": "在线", "last_seen_at": last_seen.isoformat()})
                return {"items": items, "module": module}
            if module == "analytics":
                rows = session.scalars(select(User).order_by(User.created_at.desc()).limit(100)).all()
                return {"items": [{"id": u.id, "username": u.username, "status": u.status.value, "created_at": u.created_at.isoformat()} for u in rows], "module": module}
            if module == "security":
                rows = session.scalars(select(User).order_by(User.updated_at.desc()).limit(100)).all()
                return {"module": module, "items": [{"id": u.id, "username": u.username, "status": u.status.value, "updated_at": u.updated_at.isoformat()} for u in rows]}
            if module == "support-role":
                rows = session.execute(select(User, UserRole.role_code).join(UserRole, UserRole.user_id == User.id).order_by(UserRole.assigned_at.desc()).limit(100)).all()
                return {"module": module, "items": [{"id": u.id, "username": u.username, "role": role.value, "assigned_at": next((r.assigned_at.isoformat() for r in session.scalars(select(UserRole).where(UserRole.user_id == u.id, UserRole.role_code == role).limit(1)).all()), None)} for u, role in rows]}
            if module == "finance":
                rows = session.scalars(select(AdjustmentRequest).order_by(AdjustmentRequest.created_at.desc()).limit(100)).all()
                return {"module": module, "items": [{"id": r.id, "user_id": r.user_id, "amount": f"{r.amount:.2f}", "status": r.status, "reason_code": r.reason_code, "created_at": r.created_at.isoformat()} for r in rows]}
            if module == "ledger":
                rows = session.execute(
                    select(LedgerTransaction, LedgerEntry)
                    .join(LedgerEntry, LedgerEntry.transaction_id == LedgerTransaction.id)
                    .order_by(LedgerTransaction.created_at.desc(), LedgerEntry.id.asc())
                    .limit(100)
                ).all()
                return {"module": module, "items": [
                    {
                        "transaction_id": tx.id,
                        "time": tx.created_at.isoformat(),
                        "user_id": entry.account_id,
                        "type": tx.scope,
                        "amount": f"{entry.amount:.2f}",
                        "reason_code": tx.reason_code,
                    }
                    for tx, entry in rows
                    if not entry.account_id.startswith("PLATFORM_")
                ]}
            if module == "wallet":
                rows = session.scalars(select(Withdrawal).order_by(Withdrawal.created_at.desc()).limit(100)).all()
                return {"module": module, "items": [
                    {
                        "id": withdrawal.id,
                        "user_id": withdrawal.user_id,
                        "amount": f"{withdrawal.amount:.6f}",
                        "status": withdrawal.status,
                        "address": _mask_wallet_address(withdrawal.address),
                        "created_at": withdrawal.created_at.isoformat(),
                    }
                    for withdrawal in rows
                ]}
            if module == "ads":
                rows = session.scalars(select(NativeMomentAd).order_by(NativeMomentAd.created_at.desc()).limit(100)).all()
                return {"module": module, "items": [
                    {
                        "id": ad.id,
                        "advertiser_name": ad.advertiser_name,
                        "text": ad.text,
                        "status": ad.status,
                        "created_at": ad.created_at.isoformat(),
                    }
                    for ad in rows
                ]}
            return {"items": [], "module": module}

    return router


def _mask_wallet_address(address: str) -> str:
    """Return a stable, non-sensitive display form for an on-chain address."""
    if len(address) <= 8:
        return "***"
    return f"{address[:1]}***{address[-4:]}"




