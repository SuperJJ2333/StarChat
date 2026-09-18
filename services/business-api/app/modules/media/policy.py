"""Media Platform policies (Phase 4.1).

Policies are *values*, not behaviour: they are injected into the gateway and resolver so
that the frozen relative relationships hold even when the numeric values change.

Frozen here (see `docs/architecture/media-engine-phase3-freeze.md`):

- **Dedup policy** — cross-user plaintext reuse is never allowed; ciphertext reuse is
  allowed only for the deterministic envelope above a size threshold. Small files are
  never cross-user deduplicated (confirmation-attack surface).
- **TTL policy** — the server decides; the relative ordering is
  ``public >= audience >= private`` and, within a tier,
  ``poster/thumbnail >= preview/image >= video >= original``. Sizes are configurable but
  the ordering is asserted in tests.
- **Variant preference** — a client ``prefer`` hint plus a network hint choose an ordered
  candidate list; authorization filters it afterwards, never the other way round.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum

from app.modules.media.domain import (
    DigestKind,
    EnvelopeMode,
    IsolationViolation,
    MediaKind,
    Permission,
    VariantKind,
    VisibilityTier,
    dedup_eligible,
)


class DedupDecision(StrEnum):
    REUSE = "reuse"
    CREATE = "create"


@dataclass(frozen=True, slots=True)
class MediaDedupPolicy:
    """When may an upload reuse an existing blob instead of storing new bytes?"""

    #: Below this size an object is never reused across users.
    min_dedup_bytes: int = 256 * 1024
    #: E2EE ciphertext reuse (the shipped behaviour) can be switched off entirely.
    allow_ciphertext_reuse: bool = True
    #: Frozen ``False``: user A's plaintext upload must never satisfy user B.
    allow_cross_user_plaintext: bool = False
    #: Deterministic envelope version that is allowed to be reused.
    reusable_envelope_version: int = 1

    def decide(
        self,
        *,
        digest_kind: DigestKind,
        envelope_mode: EnvelopeMode,
        envelope_version: int,
        size: int,
    ) -> DedupDecision:
        if self.allow_cross_user_plaintext:
            # Frozen ``False``. Failing loudly beats silently enabling global dedup that
            # ADR-001 rejected: anybody flipping this flag must change the ADR first.
            raise IsolationViolation(
                "cross-user plaintext dedup is rejected by ADR-001 and cannot be enabled"
            )
        if digest_kind is DigestKind.PLAINTEXT:
            # Plaintext bytes are only ever reused inside one owner's isolation domain,
            # which the repository enforces with its owner-scoped lookup.
            return DedupDecision.REUSE
        if not self.allow_ciphertext_reuse:
            return DedupDecision.CREATE
        if envelope_version != self.reusable_envelope_version:
            return DedupDecision.CREATE
        if dedup_eligible(
            digest_kind=digest_kind,
            envelope_mode=envelope_mode,
            size=size,
            min_size_bytes=self.min_dedup_bytes,
        ):
            return DedupDecision.REUSE
        return DedupDecision.CREATE


class NetworkHint(StrEnum):
    """Client-declared hint. Never security relevant, only affects variant selection."""

    UNKNOWN = "unknown"
    SLOW = "slow"
    WIFI = "wifi"
    ETHERNET = "ethernet"


class VariantPreference(StrEnum):
    AUTO = "auto"
    DATA_SAVER = "data_saver"
    QUALITY = "quality"


#: Variant classes used by the TTL policy. Poster-ish bytes are cheap and highly reused;
#: originals are the most sensitive and get the shortest window.
_CHEAPEST_VARIANTS = frozenset(
    {VariantKind.POSTER, VariantKind.THUMBNAIL, VariantKind.P360, VariantKind.COMPRESSED}
)
_MID_VARIANTS = frozenset({VariantKind.PREVIEW, VariantKind.PREVIEW_VIDEO, VariantKind.P720})
_ORIGINAL_VARIANTS = frozenset({VariantKind.ORIGINAL, VariantKind.P1080})


@dataclass(frozen=True, slots=True)
class MediaTtlPolicy:
    """Server-decided signed-URL lifetime.

    The client cannot pass ``expires_in`` to any Phase 4 endpoint; the API layer does not
    even accept the parameter (ADR-003). Values are the configurable part, the ordering is
    the frozen part.
    """

    private_seconds: int = 60
    audience_seconds: int = 600
    public_seconds: int = 86400
    minimum_seconds: int = 30
    maximum_seconds: int = 86400

    def ttl_seconds(
        self,
        *,
        visibility: VisibilityTier,
        variant_kind: VariantKind,
        permission: Permission = Permission.READ,
    ) -> int:
        base = {
            VisibilityTier.PRIVATE: self.private_seconds,
            VisibilityTier.AUDIENCE: self.audience_seconds,
            VisibilityTier.PUBLIC: self.public_seconds,
        }[visibility]

        if variant_kind in _CHEAPEST_VARIANTS:
            multiplier = 4
        elif variant_kind in _MID_VARIANTS:
            multiplier = 2
        elif variant_kind in _ORIGINAL_VARIANTS:
            multiplier = 1
        else:  # pragma: no cover - exhaustive enum coverage guard
            multiplier = 1

        if permission is Permission.READ_ORIGINAL:
            # Original bytes are the most sensitive: never extend the window for them.
            multiplier = 1

        return max(self.minimum_seconds, min(self.maximum_seconds, base * multiplier))


def variant_preference_order(
    *,
    media_kind: MediaKind,
    prefer: VariantPreference,
    network: NetworkHint,
) -> tuple[VariantKind, ...]:
    """Ordered candidate variants for a first look.

    Ordering only; the caller still filters by readiness and by the grant's
    ``variant_scope``. Unknown media kinds fall back to their primary variant.
    """

    if media_kind is MediaKind.VIDEO:
        if prefer is VariantPreference.DATA_SAVER or network is NetworkHint.SLOW:
            return (
                VariantKind.POSTER,
                VariantKind.PREVIEW_VIDEO,
                VariantKind.P360,
                VariantKind.P720,
                VariantKind.ORIGINAL,
            )
        if prefer is VariantPreference.QUALITY or network in (
            NetworkHint.WIFI,
            NetworkHint.ETHERNET,
        ):
            return (
                VariantKind.POSTER,
                VariantKind.PREVIEW_VIDEO,
                VariantKind.P720,
                VariantKind.P1080,
                VariantKind.P360,
                VariantKind.ORIGINAL,
            )
        return (
            VariantKind.POSTER,
            VariantKind.PREVIEW_VIDEO,
            VariantKind.P360,
            VariantKind.P720,
            VariantKind.ORIGINAL,
        )

    if media_kind in (MediaKind.IMAGE, MediaKind.GIF):
        if prefer is VariantPreference.DATA_SAVER or network is NetworkHint.SLOW:
            return (VariantKind.THUMBNAIL, VariantKind.PREVIEW, VariantKind.ORIGINAL)
        if prefer is VariantPreference.QUALITY:
            return (VariantKind.ORIGINAL, VariantKind.PREVIEW, VariantKind.THUMBNAIL)
        return (VariantKind.THUMBNAIL, VariantKind.PREVIEW, VariantKind.COMPRESSED, VariantKind.ORIGINAL)

    if media_kind is MediaKind.AUDIO:
        return (VariantKind.COMPRESSED, VariantKind.ORIGINAL)

    return (VariantKind.ORIGINAL,)


@dataclass(frozen=True, slots=True)
class MediaPlatformPolicy:
    """The policy bundle handed to the gateway."""

    dedup: MediaDedupPolicy = field(default_factory=MediaDedupPolicy)
    ttl: MediaTtlPolicy = field(default_factory=MediaTtlPolicy)
    #: Grace period before an orphan may be collected (ADR-006).
    orphan_grace_seconds: int = 7 * 24 * 3600
    #: E2EE references are unknowable, so an E2EE object keeps a retention floor.
    e2ee_retention_floor_seconds: int = 30 * 24 * 3600
    #: Upload sessions may be resumed for this long (ADR-005).
    upload_session_ttl_seconds: int = 24 * 3600
    #: Upload session part size advertised to clients.
    upload_part_size_bytes: int = 8 * 1024 * 1024
    #: Hard cap for a single upload session.
    upload_max_parts: int = 4096
