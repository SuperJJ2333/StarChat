"""The live profile, friendship, and Moments projections share avatar signing."""

from datetime import datetime, timedelta, timezone
from hashlib import sha256
from urllib.parse import parse_qs, urlsplit, urlunsplit

import httpx
import jwt
import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.integrations.private_storage import LocalPrivateObjectStorage
from app.main import create_app
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User


def _bearer(settings: Settings, user_id: str) -> dict[str, str]:
    now = datetime.now(timezone.utc)
    token = jwt.encode(
        {
            "sub": user_id,
            "iss": settings.jwt_issuer,
            "iat": int(now.timestamp()),
            "exp": int((now + timedelta(minutes=5)).timestamp()),
        },
        settings.jwt_secret,
        algorithm="HS256",
    )
    return {"Authorization": f"Bearer {token}"}


def _version(url: str, key: str) -> None:
    parts = urlsplit(url)
    assert parts.scheme == "http" and parts.netloc == "test"
    assert "/api/v1/profile/avatar/content/" in parts.path
    assert key not in url
    assert parse_qs(parts.query) == {
        "expires_in": ["300"],
        "v": [sha256(key.encode("utf-8")).hexdigest()[:32]],
    }


@pytest.mark.asyncio
async def test_local_storage_versions_all_avatar_projections_and_keeps_legacy_routes(tmp_path):
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    settings = Settings(_env_file=None, environment="test", jwt_secret="x" * 32)
    storage = LocalPrivateObjectStorage(
        root=str(tmp_path / "private"),
        signing_secret="test-avatar-signing-secret",
        public_base_url="http://test",
    )
    alice_key = "avatars/u1/one.png"
    bob_key = "avatars/u2/one.png"
    storage.put(alice_key, b"alice-image")
    storage.put(bob_key, b"bob-image")
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for user_id, name, key in (
            ("u1", "alice", alice_key),
            ("u2", "bob", bob_key),
        ):
            session.add(
                User(
                    id=user_id,
                    username=name,
                    username_normalized=name,
                    email=f"{name}@example.test",
                    email_normalized=f"{name}@example.test",
                    password_hash="hash",
                    status=AccountStatus.ACTIVE,
                    matrix_user_id=f"@{name}:matrix.example.test",
                    nickname=name.title(),
                    avatar_object_key=key,
                    profile_updated_at=now,
                    created_at=now,
                    updated_at=now,
                )
            )
    app = create_app(settings, session_factory=factory, avatar_storage=storage)
    try:
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test"
        ) as client:
            alice = _bearer(settings, "u1")
            bob = _bearer(settings, "u2")
            own = await client.get("/api/v1/profile/me", headers=alice)
            assert own.status_code == 200, own.text
            own_url = own.json()["avatar_url"]
            _version(own_url, alice_key)

            public = await client.get(
                "/api/v1/users/lookup",
                params={"matrix_user_id": "@bob:matrix.example.test"},
                headers=alice,
            )
            assert public.status_code == 200, public.text
            _version(public.json()["avatar_url"], bob_key)
            search = await client.get("/api/v1/users/search?q=bob", headers=alice)
            assert search.status_code == 200, search.text
            _version(search.json()["items"][0]["avatar_url"], bob_key)

            created = await client.post(
                "/api/v1/friends/requests",
                headers={**alice, "Idempotency-Key": "avatar-projection-request"},
                json={"target_user_id": "u2"},
            )
            assert created.status_code == 201, created.text
            requests = await client.get("/api/v1/friends/requests", headers=bob)
            assert requests.status_code == 200, requests.text
            _version(requests.json()["items"][0]["avatar_url"], alice_key)
            accepted = await client.post(
                f"/api/v1/friends/requests/{created.json()['id']}/accept",
                headers={**bob, "Idempotency-Key": "avatar-projection-accept"},
            )
            assert accepted.status_code == 200, accepted.text
            friends = await client.get("/api/v1/friends", headers=alice)
            assert friends.status_code == 200, friends.text
            _version(friends.json()["items"][0]["avatar_url"], bob_key)

            moment = await client.post(
                "/api/v1/moments",
                headers={**bob, "Idempotency-Key": "avatar-projection-moment"},
                json={"text": "avatar", "visibility": "FRIENDS"},
            )
            assert moment.status_code == 201, moment.text
            _version(moment.json()["author"]["avatar_url"], bob_key)
            feed = await client.get("/api/v1/moments/feed", headers=alice)
            assert feed.status_code == 200, feed.text
            _version(feed.json()["items"][0]["author"]["avatar_url"], bob_key)

            replacement_key = "avatars/u2/two.png"
            storage.put(replacement_key, b"new-bob-image")
            with factory.begin() as session:
                session.get(User, "u2").avatar_object_key = replacement_key
            replaced = await client.get("/api/v1/users/search?q=bob", headers=alice)
            assert replaced.status_code == 200, replaced.text
            replaced_url = replaced.json()["items"][0]["avatar_url"]
            _version(replaced_url, replacement_key)
            assert parse_qs(urlsplit(replaced_url).query)["v"] != parse_qs(
                urlsplit(search.json()["items"][0]["avatar_url"]).query
            )["v"]
            refreshed_feed = await client.get("/api/v1/moments/feed", headers=alice)
            assert refreshed_feed.status_code == 200, refreshed_feed.text
            _version(
                refreshed_feed.json()["items"][0]["author"]["avatar_url"],
                replacement_key,
            )

            # Links issued before `v` was added still read the same private bytes.
            parts = urlsplit(own_url)
            legacy = urlunsplit(
                (parts.scheme, parts.netloc, parts.path, "expires_in=300", "")
            )
            legacy_response = await client.get(legacy)
            assert legacy_response.status_code == 200, legacy_response.text
            assert legacy_response.content == b"alice-image"

            cover_key = "moments/covers/u1/cover.png"
            storage.put(cover_key, b"cover-image")
            cover_url = storage.signed_read_url(cover_key, 300)
            assert "v" not in parse_qs(urlsplit(cover_url).query)
            cover_response = await client.get(cover_url)
            assert cover_response.status_code == 200, cover_response.text
            assert cover_response.content == b"cover-image"
    finally:
        engine.dispose()
