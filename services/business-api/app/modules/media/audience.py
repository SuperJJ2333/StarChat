"""Audience verification (production-readiness fix, ADR-003 §4.3.3).

**Why this module exists.** ADR-003 froze "an audience token may be forwarded inside the
audience" as an accepted trade-off, and Phase 4 implemented exactly that: any holder of an
audience URL could read it. The production-readiness audit showed the consequence is wider
than the trade-off intended — a *non-member*, and even an anonymous caller, could read an
audience URL, because nothing re-checked membership at delivery time.

**What changed.** The platform now treats an audience reference as something it must be able
to *re-verify*, and refuses to create a token it cannot verify:

* a verifiable reference (``moment:<id>``) is re-checked on **every** delivery against the
  live Moments visibility policy, so losing membership (unfriending, blocking, deleting the
  moment, narrowing history) takes effect immediately even for an already-issued URL;
* an unverifiable reference (``room:<id>``, anything unknown) is **refused at mint time**
  with ``MEDIA_AUDIENCE_UNVERIFIABLE`` — fail closed. Chat media does not need a platform
  audience token at all: it is served by Matrix's own authenticated media endpoint, which
  verifies room membership per request (ADR-004).

This is a *tightening* of the frozen trade-off in the safe direction (deny rather than
allow). It removes no capability that any current caller relied on and touches no stored
data, but the freeze document should be amended to record it.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from app.core.errors import AppError

MOMENT_SCHEME = "moment"
ROOM_SCHEME = "room"


class AudienceVerifier(Protocol):
    scheme: str

    def verify(self, *, target: str, caller_id: str | None) -> bool: ...


@dataclass(frozen=True, slots=True)
class MomentsAudienceVerifier:
    """Audience = whoever the live Moments visibility policy allows to see the moment."""

    session_factory: object
    scheme: str = MOMENT_SCHEME

    def verify(self, *, target: str, caller_id: str | None) -> bool:
        if not caller_id:
            # No identity means no membership: anonymous audience reads are refused.
            return False
        from app.modules.moments.models import Moment
        from app.modules.moments.visibility import VisibilityPolicy

        with self._session() as session:
            moment = session.get(Moment, target)
            if moment is None or moment.deleted_at is not None or moment.status != "PUBLISHED":
                return False
            try:
                return bool(VisibilityPolicy(session).can_view(caller_id, moment))
            except Exception:
                # A failing policy lookup is a denial, never an allow (fail closed).
                return False

    def _session(self):
        # ``session_factory`` is a sessionmaker; keep the call site explicit.
        return self.session_factory()


class AudienceRegistry:
    """Routes an audience reference to a verifier, and refuses unknown schemes."""

    def __init__(self, *, verifiers: tuple[AudienceVerifier, ...]) -> None:
        self._verifiers = {verifier.scheme: verifier for verifier in verifiers}

    @staticmethod
    def parse(reference: str | None) -> tuple[str, str] | None:
        if not reference or ":" not in reference:
            return None
        scheme, _, target = reference.partition(":")
        scheme = scheme.strip().casefold()
        target = target.strip()
        if not scheme or not target:
            return None
        return scheme, target

    def verifiable(self, reference: str | None) -> bool:
        parsed = self.parse(reference)
        return parsed is not None and parsed[0] in self._verifiers

    def verify(self, reference: str | None, *, caller_id: str | None) -> bool:
        parsed = self.parse(reference)
        if parsed is None:
            return False
        verifier = self._verifiers.get(parsed[0])
        if verifier is None:
            # Unknown or unverifiable scheme: deny (the mint path already refuses these).
            return False
        return verifier.verify(target=parsed[1], caller_id=caller_id)


def assert_audience_is_verifiable(registry: AudienceRegistry, reference: str | None) -> str:
    """Mint-time guard: never issue a token the platform cannot re-check."""

    if not reference:
        raise AppError(
            code="MEDIA_AUDIENCE_REQUIRED",
            message="受众链接必须指定受众",
            status_code=422,
        )
    if not registry.verifiable(reference):
        raise AppError(
            code="MEDIA_AUDIENCE_UNVERIFIABLE",
            message="该受众无法校验，已拒绝签发链接",
            status_code=422,
        )
    return reference
