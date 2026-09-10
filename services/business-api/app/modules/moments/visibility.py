from datetime import datetime, timedelta, timezone

from sqlalchemy import and_,or_,select

from app.modules.friendship.models import ContactProfile,Friendship,UserBlock
from app.modules.moments.models import MomentsPreference


def reaction_audience(session, viewer):
    """Resolve live reaction visibility once per read session, in four queries."""
    cache = session.info.setdefault('moments_reaction_audience', {})
    if viewer in cache:
        return cache[viewer]
    if not viewer:
        return set()
    friends = session.scalars(select(Friendship).where(or_(
        Friendship.user_low_id == viewer, Friendship.user_high_id == viewer,
    )))
    visible = {row.user_high_id if row.user_low_id == viewer else row.user_low_id for row in friends}
    blocks = session.scalars(select(UserBlock).where(or_(
        UserBlock.blocker_id == viewer, UserBlock.blocked_id == viewer,
    )))
    for row in blocks:
        visible.discard(row.blocked_id if row.blocker_id == viewer else row.blocker_id)
    profiles = session.scalars(select(ContactProfile).where(or_(
        ContactProfile.owner_id == viewer, ContactProfile.contact_id == viewer,
    )))
    for row in profiles:
        restricted = {'HIDE_BOTH', 'CHAT_ONLY', 'ONLY_CHAT'}
        restricted.add('HIDE_THEIRS' if row.owner_id == viewer else 'HIDE_MINE')
        if row.moments_permission in restricted:
            visible.discard(row.contact_id if row.owner_id == viewer else row.owner_id)
    for row in session.scalars(select(MomentsPreference).where(MomentsPreference.user_id.in_(visible))):
        if not row.profile_entry_enabled or viewer in (row.excluded_user_ids or []):
            visible.discard(row.user_id)
    visible.add(viewer)
    cache[viewer] = visible
    return visible


def moment_comment_audience(session, viewer, author):
    """Keep owner semantics; foreign comments require a live common audience."""
    audience = reaction_audience(session, viewer)
    if not viewer or viewer == author:
        return audience
    return (audience & reaction_audience(session, author)) | {viewer, author}


class VisibilityPolicy:
    def __init__(self, session, *, now=None):
        self.s = session
        self.now = now or datetime.now(timezone.utc)
        self._author_visibility = {}
        self._preferences = {}

    def _are_friends(self, actor, author):
        low, high = sorted((actor, author))
        return bool(self.s.scalar(select(Friendship.id).where(
            Friendship.user_low_id == low, Friendship.user_high_id == high,
        )))

    def _preference(self, author):
        if author not in self._preferences:
            self._preferences[author] = self.s.get(MomentsPreference, author)
        return self._preferences[author]

    def can_view_author(self, actor, author):
        key = (actor, author)
        if key not in self._author_visibility:
            self._author_visibility[key] = self._can_view_author(actor, author)
        return self._author_visibility[key]

    def _can_view_author(self, actor, author):
        if author == actor:
            return True
        preference = self._preference(author)
        if preference and (not preference.profile_entry_enabled or actor in (preference.excluded_user_ids or [])):
            return False
        blocked = self.s.scalar(select(UserBlock.id).where(or_(
            and_(UserBlock.blocker_id == actor, UserBlock.blocked_id == author),
            and_(UserBlock.blocker_id == author, UserBlock.blocked_id == actor),
        )))
        if blocked:
            return False
        # Contact preferences are directional: the author controls who can see
        # their posts, while the viewer controls whose posts they want to see.
        preferences = self.s.scalars(select(ContactProfile).where(or_(
            and_(ContactProfile.owner_id == author, ContactProfile.contact_id == actor),
            and_(ContactProfile.owner_id == actor, ContactProfile.contact_id == author),
        )))
        for preference in preferences:
            restricted = {'HIDE_BOTH', 'CHAT_ONLY', 'ONLY_CHAT'}
            restricted.add('HIDE_MINE' if preference.owner_id == author else 'HIDE_THEIRS')
            if preference.moments_permission in restricted:
                return False
        return self._are_friends(actor, author)

    def can_view(self, actor, moment):
        if moment.author_id == actor:
            return True
        if not self.can_view_author(actor, moment.author_id):
            return False
        preference = self._preference(moment.author_id)
        days = {'THREE_DAYS': 3, 'ONE_MONTH': 30, 'SIX_MONTHS': 183}.get(preference.history_range if preference else 'ALL')
        created_at = moment.created_at
        if created_at.tzinfo is None:
            created_at = created_at.replace(tzinfo=timezone.utc)
        if days is not None and created_at < self.now - timedelta(days=days):
            return False
        if moment.visibility in ('PUBLIC', 'FRIENDS'):
            return True
        if moment.visibility == 'INCLUDE':
            return actor in (moment.include_user_ids or [])
        if moment.visibility == 'EXCLUDE':
            return actor not in (moment.exclude_user_ids or [])
        return False
