from enum import StrEnum

from sqlalchemy import select

from app.core.errors import AppError
from app.modules.identity.enums import RoleCode
from app.modules.identity.models import UserRole


class Permission(StrEnum):
    SUPPORT_TICKET_ASSIGN = "support.ticket.assign"
    SUPPORT_TICKET_TRANSFER = "support.ticket.transfer"
    SUPPORT_SCOPE_MANAGE = "support.scope.manage"
    ADJUSTMENT_SUBMIT = "adjustment.submit"
    FINANCE_REVIEW = "finance.review"
    FINANCE_ADJUSTMENT_SUBMIT = "finance.adjustment.submit"
    SUPERVISOR_APPROVE = "supervisor.approve"
    AUDIT_VIEW = "audit.view"
    SYSTEM_ADMIN = "system.admin"


ROLE_PERMISSIONS: dict[RoleCode, frozenset[Permission]] = {
    RoleCode.USER: frozenset(),
    RoleCode.SUPPORT_AGENT: frozenset(
        {Permission.SUPPORT_TICKET_ASSIGN, Permission.SUPPORT_TICKET_TRANSFER, Permission.ADJUSTMENT_SUBMIT}
    ),
    RoleCode.FINANCE_SUPPORT: frozenset(
        {Permission.FINANCE_REVIEW, Permission.FINANCE_ADJUSTMENT_SUBMIT}
    ),
    RoleCode.SUPPORT_SUPERVISOR: frozenset(
        {
            Permission.SUPPORT_TICKET_ASSIGN,
            Permission.SUPPORT_TICKET_TRANSFER,
            Permission.SUPPORT_SCOPE_MANAGE,
            Permission.SUPERVISOR_APPROVE,
            Permission.AUDIT_VIEW,
        }
    ),
    RoleCode.SUPER_ADMIN: frozenset(Permission),
}


class RbacService:
    def __init__(self, session_factory) -> None:
        self._session_factory = session_factory

    def permissions_for(self, user_id: str) -> frozenset[Permission]:
        with self._session_factory() as session:
            roles = session.scalars(
                select(UserRole.role_code).where(UserRole.user_id == user_id)
            )
            permissions: set[Permission] = set()
            for role in roles:
                permissions.update(ROLE_PERMISSIONS.get(role, frozenset()))
            return frozenset(permissions)

    def require(self, user_id: str, permission: Permission | str) -> None:
        try:
            declared = Permission(permission)
        except ValueError:
            self._denied()
        if declared not in self.permissions_for(user_id):
            self._denied()

    @staticmethod
    def _denied() -> None:
        raise AppError(code="PERMISSION_DENIED", message="无权执行此操作", status_code=403)

