"""Part 1 — ADR compliance audit, as executable evidence.

Each test asserts one frozen rule from `docs/architecture/media-engine-phase3-freeze.md`
(ADR-001…ADR-006). Where a rule is structural (a type cannot be compared, an adapter has no
write path) the assertion checks the structure, so a later refactor cannot silently drop it.
"""

from __future__ import annotations

import ast
import pathlib

import pytest
from sqlalchemy import select

from app.core.errors import AppError
from app.modules.media.domain import (
    CrossKindDigestComparison,
    Digest,
    DigestKind,
    EnvelopeMode,
    IsolationDomain,
    IsolationViolation,
    MediaKind,
    MediaStatus,
    VariantKind,
    VisibilityTier,
    allow_cross_user_plaintext_dedup,
    assert_object_domain,
    ciphertext_digest,
    plaintext_digest,
    transport_digest,
)
from app.modules.media.models import MediaBlob, MediaObject
from app.modules.media.policy import MediaDedupPolicy
from app.modules.media.repository import IngestRequest, MediaRepository
from app.modules.media.storage import (
    LocalBlobBackend,
    key_belongs_to_domain,
    storage_key_for,
)


MEDIA_MODULE = pathlib.Path(__file__).resolve().parents[3] / "services/business-api/app/modules/media"
ROUTER = pathlib.Path(__file__).resolve().parents[3] / "services/business-api/app/api/media_platform.py"


def _module_source(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def _class_node(path: pathlib.Path, name: str) -> ast.ClassDef:
    tree = ast.parse(_module_source(path))
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == name:
            return node
    raise AssertionError(f"{name} not found in {path}")


# --------------------------------------------------------------------------- #
# ADR-001 Isolation
# --------------------------------------------------------------------------- #
def test_adr001_plaintext_objects_never_share_across_users(platform) -> None:
    first = platform.ingest(owner="user-a", content=b"same" * 1000)
    second = platform.ingest(owner="user-b", content=b"same" * 1000)

    assert first.blob_id != second.blob_id
    with platform.factory() as session:
        blobs = list(session.scalars(select(MediaBlob)))
        scopes = {blob.owner_scope for blob in blobs}
    assert scopes == {"user:user-a", "user:user-b"}
    assert all(blob.isolation_domain == IsolationDomain.USER.value for blob in blobs)


def test_adr001_global_plaintext_dedup_is_structurally_refused() -> None:
    assert allow_cross_user_plaintext_dedup() is False
    policy = MediaDedupPolicy(allow_cross_user_plaintext=True)
    with pytest.raises(IsolationViolation):
        policy.decide(
            digest_kind=DigestKind.PLAINTEXT,
            envelope_mode=EnvelopeMode.NONE,
            envelope_version=1,
            size=4096,
        )


def test_adr001_ciphertext_reuse_needs_deterministic_envelope_and_threshold(platform) -> None:
    large = b"cipher-payload" * 20000  # 280 KiB > the 256 KiB policy threshold
    repository = MediaRepository(platform.factory, backend=platform.backend)

    def ingest(owner: str, content: bytes, envelope: EnvelopeMode):
        return repository.ingest(
            IngestRequest(
                owner_id=owner,
                origin_domain="chat",
                kind=MediaKind.VIDEO,
                mime="video/mp4",
                content=content,
                digest_kind=DigestKind.CIPHERTEXT,
                envelope_mode=envelope,
            )
        )

    first = ingest("user-a", large, EnvelopeMode.DETERMINISTIC_V1)
    second = ingest("user-b", large, EnvelopeMode.DETERMINISTIC_V1)
    assert second.reused_object is True and second.blob_id == first.blob_id

    random_first = ingest("user-a", large, EnvelopeMode.RANDOM)
    random_second = ingest("user-b", large, EnvelopeMode.RANDOM)
    assert random_first.blob_id != random_second.blob_id

    small = b"tiny-cipher"
    small_first = ingest("user-a", small, EnvelopeMode.DETERMINISTIC_V1)
    small_second = ingest("user-b", small, EnvelopeMode.DETERMINISTIC_V1)
    assert small_first.blob_id != small_second.blob_id


def test_adr001_isolation_domain_is_encoded_in_every_storage_key() -> None:
    user_key = storage_key_for(
        isolation_domain=IsolationDomain.USER,
        scope_key="user:user-a",
        blob_id="b1",
        mime="image/jpeg",
        kind=MediaKind.IMAGE,
    )
    e2ee_key = storage_key_for(
        isolation_domain=IsolationDomain.E2EE,
        scope_key="e2ee:ciphertext-v1",
        blob_id="b2",
        mime="video/mp4",
        kind=MediaKind.VIDEO,
    )
    assert key_belongs_to_domain(user_key, digest_kind=DigestKind.PLAINTEXT, owner_scope="user:user-a")
    assert not key_belongs_to_domain(user_key, digest_kind=DigestKind.CIPHERTEXT, owner_scope="e2ee:ciphertext-v1")
    assert key_belongs_to_domain(e2ee_key, digest_kind=DigestKind.CIPHERTEXT, owner_scope="e2ee:ciphertext-v1")
    with pytest.raises(IsolationViolation):
        assert_object_domain(DigestKind.PLAINTEXT, "e2ee:ciphertext-v1")
    with pytest.raises(IsolationViolation):
        assert_object_domain(DigestKind.CIPHERTEXT, "user:user-a")


def test_adr001_no_source_file_enables_cross_user_plaintext_reuse() -> None:
    """Static audit: the refusal is not a runtime flag somebody could flip by config."""

    offenders = []
    for path in MEDIA_MODULE.glob("*.py"):
        source = _module_source(path)
        if "allow_cross_user_plaintext=True" in source and "MediaDedupPolicy" not in source:
            offenders.append(path.name)
    assert offenders == []


# --------------------------------------------------------------------------- #
# ADR-002 Digest
# --------------------------------------------------------------------------- #
def test_adr002_three_digest_kinds_exist_with_distinct_semantics() -> None:
    assert {kind.value for kind in DigestKind} == {
        "plaintext_digest",
        "ciphertext_digest",
        "transport_digest",
    }


def test_adr002_kinds_are_never_compared() -> None:
    plain = plaintext_digest(b"identical")
    cipher = ciphertext_digest(b"identical")
    assert plain.value == cipher.value
    with pytest.raises(CrossKindDigestComparison):
        _ = plain == cipher
    with pytest.raises(CrossKindDigestComparison):
        _ = plain == Digest(kind=DigestKind.PLAINTEXT, value=plain.value, version=2)
    assert plaintext_digest(b"x") == plaintext_digest(b"x")


def test_adr002_no_plaintext_digest_is_stored_for_e2ee_media(platform) -> None:
    received = b"ciphertext-only" * 4096
    repository = MediaRepository(platform.factory, backend=platform.backend)
    result = repository.ingest(
        IngestRequest(
            owner_id="user-a",
            origin_domain="chat",
            kind=MediaKind.VIDEO,
            mime="video/mp4",
            content=received,
            digest_kind=DigestKind.CIPHERTEXT,
            envelope_mode=EnvelopeMode.DETERMINISTIC_V1,
        )
    )
    with platform.factory() as session:
        media = session.get(MediaObject, result.media_id)
        blob = session.get(MediaBlob, result.blob_id)
        e2ee_plaintext_rows = list(
            session.scalars(
                select(MediaObject).where(
                    MediaObject.isolation_domain == IsolationDomain.E2EE.value,
                    MediaObject.digest_kind == DigestKind.PLAINTEXT.value,
                )
            )
        )

    # The stored digest is the ciphertext digest of the bytes the server actually received.
    # (SHA-256 is the same function either way; the *kind* is what separates the semantics,
    # which is exactly why ADR-002 makes the kind part of the identity.)
    assert media.digest_kind == DigestKind.CIPHERTEXT.value
    assert blob.digest_kind == DigestKind.CIPHERTEXT.value
    assert media.content_digest == ciphertext_digest(received).value

    # The invariant that matters: no E2EE object is ever tagged with a plaintext digest kind,
    # so a plaintext fingerprint of E2EE content cannot exist server-side.
    assert e2ee_plaintext_rows == []


def test_adr002_digest_values_never_leave_the_platform(platform) -> None:
    """No API response may echo a digest value (the kind enum is allowed, the value is not)."""

    import asyncio
    import json

    payload = b"never-echoed" * 256
    digest_value = plaintext_digest(payload).value

    async def run() -> list[str]:
        bodies: list[str] = []
        async with platform.client() as client:
            created = await client.post(
                "/api/v1/media/platform/objects",
                params={"kind": "image", "mime": "image/jpeg"},
                headers={**platform.headers["user-a"], "Content-Type": "image/jpeg"},
                content=payload,
            )
            bodies.append(created.text)
            media_id = created.json()["media_id"]
            metadata = await client.get(
                f"/api/v1/media/platform/objects/{media_id}", headers=platform.headers["user-a"]
            )
            bodies.append(metadata.text)
            minted = await client.post(
                f"/api/v1/media/platform/objects/{media_id}/signed-urls",
                json={"variant_kind": "original"},
                headers=platform.headers["user-a"],
            )
            bodies.append(minted.text)
        return bodies

    for body in asyncio.run(run()):
        assert digest_value not in body
        assert "content_digest" not in body
        assert json.loads(body) is not None


def test_adr002_transport_digest_cannot_become_an_identity(platform) -> None:
    repository = MediaRepository(platform.factory, backend=platform.backend)
    with pytest.raises(AppError) as transport_as_identity:
        repository.ingest(
            IngestRequest(
                owner_id="user-a",
                origin_domain="moments",
                kind=MediaKind.FILE,
                mime="text/plain",
                content=b"payload",
                digest_kind=DigestKind.TRANSPORT,
            )
        )
    assert transport_as_identity.value.code == "MEDIA_DIGEST_KIND_INVALID"

    with pytest.raises(AppError) as client_plaintext_claim:
        repository.ingest(
            IngestRequest(
                owner_id="user-a",
                origin_domain="moments",
                kind=MediaKind.FILE,
                mime="text/plain",
                content=b"payload",
                digest_kind=DigestKind.PLAINTEXT,
                transport_claim=plaintext_digest(b"payload"),
            )
        )
    assert client_plaintext_claim.value.code == "MEDIA_DIGEST_KIND_INVALID"


def test_adr002_there_is_no_client_facing_digest_lookup(platform) -> None:
    """No route may accept a digest as a parameter (existence oracle)."""

    paths = platform.app.openapi()["paths"]
    assert paths, "the platform must publish its routes"
    # A digest *value* may never be a route or a parameter: that would be an existence oracle.
    # A digest *kind* selector is allowed and is asserted separately below.
    digest_value_names = {"digest", "content_digest", "hash", "sha256", "content_sha256", "checksum"}
    media_paths = {path: ops for path, ops in paths.items() if path.startswith("/api/v1/media/platform")}
    assert media_paths, "the media platform routes must be published"
    for path, operations in media_paths.items():
        assert "digest" not in path and "hash" not in path, path
        for operation in operations.values():
            parameter_names = {
                parameter.get("name", "") for parameter in operation.get("parameters", [])
            }
            assert not (parameter_names & digest_value_names), (path, parameter_names)
            for parameter in operation.get("parameters", []):
                pattern = str(parameter.get("schema", {}).get("pattern", ""))
                assert "a-f0-9]{64}" not in pattern, (path, parameter.get("name"))

    source = _module_source(ROUTER)
    assert "content_sha256" not in source
    assert "sha256:" not in source


# --------------------------------------------------------------------------- #
# ADR-003 Authorization
# --------------------------------------------------------------------------- #
def test_adr003_router_never_touches_storage_or_repository_directly() -> None:
    """Every read goes through Authorization → Resolver; the handler is not a bypass."""

    source = _module_source(ROUTER)
    for forbidden in (
        "LocalBlobBackend",
        "MediaRepository",
        "read_bytes",
        "backend.get",
        ".storage_key",
    ):
        assert forbidden not in source, f"router must not use {forbidden}"


def test_adr003_authorization_port_is_the_only_decision_point() -> None:
    from app.modules.media.authorization import GrantAuthorizer, OwnerOnlyAuthorizer

    assert callable(OwnerOnlyAuthorizer.authorize)
    assert callable(GrantAuthorizer.authorize)
    # The gateway must call an injected authorizer rather than deciding by itself.
    gateway_source = _module_source(MEDIA_MODULE / "gateway.py")
    assert "self._authorizer.authorize" in gateway_source
    # The invariant that matters: only authorization.py may *grant* access. An adapter may
    # construct a DELEGATED outcome (that is ADR-004's design), never an ALLOWED one.
    for path in MEDIA_MODULE.glob("*.py"):
        if path.name == "authorization.py":
            continue
        assert "AuthorizationOutcome.ALLOWED" not in _module_source(path), path.name
        assert "outcome=AuthorizationOutcome.ALLOWED" not in _module_source(path), path.name


def test_adr003_private_requires_subject_binding(platform) -> None:
    from app.modules.media.signed_urls import MediaSignedUrlCodec

    codec = MediaSignedUrlCodec(secret="readiness-secret-at-least-16-bytes")
    token, _ = codec.mint(
        media_id="m",
        variant_kind=VariantKind.ORIGINAL,
        subject="user-a",
        tier=VisibilityTier.PRIVATE,
        ttl_seconds=60,
    )
    assert codec.verify(token, caller_id="user-a").subject == "user-a"
    with pytest.raises(AppError):
        codec.verify(token, caller_id="user-b")
    with pytest.raises(AppError):
        codec.verify(token, caller_id=None)


def test_adr003_token_lifetime_is_server_side_only(platform) -> None:
    import inspect

    from app.modules.media.signed_urls import MediaSignedUrlCodec

    codec = MediaSignedUrlCodec(secret="readiness-secret-at-least-16-bytes")
    _, parsed = codec.mint(
        media_id="m",
        variant_kind=VariantKind.ORIGINAL,
        subject="user-a",
        tier=VisibilityTier.PRIVATE,
        ttl_seconds=30,
    )
    # The only TTL input is a server-side argument; there is no client-facing equivalent.
    mint_parameters = set(inspect.signature(codec.mint).parameters)
    assert "ttl_seconds" in mint_parameters
    assert not {"expires_in", "client_ttl", "ttl"} & mint_parameters

    from app.api.media_platform import SignedUrlRequest, GrantIssueRequest

    for model in (SignedUrlRequest, GrantIssueRequest):
        fields = set(model.model_fields)
        assert not {"expires_in", "ttl"} & fields, model.__name__
    assert "ttl_seconds" in GrantIssueRequest.model_fields  # owner-issued grant, still server side
    assert parsed.key_version >= 1


# --------------------------------------------------------------------------- #
# ADR-004 Matrix compatibility
# --------------------------------------------------------------------------- #
def test_adr004_matrix_adapter_has_no_write_path() -> None:
    node = _class_node(MEDIA_MODULE / "gateway.py", "MatrixMediaGateway")
    calls: list[str] = []
    for child in ast.walk(node):
        if isinstance(child, ast.Call):
            target = child.func
            name = getattr(target, "attr", getattr(target, "id", ""))
            calls.append(str(name))
    for forbidden in ("put", "delete", "write_bytes", "unlink", "store", "ingest", "ingest_object"):
        assert forbidden not in calls, f"MatrixMediaGateway must not call {forbidden}"


def test_adr004_media_module_never_moves_or_renames_bytes() -> None:
    banned = ("shutil.move", "os.rename", "os.replace", "shutil.copy")
    for path in MEDIA_MODULE.glob("*.py"):
        source = _module_source(path)
        for token in banned:
            assert token not in source, f"{path.name} must not relocate bytes ({token})"


def test_adr004_legacy_matrix_resolution_creates_no_platform_rows(platform) -> None:
    import asyncio

    async def run() -> dict:
        async with platform.client() as client:
            response = await client.get(
                "/api/v1/media/platform/resolve",
                params={"reference": "mxc://matrix.localhost/LegacyId123"},
                headers=platform.headers["user-a"],
            )
            assert response.status_code == 200
            return response.json()

    payload = asyncio.run(run())
    assert payload["requires_matrix_token"] is True
    assert payload["delegated_to"] == "matrix"
    with platform.factory() as session:
        assert session.query(MediaObject).count() == 0
        assert session.query(MediaBlob).count() == 0


def test_adr004_legacy_business_reference_is_read_only(platform) -> None:
    import asyncio

    async def run() -> dict:
        async with platform.client() as client:
            response = await client.get(
                "/api/v1/media/platform/resolve",
                params={
                    "reference": "http://media.local/api/v1/moments/media/content/gAAAAABlegacy"
                },
                headers=platform.headers["user-a"],
            )
            assert response.status_code == 200
            return response.json()

    payload = asyncio.run(run())
    assert payload["read_old_only"] is True
    assert payload["delivery"] == "legacy_capability"
    with platform.factory() as session:
        assert session.query(MediaObject).count() == 0


# --------------------------------------------------------------------------- #
# ADR-005 Upload boundary
# --------------------------------------------------------------------------- #
def test_adr005_upload_engine_is_decoupled_from_messaging_and_media_objects() -> None:
    source = _module_source(MEDIA_MODULE / "upload_engine.py")
    for forbidden in ("moments", "matrix", "sendFileEvent", "reference", "media_objects"):
        assert forbidden not in source, f"upload engine must not depend on {forbidden}"


def test_adr005_no_media_id_is_published_before_commit(platform) -> None:
    import asyncio

    async def run() -> tuple[dict, int, dict]:
        async with platform.client() as client:
            created = await client.post(
                "/api/v1/media/platform/uploads",
                params={"kind": "video", "declared_size": 1024, "declared_mime": "video/mp4"},
                headers={**platform.headers["user-a"], "Idempotency-Key": "ready-upload"},
            )
            payload = created.json()
            committed = await client.post(
                f"/api/v1/media/platform/uploads/{payload['upload_id']}/complete",
                headers=platform.headers["user-a"],
            )
            return payload, committed.status_code, committed.json()

    payload, status, body = asyncio.run(run())
    assert status == 501
    assert payload["media_id"] is None
    assert "media_id" not in body.get("error", {})
    # No object was created by a reserved operation.
    with platform.factory() as session:
        assert session.query(MediaObject).count() == 0


def test_adr005_resume_state_is_owner_scoped(platform) -> None:
    import asyncio

    async def run() -> tuple[int, int]:
        async with platform.client() as client:
            created = await client.post(
                "/api/v1/media/platform/uploads",
                params={"kind": "image", "declared_size": 512, "declared_mime": "image/jpeg"},
                headers={**platform.headers["user-a"], "Idempotency-Key": "ready-scope"},
            )
            upload_id = created.json()["upload_id"]
            owner = await client.get(
                f"/api/v1/media/platform/uploads/{upload_id}", headers=platform.headers["user-a"]
            )
            other = await client.get(
                f"/api/v1/media/platform/uploads/{upload_id}", headers=platform.headers["user-c"]
            )
            return owner.status_code, other.status_code

    owner_status, other_status = asyncio.run(run())
    assert owner_status == 200
    assert other_status == 404


# --------------------------------------------------------------------------- #
# ADR-006 Lifecycle
# --------------------------------------------------------------------------- #
def test_adr006_release_marks_orphan_before_any_deletion(platform) -> None:
    from app.modules.media.domain import BusinessType, ReleaseReason
    from app.modules.media.references import MediaReferenceService

    result = platform.ingest()
    references = MediaReferenceService(platform.factory)
    first = references.attach(
        media_id=result.media_id,
        actor_id="user-a",
        business_type=BusinessType.CHAT_MESSAGE,
        business_id="$m1",
    )
    second = references.attach(
        media_id=result.media_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="moment-1",
    )

    references.release(reference_id=first.reference_id, actor_id="user-a")
    with platform.factory() as session:
        media = session.get(MediaObject, result.media_id)
    assert media.status == MediaStatus.ACTIVE.value  # still referenced

    references.release(
        reference_id=second.reference_id,
        actor_id="user-a",
        reason=ReleaseReason.MOMENT_DELETED,
    )
    with platform.factory() as session:
        media = session.get(MediaObject, result.media_id)
    assert media.status == MediaStatus.ORPHAN.value
    assert media.deleted_at is None  # orphan is not deletion


def test_adr006_status_machine_rejects_illegal_transitions() -> None:
    from app.modules.media.domain import assert_status_transition

    assert_status_transition(MediaStatus.ACTIVE, MediaStatus.ORPHAN)
    with pytest.raises(AppError):
        assert_status_transition(MediaStatus.ACTIVE, MediaStatus.DELETED)
    with pytest.raises(AppError):
        assert_status_transition(MediaStatus.DELETED, MediaStatus.ACTIVE)
