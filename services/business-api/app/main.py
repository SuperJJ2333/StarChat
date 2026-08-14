from fastapi import FastAPI

from app.api.health import create_health_router
from app.api.identity import create_identity_router
from app.api.support import create_support_router
from app.api.ledger import create_ledger_router
from app.api.redpacket import create_redpacket_router
from app.api.wallet import create_wallet_router
from app.api.friendship import create_friendship_router
from app.api.moments import create_moments_router
from app.core.config import Settings
from app.core.database import create_engine, create_session_factory
from app.core.errors import ErrorEnvelope, install_error_handlers
from app.core.tracing import install_trace_middleware
from app.core.rate_limits import NoopRateLimiter, RedisRateLimiter
from app.integrations.matrix_admin import SynapseMatrixAdminGateway


def create_app(
    settings: Settings,
    session_factory=None,
    rate_limiter=None,
    matrix_gateway=None,
) -> FastAPI:
    app = FastAPI(
        title=settings.app_name,
        version="0.1.0",
        responses={
            400: {"model": ErrorEnvelope, "description": "Application error"},
            422: {"model": ErrorEnvelope, "description": "Validation error"},
            500: {"model": ErrorEnvelope, "description": "Internal error"},
        },
    )
    if session_factory is None:
        engine = create_engine(settings)
        session_factory = create_session_factory(engine)
        app.state.engine = engine
    app.state.session_factory = session_factory
    if rate_limiter is None:
        rate_limiter = (
            NoopRateLimiter()
            if settings.environment == "test"
            else RedisRateLimiter.from_url(settings.redis_url)
        )
    app.state.rate_limiter = rate_limiter
    if matrix_gateway is None:
        matrix_gateway = SynapseMatrixAdminGateway(
            homeserver_url=settings.matrix_homeserver_url,
            server_name=settings.matrix_server_name,
            admin_access_token=settings.synapse_admin_access_token or "",
        )
    install_trace_middleware(app)
    install_error_handlers(app)
    app.include_router(
        create_health_router(settings, session_factory=session_factory),
        prefix="/api/v1",
    )
    app.include_router(
        create_identity_router(
            settings,
            session_factory,
            rate_limiter,
            matrix_gateway=matrix_gateway,
        ),
        prefix="/api/v1",
    )
    app.include_router(create_support_router(settings, session_factory), prefix="/api/v1")
    app.include_router(create_ledger_router(settings, session_factory), prefix="/api/v1")
    app.include_router(create_redpacket_router(settings, session_factory), prefix="/api/v1")
    app.include_router(create_wallet_router(settings, session_factory), prefix="/api/v1")
    app.include_router(create_friendship_router(settings, session_factory), prefix="/api/v1")
    app.include_router(create_moments_router(settings, session_factory), prefix="/api/v1")
    return app


def create_default_app() -> FastAPI:
    return create_app(Settings())




