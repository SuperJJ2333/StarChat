"""Variant resolution (Phase 4.5, implemented with the gateway in Phase 4.2).

Selection inputs are network quality, device preference, authorization scope and content
type; the output is an ordered list of *ready* candidates. Two rules make this safe:

* a variant that is not ``ready`` is never returned (the caller degrades explicitly);
* the grant's ``variant_scope`` filters the list **after** ordering, so a caller can never
  widen its own access by asking for a better variant.
"""

from __future__ import annotations

from dataclasses import dataclass

from app.modules.media.domain import (
    MediaKind,
    VariantKind,
    VariantStatus,
    VARIANT_FALLBACK_ORDER,
)
from app.modules.media.metrics import media_platform_metrics
from app.modules.media.policy import (
    NetworkHint,
    VariantPreference,
    variant_preference_order,
)


@dataclass(frozen=True, slots=True)
class VariantCandidate:
    variant_id: str
    media_id: str
    kind: VariantKind
    blob_id: str
    mime: str | None
    size: int | None
    width: int | None
    height: int | None
    duration_ms: int | None
    generation: int
    is_primary: bool


class VariantResolver:
    def __init__(self, repository) -> None:
        self._repository = repository

    def ready_variants(self, media_id: str) -> dict[VariantKind, VariantCandidate]:
        """Highest generation ready variant per kind."""

        best: dict[VariantKind, VariantCandidate] = {}
        for row in self._repository.list_variants(media_id):
            if row.status != VariantStatus.READY.value or not row.blob_id:
                continue
            try:
                kind = VariantKind(row.kind)
            except ValueError:  # unknown kind from a newer writer: ignore, never fail
                continue
            candidate = VariantCandidate(
                variant_id=row.variant_id,
                media_id=row.media_id,
                kind=kind,
                blob_id=row.blob_id,
                mime=row.mime,
                size=row.size,
                width=row.width,
                height=row.height,
                duration_ms=row.duration_ms,
                generation=row.generation,
                is_primary=row.is_primary,
            )
            current = best.get(kind)
            if current is None or candidate.generation > current.generation:
                best[kind] = candidate
        return best

    def candidates(
        self,
        media_id: str,
        *,
        media_kind: MediaKind,
        prefer: VariantPreference = VariantPreference.AUTO,
        network: NetworkHint = NetworkHint.UNKNOWN,
        allowed_kinds: frozenset[VariantKind] | None = None,
    ) -> list[VariantCandidate]:
        with media_platform_metrics.timed("variant_resolve_ms"):
            ready = self.ready_variants(media_id)
            if allowed_kinds is not None:
                ready = {kind: item for kind, item in ready.items() if kind in allowed_kinds}
            ordered: list[VariantCandidate] = []
            seen: set[VariantKind] = set()
            for kind in variant_preference_order(
                media_kind=media_kind, prefer=prefer, network=network
            ):
                if kind in ready and kind not in seen:
                    ordered.append(ready[kind])
                    seen.add(kind)
            # Anything ready but outside the preference list still gets a deterministic
            # place, ordered cheapest-first, so a newer writer's variant is reachable.
            for kind in VARIANT_FALLBACK_ORDER[media_kind]:
                if kind in ready and kind not in seen:
                    ordered.append(ready[kind])
                    seen.add(kind)
            media_platform_metrics.increment("variant_resolve")
            return ordered

    def best(
        self,
        media_id: str,
        *,
        media_kind: MediaKind,
        prefer: VariantPreference = VariantPreference.AUTO,
        network: NetworkHint = NetworkHint.UNKNOWN,
        allowed_kinds: frozenset[VariantKind] | None = None,
    ) -> VariantCandidate | None:
        candidates = self.candidates(
            media_id,
            media_kind=media_kind,
            prefer=prefer,
            network=network,
            allowed_kinds=allowed_kinds,
        )
        return candidates[0] if candidates else None
