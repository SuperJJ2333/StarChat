from sqlalchemy import and_,or_,select

from app.modules.friendship.models import Friendship,UserBlock


class VisibilityPolicy:
    def __init__(self, session):
        self.s = session

    def _are_friends(self, actor, author):
        low, high = sorted((actor, author))
        return bool(self.s.scalar(select(Friendship.id).where(
            Friendship.user_low_id == low, Friendship.user_high_id == high,
        )))

    def can_view(self, actor, moment):
        if moment.author_id == actor:
            return True
        blocked = self.s.scalar(select(UserBlock.id).where(or_(
            and_(UserBlock.blocker_id == actor, UserBlock.blocked_id == moment.author_id),
            and_(UserBlock.blocker_id == moment.author_id, UserBlock.blocked_id == actor),
        )))
        if blocked:
            return False
        is_friend = self._are_friends(actor, moment.author_id)
        if moment.visibility in ('PUBLIC', 'FRIENDS'):
            return is_friend
        if moment.visibility == 'INCLUDE':
            return is_friend and actor in (moment.include_user_ids or [])
        if moment.visibility == 'EXCLUDE':
            return is_friend and actor not in (moment.exclude_user_ids or [])
        return False
