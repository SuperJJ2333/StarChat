"""Narrow financial identity policy for support orders, never owner repairs."""
from datetime import timedelta
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


def fresh_owner_proof_authorization(settings, factory, clock, claims, body, *,
                                    mfa_verifier=None, rate_limiter=None):
    """Verify the configured owner for this request, then recheck before commit.

    An existing wallet read grant is deliberately irrelevant to a takeover.
    The returned callback runs inside the financial command's locked transaction.
    """
    owner_id = settings.wallet_manual_owner_admin_id
    if not owner_id or claims.get('sub') != owner_id or body is None:
        raise AppError(code='PERMISSION_DENIED', message='仅官方钱包所有者管理员可接管', status_code=403)

    def require_owner(session):
        if (settings.wallet_manual_owner_admin_id != owner_id
                or session.scalar(select(UserRole.id).where(
                    UserRole.user_id == owner_id,
                    UserRole.role_code == RoleCode.SUPER_ADMIN).with_for_update()) is None):
            raise AppError(code='PERMISSION_DENIED', message='仅官方钱包所有者管理员可接管', status_code=403)

    def owner_checked(authorize):
        def checked(session):
            if settings.wallet_admin_auth_mode != mode:
                raise AppError(code='ADMIN_WALLET_AUTH_MODE_MISMATCH',
                    message='钱包验证方式已变化，请重新验证', status_code=403)
            final = authorize(session)
            require_owner(session)
            def recheck():
                if settings.wallet_admin_auth_mode != mode:
                    raise AppError(code='ADMIN_WALLET_AUTH_MODE_MISMATCH',
                        message='钱包验证方式已变化，请重新验证', status_code=403)
                final()
                require_owner(session)
            return recheck
        return checked

    mode = settings.wallet_admin_auth_mode
    if mode == 'operation_password':
        if body.mfa_proof is not None or body.operation_password is None:
            raise AppError(code='ADMIN_WALLET_AUTH_MODE_MISMATCH',
                message='请选择当前钱包验证方式', status_code=403)
        from app.modules.identity.operation_password import AdminWalletOperationPasswordService
        service = AdminWalletOperationPasswordService(factory,
            owner_id=lambda: settings.wallet_manual_owner_admin_id,
            auth_mode=lambda: settings.wallet_admin_auth_mode,
            clock=clock, scope='support-orders')
        proof = service.verify(claims=claims,
            operation_password=body.operation_password.get_secret_value(),
            grant_verification=True)
        return owner_checked(service.authorization(claims=claims, proof=proof,
            grant_verification=True))

    if mode == 'totp':
        if body.operation_password is not None or body.mfa_proof is None:
            raise AppError(code='ADMIN_WALLET_AUTH_MODE_MISMATCH',
                message='请选择当前钱包验证方式', status_code=403)
        sessions = SupportOrderSessionAuthorizer(settings, factory, clock)
        with factory.begin() as session:
            final = sessions.authorization(claims=claims)(session)
            require_owner(session)
            final()
        verifier = mfa_verifier
        if verifier is None:
            from app.modules.identity.totp import FernetSecretProtector, TotpService
            from app.modules.wallet.binding_adapters import WalletTotpVerifier
            key = getattr(settings, 'wallet_totp_encryption_key', None)
            if key is None or rate_limiter is None:
                raise AppError(code='WALLET_MFA_NOT_CONFIGURED',
                    message='动态验证尚未配置', status_code=503)
            verifier = WalletTotpVerifier(TotpService(factory, protector=FernetSecretProtector(
                key.get_secret_value().encode('ascii'))), rate_limiter, clock=clock)
        if verifier(user_id=owner_id, session_id=claims['family_id'],
                    proof=body.mfa_proof.get_secret_value(), now=clock()) is not True:
            raise AppError(code='TOTP_REQUIRED', message='需要重新验证动态验证码', status_code=403)
        verified_at = clock()
        from app.modules.identity.wallet_access import require_wallet_session
        def authorize(session):
            current_session = sessions.authorization(claims=claims)(session)
            current_proof = require_wallet_session(session, claims=claims, clock=clock,
                verified_at=verified_at, require_recent=False)
            def final():
                current_session()
                current_proof()
            return final
        return owner_checked(authorize)

    raise AppError(code='ADMIN_WALLET_AUTH_MODE_MISMATCH',
        message='钱包验证方式不可用', status_code=403)
