"""Authorization port and the conservative first implementation (Phase 4.4 groundwork).

Phase 4.2 wires the *decision point* into the gateway so that every new read already goes
through `Client → Authorization → Media Resolver → Variant Resolver → delivery`. Phase 4.4
adds the grant model, the audience rules and the signed-URL delivery on top of the same
port; nothing in the gateway changes when it does.

Fail-closed is a property of the types here: an outcome that is neither ``ALLOWED`` nor
``DELEGATED`` is a denial, and there is no "unknown → allow" path.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol

from app.modules.media.domain import (
    AuthorizationOutcome,
    DerivedRule,
    Permission,
    SubjectType,
    VariantKind,
)
from app.modules.media.metrics import media_platform_metrics
from app.modules.media.policy import MediaTtlPolicy, VisibilityTier


def _scope_of(grant) -> tuple[str, ...]:
    return tuple(grant.variant_scope or ["*"])


def _variant_scope(scope: tuple[str, ...]) -> tuple[VariantKind, ...] | None:
    if "*" in scope:
        return None
    resolved: list[VariantKind] = []
    for value in scope:
        try:
            resolved.append(VariantKind(value))
        except ValueError:
            continue
    return tuple(resolved)


def _remaining_seconds(grant) -> int:
    from app.modules.media.repository import as_utc, utcnow

    expires_at = as_utc(grant.expires_at)
    if expires_at is None:  # pragma: no cover - expiry is NOT NULL
        return 0
    return max(1, int((expires_at - utcnow()).total_seconds()))


@dataclass(frozen=True, slots=True)
class AccessDecision:
    outcome: AuthorizationOutcome
    rule: DerivedRule
    ttl_seconds: int
    reason: str
    #: ``None`` means "every variant of this object"; a tuple is an explicit allow-list.
    variant_scope: tuple[VariantKind, ...] | None = None
    grant_id: str | None = None
    grant_version: int | None = None
    single_use: bool = False
    #: Set when delivery must happen through another authority (Matrix).
    delegate_to: str | None = None

    @property
    def allowed(self) -> bool:
        return self.outcome is AuthorizationOutcome.ALLOWED

    @property
    def delegated(self) -> bool:
        return self.outcome is AuthorizationOutcome.DELEGATED

    def allows_variant(self, kind: VariantKind) -> bool:
        if not self.allowed:
            return False
        return self.variant_scope is None or kind in self.variant_scope


class Authorizer(Protocol):
    def authorize(
        self,
        *,
        media,
        subject_id: str,
        permission: Permission,
        variant_kind: VariantKind,
        visibility: VisibilityTier,
    ) -> AccessDecision: ...


@dataclass(frozen=True, slots=True)
class GrantAuthorizer:
    """Phase 4.4 decision function: owner → explicit grant → deny (fail closed).

    Audience reads are deliberately *not* decided here: an audience member reaches the
    bytes through a signed URL minted from an audience grant, and that path re-checks the
    grant's state and version. Deciding it here as well would mean guessing membership that
    the platform does not own.
    """

    grants: object
    ttl_policy: MediaTtlPolicy = field(default_factory=MediaTtlPolicy)

    def authorize(
        self,
        *,
        media,
        subject_id: str,
        permission: Permission,
        variant_kind: VariantKind,
        visibility: VisibilityTier,
    ) -> AccessDecision:
        with media_platform_metrics.timed("authorization_ms"):
            return self._decide(
                media=media,
                subject_id=subject_id,
                permission=permission,
                variant_kind=variant_kind,
                visibility=visibility,
            )

    def _decide(
        self,
        *,
        media,
        subject_id: str,
        permission: Permission,
        variant_kind: VariantKind,
        visibility: VisibilityTier,
    ) -> AccessDecision:
        media_platform_metrics.increment("authorization")
        ttl = self.ttl_policy.ttl_seconds(
            visibility=visibility, variant_kind=variant_kind, permission=permission
        )
        if subject_id and subject_id == media.owner_id:
            media_platform_metrics.increment("cache_hit")
            return AccessDecision(
                outcome=AuthorizationOutcome.ALLOWED,
                rule=DerivedRule.OWNER,
                ttl_seconds=ttl,
                reason="owner",
            )

        grant = self.grants.active_for_subject(
            media_id=media.media_id,
            subject_type=SubjectType.USER,
            subject_id=subject_id,
            permission=permission,
        )
        if grant is not None:
            scope = _scope_of(grant)
            if variant_kind.value in scope or "*" in scope:
                media_platform_metrics.increment("cache_hit")
                return AccessDecision(
                    outcome=AuthorizationOutcome.ALLOWED,
                    rule=DerivedRule.GRANT,
                    ttl_seconds=min(ttl, _remaining_seconds(grant)),
                    reason="grant",
                    variant_scope=_variant_scope(scope),
                    grant_id=grant.grant_id,
                    grant_version=grant.grant_version,
                    single_use=grant.single_use,
                )

        media_platform_metrics.increment("authorization_denied")
        media_platform_metrics.increment("cache_miss")
        return AccessDecision(
            outcome=AuthorizationOutcome.DENIED,
            rule=DerivedRule.GRANT,
            ttl_seconds=0,
            reason="no_grant",
        )


@dataclass(frozen=True, slots=True)
class OwnerOnlyAuthorizer:
    """Phase 4.2 default: only the owner may read.

    Deliberately the *narrowest* rule that makes the gateway usable. Phase 4.4 replaces it
    with the grant/audience implementation; keeping this default means an unfinished
    deployment cannot accidentally serve other users' media.
    """

    ttl_policy: MediaTtlPolicy = field(default_factory=MediaTtlPolicy)

    def authorize(
        self,
        *,
        media,
        subject_id: str,
        permission: Permission,
        variant_kind: VariantKind,
        visibility: VisibilityTier,
    ) -> AccessDecision:
        with media_platform_metrics.timed("authorization_ms"):
            return self._decide(
                media=media,
                subject_id=subject_id,
                permission=permission,
                variant_kind=variant_kind,
                visibility=visibility,
            )

    def _decide(
        self,
        *,
        media,
        subject_id: str,
        permission: Permission,
        variant_kind: VariantKind,
        visibility: VisibilityTier,
    ) -> AccessDecision:
        media_platform_metrics.increment("authorization")
        ttl = self.ttl_policy.ttl_seconds(
            visibility=visibility, variant_kind=variant_kind, permission=permission
        )
        if subject_id and subject_id == media.owner_id:
            media_platform_metrics.increment("cache_hit")
            return AccessDecision(
                outcome=AuthorizationOutcome.ALLOWED,
                rule=DerivedRule.OWNER,
                ttl_seconds=ttl,
                reason="owner",
            )
        media_platform_metrics.increment("authorization_denied")
        media_platform_metrics.increment("cache_miss")
        return AccessDecision(
            outcome=AuthorizationOutcome.DENIED,
            rule=DerivedRule.GRANT,
            ttl_seconds=0,
            reason="no_grant",
        )
