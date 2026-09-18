"""Access grants (Phase 4.4).

A grant is a *server-side truth*: subject + permission + variant scope + expiry + a
derivable source. A signed URL is only ever a proof of a grant, never a grant itself, which
is why revoking a grant immediately invalidates every URL minted from it — including the
ones already forwarded inside an audience (ADR-003).

Only the media owner (or a service-subject flow) may issue or revoke a grant; ownership is
checked against the object, not against the caller's claim.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import timedelta
from typing import Any

from sqlalchemy import select

from app.core.errors import AppError
from app.modules.media.domain import (
    DerivedRule,
    MediaStatus,
    Permission,
    SubjectType,
    VariantKind,
    new_grant_id,
)
from app.modules.media.metrics import media_platform_metrics
from app.modules.media.models import MediaAccessGrant, MediaObject
from app.modules.media.repository import utcnow


@dataclass(frozen=True, slots=True)
class GrantView:
    grant_id: str
    media_id: str
    subject_type: str
    subject_id: str
    permission: str
    variant_scope: tuple[str, ...]
    derived_from: dict[str, Any] | None
    grant_version: int
    expires_at: str
    single_use: bool
    max_uses: int | None
    uses: int
    issued_by: str
    revoked_at: str | None
    revoke_reason: str | None

    @staticmethod
    def of(row: MediaAccessGrant) -> "GrantView":
        return GrantView(
            grant_id=row.grant_id,
            media_id=row.media_id,
            subject_type=row.subject_type,
            subject_id=row.subject_id,
            permission=row.permission,
            variant_scope=tuple(row.variant_scope or []),
            derived_from=row.derived_from,
            grant_version=row.grant_version,
            expires_at=row.expires_at.isoformat(),
            single_use=row.single_use,
            max_uses=row.max_uses,
            uses=row.uses,
            issued_by=row.issued_by,
            revoked_at=row.revoked_at.isoformat() if row.revoked_at else None,
            revoke_reason=row.revoke_reason,
        )


class MediaGrantService:
    def __init__(self, session_factory, *, now_factory=utcnow) -> None:
        self._session_factory = session_factory
        self._now = now_factory

    def issue(
        self,
        *,
        media_id: str,
        actor_id: str,
        subject_type: SubjectType,
        subject_id: str,
        permission: Permission = Permission.READ,
        variant_scope: list[str] | None = None,
        ttl_seconds: int = 600,
        single_use: bool = False,
        max_uses: int | None = None,
        derived_from: dict[str, Any] | None = None,
    ) -> GrantView:
        scope = variant_scope or ["*"]
        for kind in scope:
            if kind != "*":
                try:
                    VariantKind(kind)
                except ValueError:
                    raise AppError(
                        code="MEDIA_GRANT_INVALID",
                        message="授权范围不合法",
                        status_code=422,
                    ) from None
        now = self._now()
        with self._session_factory.begin() as session:
            media = session.get(MediaObject, media_id)
            if media is None or media.status == MediaStatus.DELETED.value:
                raise AppError(
                    code="MEDIA_OBJECT_NOT_FOUND", message="媒体不存在", status_code=404
                )
            self._assert_may_manage(media=media, actor_id=actor_id)

            existing = session.scalars(
                select(MediaAccessGrant).where(
                    MediaAccessGrant.media_id == media_id,
                    MediaAccessGrant.subject_type == subject_type.value,
                    MediaAccessGrant.subject_id == subject_id,
                    MediaAccessGrant.permission == permission.value,
                    MediaAccessGrant.revoked_at.is_(None),
                )
            ).first()
            if existing is not None:
                existing.variant_scope = scope
                existing.expires_at = now + timedelta(seconds=max(1, ttl_seconds))
                existing.single_use = single_use
                existing.max_uses = max_uses
                existing.derived_from = derived_from or existing.derived_from
                return GrantView.of(existing)

            row = MediaAccessGrant(
                grant_id=new_grant_id(),
                media_id=media_id,
                variant_scope=scope,
                subject_type=subject_type.value,
                subject_id=subject_id,
                permission=permission.value,
                derived_from=derived_from,
                grant_version=1,
                expires_at=now + timedelta(seconds=max(1, ttl_seconds)),
                single_use=single_use,
                uses=0,
                max_uses=max_uses,
                issued_by=actor_id,
                created_at=now,
            )
            session.add(row)
            media_platform_metrics.increment("grant_issued")
            return GrantView.of(row)

    def revoke(
        self,
        *,
        grant_id: str,
        actor_id: str,
        reason: str = "owner_revoked",
    ) -> GrantView:
        now = self._now()
        with self._session_factory.begin() as session:
            row = session.get(MediaAccessGrant, grant_id)
            if row is None:
                raise AppError(
                    code="MEDIA_GRANT_NOT_FOUND", message="授权不存在", status_code=404
                )
            media = session.get(MediaObject, row.media_id)
            if media is not None:
                self._assert_may_manage(media=media, actor_id=actor_id)
            if row.revoked_at is None:
                row.revoked_at = now
                row.revoke_reason = reason
                # Bump the version so tokens minted before the revocation stop verifying
                # even if they are still inside their TTL (ADR-003).
                row.grant_version = row.grant_version + 1
                media_platform_metrics.increment("grant_revoked")
            return GrantView.of(row)

    def list_for_media(self, media_id: str, *, include_revoked: bool = False) -> list[GrantView]:
        with self._session_factory() as session:
            statement = select(MediaAccessGrant).where(MediaAccessGrant.media_id == media_id)
            if not include_revoked:
                statement = statement.where(MediaAccessGrant.revoked_at.is_(None))
            return [
                GrantView.of(row)
                for row in session.scalars(statement.order_by(MediaAccessGrant.created_at))
            ]

    def get(self, grant_id: str) -> MediaAccessGrant | None:
        with self._session_factory() as session:
            return session.get(MediaAccessGrant, grant_id)

    def active_for_subject(
        self,
        *,
        media_id: str,
        subject_type: SubjectType,
        subject_id: str,
        permission: Permission,
    ) -> MediaAccessGrant | None:
        now = self._now()
        with self._session_factory() as session:
            row = session.scalars(
                select(MediaAccessGrant)
                .where(
                    MediaAccessGrant.media_id == media_id,
                    MediaAccessGrant.subject_type == subject_type.value,
                    MediaAccessGrant.subject_id == subject_id,
                    MediaAccessGrant.permission == permission.value,
                    MediaAccessGrant.revoked_at.is_(None),
                )
                .limit(1)
            ).first()
            if row is None:
                return None
            expires_at = row.expires_at
            if expires_at.tzinfo is None:
                expires_at = expires_at.replace(tzinfo=now.tzinfo)
            if expires_at <= now:
                return None
            return row

    def consume(self, grant_id: str) -> None:
        """Record one use; refuses to exceed ``max_uses`` (single-use included)."""

        now = self._now()
        with self._session_factory.begin() as session:
            row = session.get(MediaAccessGrant, grant_id, with_for_update=True)
            if row is None or row.revoked_at is not None:
                raise AppError(
                    code="MEDIA_GRANT_NOT_FOUND", message="授权不存在", status_code=404
                )
            if row.max_uses is not None and row.uses >= row.max_uses:
                raise AppError(
                    code="MEDIA_GRANT_EXHAUSTED",
                    message="授权已用尽",
                    status_code=403,
                )
            row.uses = row.uses + 1
            del now

    @staticmethod
    def _assert_may_manage(*, media: MediaObject, actor_id: str) -> None:
        if actor_id != media.owner_id:
            raise AppError(
                code="MEDIA_ACCESS_DENIED",
                message="无权管理该媒体授权",
                status_code=403,
            )


#: Rule names that may be attached to a grant as its derivable source.
DERIVABLE_RULES = (
    DerivedRule.OWNER.value,
    DerivedRule.ROOM_MEMBERSHIP.value,
    DerivedRule.MOMENT_VISIBILITY.value,
    DerivedRule.PUBLIC_VERSION.value,
)


def scope_allows(variant_scope: tuple[str, ...], kind: VariantKind) -> bool:
    return "*" in variant_scope or kind.value in variant_scope
