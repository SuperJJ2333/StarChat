from fastapi import FastAPI

from app.api.health import create_health_router
from app.core.config import Settings
from app.core.database import create_engine, create_session_factory
from app.core.errors import ErrorEnvelope, install_error_handlers
from app.core.tracing import install_trace_middleware


def create_app(settings: Settings, session_factory=None) -> FastAPI:
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
    install_trace_middleware(app)
    install_error_handlers(app)
    app.include_router(
        create_health_router(settings, session_factory=session_factory),
        prefix="/api/v1",
    )
    return app


def create_default_app() -> FastAPI:
    return create_app(Settings())
