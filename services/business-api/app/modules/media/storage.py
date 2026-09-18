"""Blob storage for the Media Platform (Phase 4.1).

This is **not** a second cache and not a second storage system: it writes into the same
private object directory the business API already owns (``BUSINESS_AVATAR_STORAGE_ROOT``)
under a new, media-platform key namespace. Existing objects keep their existing keys.

Key layout (ADR-001 — the key encodes the isolation domain so a bug cannot silently place
per-user plaintext into the shared ciphertext namespace or the other way round)::

    media/user/<sha256(scope_key)[:32]>/<blob_id><suffix>      plaintext, per owner
    media/e2ee/<sha256(scope_key)[:32]>/<blob_id><suffix>      E2EE ciphertext (shared)
    media/public/<sha256(scope_key)[:32]>/<blob_id><suffix>    platform public material

The scope hash keeps raw user ids out of filesystem paths; ``blob_id`` is opaque, so a
path never reveals content or a digest.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Protocol

from app.core.errors import AppError
from app.modules.media.domain import (
    MIME_SUFFIX,
    MediaKind,
    MEDIA_KIND_DEFAULT_SUFFIX,
    IsolationDomain,
    assert_object_domain,
)


class BlobBackend(Protocol):
    """Minimal byte-store contract. Implementations must be atomic on write."""

    def put(self, key: str, content: bytes) -> None: ...

    def get(self, key: str) -> bytes: ...

    def exists(self, key: str) -> bool: ...

    def delete(self, key: str) -> None: ...


class LocalBlobBackend:
    """Filesystem backend rooted at the existing private object directory."""

    def __init__(self, *, root: str) -> None:
        self._root = Path(root).resolve()

    @property
    def root(self) -> Path:
        return self._root

    def put(self, key: str, content: bytes) -> None:
        target = self._path(key)
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(target.suffix + ".tmp")
        temporary.write_bytes(content)
        temporary.replace(target)

    def get(self, key: str) -> bytes:
        try:
            return self._path(key).read_bytes()
        except FileNotFoundError:
            raise AppError(
                code="MEDIA_BLOB_MISSING",
                message="媒体文件不存在",
                status_code=503,
            ) from None

    def exists(self, key: str) -> bool:
        return self._path(key).is_file()

    def delete(self, key: str) -> None:
        self._path(key).unlink(missing_ok=True)

    def _path(self, key: str) -> Path:
        if not key or key.startswith("/") or ".." in Path(key).parts:
            raise AppError(
                code="MEDIA_STORAGE_KEY_INVALID",
                message="媒体存储引用无效",
                status_code=500,
            )
        candidate = (self._root / key).resolve()
        if candidate == self._root or self._root not in candidate.parents:
            raise AppError(
                code="MEDIA_STORAGE_KEY_INVALID",
                message="媒体存储引用无效",
                status_code=500,
            )
        return candidate


_DOMAIN_SEGMENT: dict[IsolationDomain, str] = {
    IsolationDomain.USER: "user",
    IsolationDomain.E2EE: "e2ee",
    IsolationDomain.SYSTEM_PUBLIC: "public",
}

DOMAIN_SEGMENTS = tuple(_DOMAIN_SEGMENT.values())


def scope_hash(scope_key: str) -> str:
    return hashlib.sha256(scope_key.encode("utf-8")).hexdigest()[:32]


def suffix_for_mime(mime: str, *, kind: MediaKind) -> str:
    return MIME_SUFFIX.get(mime.strip().casefold(), MEDIA_KIND_DEFAULT_SUFFIX[kind])


def storage_key_for(
    *,
    isolation_domain: IsolationDomain,
    scope_key: str,
    blob_id: str,
    mime: str,
    kind: MediaKind,
) -> str:
    """Build the only legal key shape for a blob in the given isolation domain."""

    segment = _DOMAIN_SEGMENT[isolation_domain]
    return f"media/{segment}/{scope_hash(scope_key)}/{blob_id}{suffix_for_mime(mime, kind=kind)}"


def key_belongs_to_domain(key: str, *, digest_kind, owner_scope: str) -> bool:
    """Guard used before writing: a key may only live in its own isolation domain.

    Verifies both the address (scope hash) and the segment, so a bug that mixes a
    plaintext digest with the E2EE scope fails loudly instead of writing per-user bytes
    into the shared namespace (ADR-001).
    """

    from app.modules.media.domain import DigestKind

    if not isinstance(digest_kind, DigestKind):
        return False
    domain = assert_object_domain(digest_kind, owner_scope)
    parts = key.split("/")
    return (
        len(parts) >= 4
        and parts[0] == "media"
        and parts[1] == _DOMAIN_SEGMENT[domain]
        and parts[2] == scope_hash(owner_scope)
    )
