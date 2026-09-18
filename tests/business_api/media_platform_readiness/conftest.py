"""Shared fixtures for the Media Engine production-readiness validation.

These suites are *verification instruments*: they do not add product features. They exercise
the Phase 4 implementation against the frozen ADRs and the readiness checklist, on an
in-memory SQLite database plus a temporary private-object directory — the same harness the
Phase 4 suites use, so results are comparable.
"""

from __future__ import annotations

from datetime import datetime, timezone

from httpx import ASGITransport, AsyncClient
import pytest
from sqlalchemy import create_engine, event
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.integrations.private_storage import LocalPrivateObjectStorage
from app.main import create_app
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.tokens import TokenService
from app.modules.media.storage import LocalBlobBackend

JWT_SECRET = "test-jwt-secret-at-least-thirty-two-bytes"
MEDIA_SECRET = "readiness-media-url-signing-secret-32b"

USERS = (("user-a", "usera"), ("user-b", "userb"), ("user-c", "userc"))


def _create_user(session, user_id: str, username: str, now: datetime) -> None:
    session.add(
        User(
            id=user_id,
            username=username,
            username_normalized=username,
            email=f"{username}@example.com",
            email_normalized=f"{username}@example.com",
            password_hash="hash",
            status=AccountStatus.ACTIVE,
            email_verified_at=now,
            created_at=now,
            updated_at=now,
        )
    )


def media_test_engine():
    """SQLite, in memory, **with foreign keys enforced**.

    SQLite ignores foreign keys unless ``PRAGMA foreign_keys=ON`` is set per connection, and
    production is PostgreSQL where they are always enforced. The deployment rehearsal found an
    insert-order bug (`media_blobs_object_id_fkey`) that every SQLite suite had been hiding;
    the readiness instrument therefore runs with the same constraint behaviour as production.
    """

    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )

    @event.listens_for(engine, "connect")
    def _enforce_foreign_keys(dbapi_connection, _record):  # pragma: no cover - plumbing
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.close()

    return engine


@pytest.fixture()
def platform(tmp_path):
    engine = media_test_engine()
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for user_id, username in USERS:
            _create_user(session, user_id, username, now)

    root = str(tmp_path / "private-media")
    backend = LocalBlobBackend(root=root)
    storage = LocalPrivateObjectStorage(
        root=root,
        signing_secret="test-media-signing-secret-32-bytes",
        public_base_url="http://mediatest.local",
    )
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://unused",
        jwt_secret=JWT_SECRET,
        email_verification_secret="test-email-verification-secret",
        password_reset_secret="test-password-reset-secret",
        avatar_storage_root=root,
        media_url_signing_secret=MEDIA_SECRET,
        media_ttl_private_seconds=60,
        media_ttl_audience_seconds=600,
        media_ttl_public_seconds=86400,
        media_orphan_grace_seconds=3600,
        media_e2ee_retention_floor_seconds=30 * 24 * 3600,
    )
    app = create_app(settings, session_factory=factory, avatar_storage=storage)
    tokens = TokenService(factory, jwt_secret=JWT_SECRET, jwt_issuer="liuhetong")
    headers = {
        user_id: {
            "Authorization": "Bearer "
            + tokens.issue_pair(
                user_id=user_id, device_key=f"device-{user_id}", display_name=user_id
            ).access_token
        }
        for user_id, _ in USERS
    }

    class Env:
        def __init__(self) -> None:
            self.app = app
            self.factory = factory
            self.backend = backend
            self.storage = storage
            self.settings = settings
            self.headers = headers
            self.root = root

        def client(self) -> AsyncClient:
            return AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local")

        def ingest(self, **kwargs):
            """Direct ingest for data-plane tests (no HTTP round trip)."""

            return ingest_object(factory, backend, **kwargs)

    yield Env()
    engine.dispose()


def ingest_object(factory, backend, *, owner="user-a", content=b"readiness" * 512, kind=None, visibility=None):
    """Direct ingest helper (bypasses HTTP) for data-plane tests."""

    from app.modules.media.domain import DigestKind, MediaKind, VisibilityTier
    from app.modules.media.repository import IngestRequest, MediaRepository

    repository = MediaRepository(factory, backend=backend)
    return repository.ingest(
        IngestRequest(
            owner_id=owner,
            origin_domain="moments",
            kind=kind or MediaKind.IMAGE,
            mime="image/jpeg",
            content=content,
            digest_kind=DigestKind.PLAINTEXT,
            visibility=visibility or VisibilityTier.PRIVATE,
        )
    )
