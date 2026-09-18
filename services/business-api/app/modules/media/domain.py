"""Media Platform domain core (Phase 4.1).

Frozen by `docs/architecture/media-engine-phase3-freeze.md`:

- **ADR-001 Isolation** — plaintext domains are per-owner; the E2EE domain keeps the
  shipped ciphertext reuse. Isolation (where bytes live) and authorization (who may
  read) are separate concerns.
- **ADR-002 Digest** — three digest kinds with different owners, trust levels and
  purposes. Kinds are never compared with each other; client supplied digests are
  never authoritative; no client-facing existence query exists.

This module is pure domain logic: no I/O, no HTTP, no ORM. Everything the rest of
the platform enforces about identity, isolation and digests is defined here so that a
violation is a type/`raise` at the boundary rather than a convention.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from enum import StrEnum
from uuid import uuid4

from app.core.errors import AppError

# --------------------------------------------------------------------------- #
# Identifiers and limits
# --------------------------------------------------------------------------- #

#: Opaque identifiers. Never derived from a digest (ADR-002 rule 5) so that knowing
#: an id can never reveal content and knowing content can never produce an id.
ID_LENGTH = 36

MAX_IMAGE_BYTES = 20 * 1024 * 1024
MAX_VIDEO_BYTES = 2 * 1024 * 1024 * 1024
MAX_AUDIO_BYTES = 64 * 1024 * 1024
MAX_FILE_BYTES = 512 * 1024 * 1024

#: Digest of an empty byte string is a valid digest; guard instead against blanks.
DIGEST_HEX_LENGTH = 64


def new_media_id() -> str:
    return str(uuid4())


def new_blob_id() -> str:
    return str(uuid4())


def new_variant_id() -> str:
    return str(uuid4())


def new_reference_id() -> str:
    return str(uuid4())


def new_grant_id() -> str:
    return str(uuid4())


def new_upload_id() -> str:
    return str(uuid4())


def new_gc_run_id() -> str:
    return str(uuid4())


# --------------------------------------------------------------------------- #
# Media kind
# --------------------------------------------------------------------------- #


class MediaKind(StrEnum):
    IMAGE = "image"
    VIDEO = "video"
    AUDIO = "audio"
    FILE = "file"
    GIF = "gif"


MEDIA_KIND_MAX_BYTES: dict[MediaKind, int] = {
    MediaKind.IMAGE: MAX_IMAGE_BYTES,
    MediaKind.VIDEO: MAX_VIDEO_BYTES,
    MediaKind.AUDIO: MAX_AUDIO_BYTES,
    MediaKind.FILE: MAX_FILE_BYTES,
    MediaKind.GIF: MAX_IMAGE_BYTES,
}

MEDIA_KIND_DEFAULT_SUFFIX: dict[MediaKind, str] = {
    MediaKind.IMAGE: ".jpg",
    MediaKind.VIDEO: ".mp4",
    MediaKind.AUDIO: ".m4a",
    MediaKind.FILE: ".bin",
    MediaKind.GIF: ".gif",
}

MIME_SUFFIX: dict[str, str] = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
    "image/gif": ".gif",
    "video/mp4": ".mp4",
    "video/quicktime": ".mov",
    "audio/mp4": ".m4a",
    "audio/aac": ".aac",
    "audio/mpeg": ".mp3",
    "application/pdf": ".pdf",
    "application/zip": ".zip",
    "text/plain": ".txt",
}

#: Media that the server may hash in plaintext (ADR-002). E2EE attachments never
#: reach this table as plaintext: they only ever carry a ciphertext digest.
PLAINTEXT_MEDIA_KINDS = frozenset(MediaKind)


# --------------------------------------------------------------------------- #
# Digest
# --------------------------------------------------------------------------- #


class DigestKind(StrEnum):
    """The three frozen digest kinds (ADR-002).

    ``PLAINTEXT``  — server computes it, only where the server legitimately holds the
                     plaintext bytes. Authoritative for content addressing inside the
                     owner's isolation domain.
    ``CIPHERTEXT`` — server computes it over the bytes it actually received for an E2EE
                     attachment. The only key allowed to reuse an object across users,
                     and only for a deterministic envelope with ``dedup_eligible``.
    ``TRANSPORT``  — client supplied per-chunk digest used purely to detect transport
                     errors and to reconcile a resumed session. Never an identity, never
                     a dedup key, never an authorization input.
    """

    PLAINTEXT = "plaintext_digest"
    CIPHERTEXT = "ciphertext_digest"
    TRANSPORT = "transport_digest"


class CrossKindDigestComparison(RuntimeError):
    """Raised when two digests of different kinds/versions would be compared.

    ADR-002 rule 1: kinds are never compared. Failing loudly here is what makes
    "plaintext hash == ciphertext hash" structurally impossible rather than a rule
    somebody has to remember.
    """


@dataclass(frozen=True, slots=True)
class Digest:
    kind: DigestKind
    value: str
    version: int = 1

    def __post_init__(self) -> None:
        normalized = self.value.strip().casefold()
        if len(normalized) != DIGEST_HEX_LENGTH or any(
            character not in "0123456789abcdef" for character in normalized
        ):
            raise AppError(
                code="MEDIA_DIGEST_INVALID",
                message="媒体摘要格式不合法",
                status_code=422,
            )
        if self.version < 1:
            raise AppError(
                code="MEDIA_DIGEST_INVALID",
                message="媒体摘要版本不合法",
                status_code=422,
            )
        object.__setattr__(self, "value", normalized)

    @property
    def identity(self) -> tuple[str, int, str]:
        return (str(self.kind), self.version, self.value)

    def same_kind_as(self, other: "Digest") -> bool:
        return self.kind == other.kind and self.version == other.version

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Digest):
            return NotImplemented
        if not self.same_kind_as(other):
            raise CrossKindDigestComparison(
                "digest kinds are never compared "
                f"({self.kind.value}#{self.version} vs {other.kind.value}#{other.version})"
            )
        return self.value == other.value

    def __hash__(self) -> int:
        return hash(self.identity)


def digest_of(kind: DigestKind, content: bytes, *, version: int = 1) -> Digest:
    """Hash bytes for the given digest kind.

    The caller decides the kind; the domain guarantees the kind/version travel with the
    value so that a later comparison can never silently mix two families.
    """

    return Digest(
        kind=kind,
        value=hashlib.sha256(content).hexdigest(),
        version=version,
    )


def plaintext_digest(content: bytes, *, version: int = 1) -> Digest:
    return digest_of(DigestKind.PLAINTEXT, content, version=version)


def ciphertext_digest(content: bytes, *, version: int = 1) -> Digest:
    return digest_of(DigestKind.CIPHERTEXT, content, version=version)


def transport_digest(content: bytes, *, version: int = 1) -> Digest:
    return digest_of(DigestKind.TRANSPORT, content, version=version)


def assert_transport_claim_matches(claim: Digest | None, content: bytes) -> None:
    """Verify a client transport digest without ever trusting it.

    The server recomputes; a mismatch is a transport error (fail the request), a match
    still proves nothing about the object identity (ADR-002 rule 3).
    """

    if claim is None:
        return
    if claim.kind is not DigestKind.TRANSPORT:
        raise AppError(
            code="MEDIA_DIGEST_KIND_INVALID",
            message="只有传输摘要可以由客户端声明",
            status_code=422,
        )
    expected = transport_digest(content, version=claim.version)
    if expected.value != claim.value:
        raise AppError(
            code="MEDIA_TRANSPORT_DIGEST_MISMATCH",
            message="分片校验失败，请重试",
            status_code=409,
        )


# --------------------------------------------------------------------------- #
# Isolation (ADR-001)
# --------------------------------------------------------------------------- #


class IsolationDomain(StrEnum):
    """Byte-sharing boundary. Bytes never move across domains."""

    USER = "user"
    E2EE = "e2ee"
    SYSTEM_PUBLIC = "system_public"


class IsolationViolation(RuntimeError):
    """Raised when a digest kind is paired with a domain it may never own."""


_DOMAIN_BY_DIGEST_KIND: dict[DigestKind, IsolationDomain] = {
    DigestKind.PLAINTEXT: IsolationDomain.USER,
    DigestKind.CIPHERTEXT: IsolationDomain.E2EE,
}

E2EE_SCOPE_KEY = "e2ee:ciphertext-v1"
SYSTEM_PUBLIC_SCOPE_KEY = "system:public:v1"


def isolation_domain_for(digest_kind: DigestKind) -> IsolationDomain:
    """Map a digest kind to the only domain allowed to own it.

    A transport digest never owns an object, so it has no domain at all.
    """

    domain = _DOMAIN_BY_DIGEST_KIND.get(digest_kind)
    if domain is None:
        raise IsolationViolation(
            f"{digest_kind.value} must never own an object (transport digests are claims)"
        )
    return domain


def owner_scope_key(domain: IsolationDomain, owner_id: str) -> str:
    if domain is IsolationDomain.USER:
        if not owner_id:
            raise IsolationViolation("user isolation domain requires an owner")
        return f"user:{owner_id}"
    if domain is IsolationDomain.E2EE:
        return E2EE_SCOPE_KEY
    return SYSTEM_PUBLIC_SCOPE_KEY


def assert_object_domain(digest_kind: DigestKind, owner_scope: str) -> IsolationDomain:
    """Fail fast when a caller tries to place bytes in the wrong isolation domain."""

    domain = isolation_domain_for(digest_kind)
    expected = (
        f"{domain.value}:"
        if domain is not IsolationDomain.E2EE
        else E2EE_SCOPE_KEY
    )
    if domain is IsolationDomain.USER:
        if not owner_scope.startswith("user:"):
            raise IsolationViolation("plaintext objects live in a per-owner scope only")
    elif domain is IsolationDomain.E2EE:
        if owner_scope != E2EE_SCOPE_KEY:
            raise IsolationViolation("ciphertext objects live in the shared E2EE scope only")
    elif not owner_scope.startswith("system:"):
        raise IsolationViolation("public objects live in the system scope only")
    del expected  # documentation only; the checks above are the contract
    return domain


def allow_cross_user_plaintext_dedup() -> bool:
    """Always ``False`` in Phase 4.

    ADR-001 rejects global plaintext dedup: user A's upload must never let user B hit the
    same plaintext object. Kept as an explicit function so the refusal is discoverable and
    cannot be flipped by an accidental configuration read.
    """

    return False


# --------------------------------------------------------------------------- #
# Envelope
# --------------------------------------------------------------------------- #


class EnvelopeMode(StrEnum):
    NONE = "none"
    DETERMINISTIC_V1 = "deterministic_v1"
    MATRIX_V2_ENVELOPE = "matrix_v2_envelope"
    RANDOM = "random"


def dedup_eligible(
    *,
    digest_kind: DigestKind,
    envelope_mode: EnvelopeMode,
    size: int,
    min_size_bytes: int,
) -> bool:
    """Whether an object may be reused across users.

    Only the E2EE domain may reuse across users, only with the deterministic envelope
    (identical plaintext therefore identical ciphertext), and only above the policy
    threshold so that small files are not exposed to confirmation attacks.
    """

    if digest_kind is not DigestKind.CIPHERTEXT:
        return False
    if envelope_mode is not EnvelopeMode.DETERMINISTIC_V1:
        return False
    return size >= min_size_bytes


# --------------------------------------------------------------------------- #
# Object / variant lifecycle (ADR-006)
# --------------------------------------------------------------------------- #


class MediaStatus(StrEnum):
    ACTIVE = "ACTIVE"
    ORPHAN = "ORPHAN"
    DELETING = "DELETING"
    DELETED = "DELETED"

    @property
    def readable(self) -> bool:
        return self is MediaStatus.ACTIVE


MEDIA_STATUS_TRANSITIONS: dict[MediaStatus, frozenset[MediaStatus]] = {
    MediaStatus.ACTIVE: frozenset({MediaStatus.ORPHAN}),
    MediaStatus.ORPHAN: frozenset({MediaStatus.ACTIVE, MediaStatus.DELETING}),
    MediaStatus.DELETING: frozenset({MediaStatus.DELETED, MediaStatus.ORPHAN}),
    MediaStatus.DELETED: frozenset(),
}


def assert_status_transition(current: MediaStatus, target: MediaStatus) -> None:
    if target not in MEDIA_STATUS_TRANSITIONS[current]:
        raise AppError(
            code="MEDIA_STATUS_TRANSITION_INVALID",
            message="媒体状态流转不合法",
            status_code=409,
        )


class BlobStatus(StrEnum):
    STAGED = "STAGED"
    VERIFIED = "VERIFIED"
    ACTIVE = "ACTIVE"
    RETIRING = "RETIRING"
    DELETED = "DELETED"


class VariantKind(StrEnum):
    # images
    ORIGINAL = "original"
    THUMBNAIL = "thumbnail"
    PREVIEW = "preview"
    COMPRESSED = "compressed"
    # video
    POSTER = "poster"
    PREVIEW_VIDEO = "preview_video"
    P360 = "360p"
    P720 = "720p"
    P1080 = "1080p"


class VariantStatus(StrEnum):
    PENDING = "pending"
    PROCESSING = "processing"
    READY = "ready"
    FAILED = "failed"
    SKIPPED = "skipped"


IMAGE_VARIANTS: tuple[VariantKind, ...] = (
    VariantKind.ORIGINAL,
    VariantKind.THUMBNAIL,
    VariantKind.PREVIEW,
    VariantKind.COMPRESSED,
)

VIDEO_VARIANTS: tuple[VariantKind, ...] = (
    VariantKind.ORIGINAL,
    VariantKind.POSTER,
    VariantKind.PREVIEW_VIDEO,
    VariantKind.P360,
    VariantKind.P720,
    VariantKind.P1080,
)

AUDIO_VARIANTS: tuple[VariantKind, ...] = (VariantKind.ORIGINAL, VariantKind.COMPRESSED)
FILE_VARIANTS: tuple[VariantKind, ...] = (VariantKind.ORIGINAL,)

VARIANT_KINDS_BY_MEDIA_KIND: dict[MediaKind, tuple[VariantKind, ...]] = {
    MediaKind.IMAGE: IMAGE_VARIANTS,
    MediaKind.GIF: (VariantKind.ORIGINAL, VariantKind.THUMBNAIL, VariantKind.PREVIEW),
    MediaKind.VIDEO: VIDEO_VARIANTS,
    MediaKind.AUDIO: AUDIO_VARIANTS,
    MediaKind.FILE: FILE_VARIANTS,
}

#: The variant a client should show first when it has no other information.
PRIMARY_VARIANT_BY_MEDIA_KIND: dict[MediaKind, VariantKind] = {
    MediaKind.IMAGE: VariantKind.THUMBNAIL,
    MediaKind.GIF: VariantKind.ORIGINAL,
    MediaKind.VIDEO: VariantKind.POSTER,
    MediaKind.AUDIO: VariantKind.ORIGINAL,
    MediaKind.FILE: VariantKind.ORIGINAL,
}

#: Cheapest-to-most-expensive ordering used when a preferred variant is unavailable.
VARIANT_FALLBACK_ORDER: dict[MediaKind, tuple[VariantKind, ...]] = {
    MediaKind.IMAGE: (
        VariantKind.THUMBNAIL,
        VariantKind.PREVIEW,
        VariantKind.COMPRESSED,
        VariantKind.ORIGINAL,
    ),
    MediaKind.GIF: (VariantKind.THUMBNAIL, VariantKind.PREVIEW, VariantKind.ORIGINAL),
    MediaKind.VIDEO: (
        VariantKind.POSTER,
        VariantKind.PREVIEW_VIDEO,
        VariantKind.P360,
        VariantKind.P720,
        VariantKind.P1080,
        VariantKind.ORIGINAL,
    ),
    MediaKind.AUDIO: (VariantKind.COMPRESSED, VariantKind.ORIGINAL),
    MediaKind.FILE: (VariantKind.ORIGINAL,),
}


def assert_variant_kind_allowed(media_kind: MediaKind, variant_kind: VariantKind) -> None:
    if variant_kind not in VARIANT_KINDS_BY_MEDIA_KIND[media_kind]:
        raise AppError(
            code="MEDIA_VARIANT_KIND_INVALID",
            message="媒体类型不支持该演绎版",
            status_code=422,
        )


# --------------------------------------------------------------------------- #
# Reference (ADR-006)
# --------------------------------------------------------------------------- #


class BusinessType(StrEnum):
    CHAT_MESSAGE = "chat_message"
    GROUP_MESSAGE = "group_message"
    MOMENT = "moment"
    MOMENT_COMMENT = "moment_comment"
    MOMENT_COVER = "moment_cover"
    MOMENT_UPLOAD = "moment_upload"
    FILE = "file"
    ANNOUNCEMENT = "announcement"
    UPLOADER = "uploader"
    SYSTEM = "system"


class ReferenceKind(StrEnum):
    """Observed references are the server's own; declared ones come from a client.

    E2EE reference counts are unknowable to the server, so declared references are
    advisory only and must never be the sole reason to delete bytes (ADR-006).
    """

    OBSERVED = "observed"
    DECLARED = "declared"


class ReferenceState(StrEnum):
    ACTIVE = "active"
    RELEASED = "released"


class ReleaseReason(StrEnum):
    MESSAGE_DELETED = "message_deleted"
    MOMENT_DELETED = "moment_deleted"
    AVATAR_REPLACED = "avatar_replaced"
    RETENTION = "retention"
    USER_DELETE = "user_delete"
    MODERATION = "moderation"
    UPLOAD_ABORTED = "upload_aborted"


# --------------------------------------------------------------------------- #
# Authorization (ADR-003)
# --------------------------------------------------------------------------- #


class VisibilityTier(StrEnum):
    PRIVATE = "private"
    AUDIENCE = "audience"
    PUBLIC = "public"


class SubjectType(StrEnum):
    USER = "user"
    ROOM = "room"
    AUDIENCE = "audience"
    PUBLIC = "public"
    SERVICE = "service"


class Permission(StrEnum):
    READ = "read"
    READ_ORIGINAL = "read_original"
    LIST = "list"
    DELETE = "delete"
    ADMIN = "admin"


class DerivedRule(StrEnum):
    OWNER = "owner"
    GRANT = "grant"
    ROOM_MEMBERSHIP = "room_membership"
    MOMENT_VISIBILITY = "moment_visibility"
    PUBLIC_VERSION = "public_version"
    MAINTENANCE = "maintenance"


class AuthorizationOutcome(StrEnum):
    ALLOWED = "allowed"
    DELEGATED = "delegated"
    DENIED = "denied"


# --------------------------------------------------------------------------- #
# Upload sessions (ADR-005)
# --------------------------------------------------------------------------- #


class UploadSessionStatus(StrEnum):
    CREATED = "created"
    UPLOADING = "uploading"
    VERIFYING = "verifying"
    COMMITTED = "committed"
    ABORTED = "aborted"
    EXPIRED = "expired"


UPLOAD_SESSION_TERMINAL: frozenset[UploadSessionStatus] = frozenset(
    {
        UploadSessionStatus.COMMITTED,
        UploadSessionStatus.ABORTED,
        UploadSessionStatus.EXPIRED,
    }
)


# --------------------------------------------------------------------------- #
# GC (ADR-006)
# --------------------------------------------------------------------------- #


class GcMode(StrEnum):
    DRY_RUN = "dry_run"
    ENFORCE = "enforce"


class GcSkipReason(StrEnum):
    HAS_REFERENCES = "has_references"
    PINNED = "pinned"
    WITHIN_GRACE = "within_grace"
    QUARANTINED = "quarantined"
    ACTIVE_UPLOAD = "active_upload"
    NOT_ORPHAN = "not_orphan"
