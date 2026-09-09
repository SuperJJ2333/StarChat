"""Authentication boundary for management routes, including legacy wallet paths."""
import re

from fastapi import Request

from app.core.errors import AppError
from app.modules.identity.tokens import TokenService


def management_path(path: str) -> bool:
    path = path.rstrip('/')
    return bool(
        path == '/api/v1/admin' or path.startswith('/api/v1/admin/')
        or re.fullmatch(r'/api/v1/wallet/manual/payouts/[^/]+/(claim|txid|correct-candidate)', path)
        or re.fullmatch(r'/api/v1/wallet/withdrawals/[^/]+/(finance-approve|admin-approve|submit)', path)
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

    return require_admin_session
