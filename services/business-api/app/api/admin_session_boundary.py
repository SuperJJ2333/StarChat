"""Authentication boundary for management routes, including legacy wallet paths."""
import re
from datetime import datetime, timezone

from fastapi import Request

from app.core.errors import AppError
from app.modules.identity.rbac import Permission, RbacService
from app.modules.identity.tokens import TokenService
from app.api.admin_wallet_auth import wallet_grant_service


WALLET_READ_ROUTE_TEMPLATES = frozenset({
    '/admin/modules/{module}',
    '/admin/wallet/reports/daily',
    '/wallet/reports/closed/{id}',
    '/wallet/incidents',
    '/wallet/incidents/{id}',
    '/wallet/monitor/status',
    '/wallet/chain/summary',
    '/wallet/chain/transactions',
    '/wallet/chain/transactions/{txid}/{log_index}',
    '/wallet/manual/payouts',
    '/wallet/manual/payouts/{order_id}',
    '/wallet/manual/operations/control',
    '/wallet/manual/operations/diagnostics',
    '/wallet/manual/handover/{id}',
    '/wallet/manual/deposit-repairs/candidates',
    '/wallet/manual/deposit-repairs/{operation_id}',
    '/wallet/manual/manual-deposit-cases/context',
    '/wallet/manual/manual-deposit-cases/operations/{operation_id}',
    '/wallet/manual/manual-deposit-cases/{case_id}',
    '/wallet/manual/payout-reconciliations/{operation_id}',
    '/wallet/manual/owner-transfers/{txid}',
})


def wallet_read_allowlist(request: Request) -> bool:
    route = request.scope.get('route')
    return getattr(route, 'path', None) in WALLET_READ_ROUTE_TEMPLATES


def wallet_management_path(path: str) -> bool:
    path = path.rstrip('/')
    # Credential bootstrap/rotation has its own explicit proof and session checks.
    if path in ('/api/v1/admin/wallet/security', '/api/v1/admin/wallet/security/operation-password'):
        return False
    return bool(path == '/api/v1/admin/modules/wallet'
        or path.startswith('/api/v1/admin/wallet/')
        or re.fullmatch(r'/api/v1/wallet/manual/payouts/[^/]+/(claim|adjust-rate|txid|correct-candidate)', path))


def management_path(path: str) -> bool:
    path = path.rstrip('/')
    return bool(
        path == '/api/v1/admin' or path.startswith('/api/v1/admin/')
        or re.fullmatch(r'/api/v1/wallet/manual/payouts/[^/]+/(claim|adjust-rate|txid|correct-candidate)', path)
        or re.fullmatch(r'/api/v1/wallet/withdrawals/[^/]+/(finance-approve|admin-approve|submit)', path)
        or path.startswith('/api/v1/recharge/admin/')
        or path.startswith('/api/v1/ledger/adjustments')
        or path.startswith('/api/v1/ledger/adjustment-policies')
        or re.fullmatch(r'/api/v1/support/tickets/[^/]+/(assign|transfer|close)', path)
        or re.fullmatch(r'/api/v1/support/agents/[^/]+/presence', path)
        or re.fullmatch(r'/api/v1/red-packets/[^/]+/cancel', path)
    )


def create_admin_session_boundary(settings, session_factory):
    tokens = TokenService(session_factory,
        jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer, require_session_claims=settings.environment != 'test')

    def require_admin_session(request: Request):
        if not management_path(request.url.path):
            return
        authorization = request.headers.get('authorization', '')
        if not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED', message='需要登录', status_code=401)
        claims = tokens.decode_access_token(authorization[7:])
        # Existing fixture-only JWTs are accepted solely in the explicit test runtime.
        # Real ordinary sessions (including test-issued sessions) never bypass this gate.
        if settings.environment == 'test' and not claims.get('family_id'):
            return
        tokens.admin_session(authorization[7:])
        if getattr(settings, 'wallet_access_grant_enabled', False) and wallet_management_path(request.url.path):
            grant = wallet_grant_service(settings, session_factory, lambda: datetime.now(timezone.utc))
            if request.method in {'GET', 'HEAD'} and wallet_read_allowlist(request):
                grant.require_read(claims=claims)
                # The handler may wait on a database or chain observer after this
                # gate. Recheck before any successful response is sent.
                request.state.wallet_read_token = authorization[7:]
            else:
                grant.require(claims=claims)

    return require_admin_session


def install_wallet_read_response_guard(app, settings, session_factory) -> None:
    """Stop a wallet read if the owner/session is revoked during its handler."""
    tokens = TokenService(session_factory,
        jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer, require_session_claims=settings.environment != 'test')

    @app.middleware('http')
    async def wallet_read_response_guard(request: Request, call_next):
        response = await call_next(request)
        token = getattr(request.state, 'wallet_read_token', None)
        if token is None or response.status_code >= 400:
            return response
        try:
            claims = tokens.decode_access_token(token)
            tokens.admin_session(token)
            wallet_grant_service(settings, session_factory,
                lambda: datetime.now(timezone.utc)).require_read(claims=claims)
        except AppError as exc:
            return await app.exception_handlers[AppError](request, exc)
        return response


def install_admin_directory_response_guard(app, settings, session_factory) -> None:
    """Recheck admin-only directory access before any successful payload is sent."""
    tokens = TokenService(session_factory,
        jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer, require_session_claims=settings.environment != 'test')
    rbac = RbacService(session_factory)

    @app.middleware('http')
    async def admin_directory_response_guard(request: Request, call_next):
        response = await call_next(request)
        token = getattr(request.state, 'admin_directory_token', None)
        if token is None or response.status_code >= 400:
            return response
        try:
            session = tokens.admin_session(token)
            rbac.require(session['user_id'], Permission.SYSTEM_ADMIN)
        except AppError as exc:
            denied = await app.exception_handlers[AppError](request, exc)
            denied.headers['Cache-Control'] = 'no-store'
            return denied
        return response
