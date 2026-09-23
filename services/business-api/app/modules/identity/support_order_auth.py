"""Narrow financial identity policy for support orders, never owner repairs."""
from sqlalchemy import select
from app.core.errors import AppError
from app.modules.identity.enums import RoleCode
from app.modules.identity.models import User, UserRole
from app.modules.identity.staff_activation import require_staff_admin_access
from app.modules.identity.wallet_access import require_wallet_actor


def require_support_order_actor(session, *, claims, clock, owner_id):
    if claims.get('session_scope') != 'admin':
        raise AppError(code='PERMISSION_DENIED', message='需要客服管理会话', status_code=403)
    require_wallet_actor(session, user_id=claims['sub'], clock=clock)
    user = session.scalar(select(User).where(User.id == claims['sub']).with_for_update()
        .execution_options(populate_existing=True))
    require_staff_admin_access(session, user)
    roles = set(session.scalars(select(UserRole.role_code).where(UserRole.user_id == claims['sub']).with_for_update()))
    if RoleCode.FINANCE_SUPPORT not in roles and not (claims['sub'] == owner_id and RoleCode.SUPER_ADMIN in roles):
        raise AppError(code='PERMISSION_DENIED', message='需要财务客服权限', status_code=403)


class SupportOrderSessionAuthorizer:
    """Live management access for customer-service orders only; never a wallet grant.

    Financial callers keep the returned final check inside their own transaction.
    Lock order matches the existing financial engine: budget, user, session.
    """
    def __init__(self, settings, factory, clock):
        self.settings, self.factory, self.clock = settings, factory, clock

    def _identity(self, session, claims):
        from app.modules.identity.wallet_access import require_wallet_session
        from app.modules.ledger.reserve import lock_budget
        lock_budget(session)
        if not all(claims.get(key) for key in ('sub', 'device_id', 'family_id', 'iat', 'exp')):
            raise AppError(code='ACCESS_TOKEN_INVALID', message='访问令牌无效', status_code=401)
        require_support_order_actor(session, claims=claims, clock=self.clock,
            owner_id=self.settings.wallet_manual_owner_admin_id)
        return require_wallet_session(session, claims=claims, clock=self.clock,
            verified_at=None, require_recent=False, require_proof=False)

    def authorization(self, *, claims):
        def authorize(session):
            self._identity(session, claims)()
            def final():
                # Reread database state and deadlines after downstream lock waits.
                # This also checks account, role and activation changes, not just time.
                self._identity(session, claims)()
            return final
        return authorize

    def require(self, *, claims):
        with self.factory.begin() as session:
            self.authorization(claims=claims)(session)()

    def status(self, *, claims):
        with self.factory.begin() as session:
            final = self.authorization(claims=claims)(session)
            result = dict(enabled=True, verified=True, scope='support-orders',
                auth_mode='session', configured=True, grant_id=None, verified_at=None,
                expires_at=None, server_time=self.clock().isoformat())
            final()
            return result
