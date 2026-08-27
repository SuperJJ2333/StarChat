from typing import Annotated
from fastapi import APIRouter, Depends, Header, Request
from sqlalchemy import func, select
from app.core.config import Settings
from app.core.errors import AppError
from app.modules.identity.tokens import TokenService
from app.modules.identity.rbac import Permission, RbacService
from app.modules.identity.models import User, UserRole
from app.modules.identity.enums import AccountStatus
from app.modules.support.service import SupportAgentPresence
from app.modules.audit.writer import AuditWriter

MODULE_PERMISSIONS = {
    "users": Permission.SYSTEM_ADMIN,
    "support": Permission.SUPPORT_TICKET_ASSIGN,
    "ledger": Permission.AUDIT_VIEW,
    "wallet": Permission.FINANCE_REVIEW,
    "ads": Permission.SYSTEM_ADMIN,
    "announcements": Permission.SYSTEM_ADMIN,
    "audit": Permission.AUDIT_VIEW,
}

def create_admin_router(settings: Settings, session_factory) -> APIRouter:
    router = APIRouter(prefix="/admin", tags=["admin"])
    tokens = TokenService(session_factory, jwt_secret=settings.jwt_secret or "development-jwt-secret-at-least-thirty-two-bytes", jwt_issuer=settings.jwt_issuer, require_session_claims=settings.environment != "test")
    rbac = RbacService(session_factory)
    audit = AuditWriter(session_factory)

    def actor(authorization: Annotated[str | None, Header()] = None) -> str:
        if not authorization or not authorization.startswith("Bearer "):
            raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
        return str(tokens.decode_access_token(authorization[7:])["sub"])

    def require(actor_id: str, permission: Permission):
        rbac.require(actor_id, permission)

    @router.get("/session")
    def session_info(user_id: str = Depends(actor)):
        with session_factory() as session:
            user = session.get(User, user_id)
            if user is None or user.status != AccountStatus.ACTIVE:
                raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
            roles = [r.value for r in session.scalars(select(UserRole.role_code).where(UserRole.user_id == user_id))]
        return {"user_id": user_id, "username": user.username, "roles": roles, "permissions": sorted(p.value for p in rbac.permissions_for(user_id)), "brand": "ChatFlow", "display_name": "畅聊"}

    @router.get("/overview")
    def overview(request: Request, user_id: str = Depends(actor)):
        require(user_id, Permission.SYSTEM_ADMIN)
        with session_factory() as session:
            registered = session.scalar(select(func.count()).select_from(User)) or 0
            active = session.scalar(select(func.count()).select_from(User).where(User.status == AccountStatus.ACTIVE)) or 0
            online = session.scalar(select(func.count()).select_from(SupportAgentPresence).where(SupportAgentPresence.online.is_(True))) or 0
        audit.record(actor_id=user_id, subject_type="admin", subject_id=user_id, action="admin.overview.viewed", result="SUCCESS", reason_code="ADMIN_DASHBOARD_VIEW", trace_id=getattr(request.state, "trace_id", "unknown"), source_ip=request.client.host if request.client else None)
        return {"registered_users": registered, "active_users": active, "online_customers": online, "brand": "ChatFlow"}

    @router.get("/modules/{module}")
    def module_data(module: str, user_id: str = Depends(actor)):
        permission = MODULE_PERMISSIONS.get(module)
        if permission is None:
            raise AppError(code="ADMIN_MODULE_NOT_FOUND", message="模块不存在", status_code=404)
        require(user_id, permission)
        with session_factory() as session:
            if module == "users":
                rows = session.scalars(select(User).order_by(User.created_at.desc()).limit(100)).all()
                return {"items": [{"id": u.id, "username": u.username, "status": u.status.value, "created_at": u.created_at} for u in rows]}
            return {"items": [], "module": module}

    return router
