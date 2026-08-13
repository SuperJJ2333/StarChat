from sqlalchemy import and_,or_,select
from app.modules.friendship.models import Friendship,UserBlock
class VisibilityPolicy:
    def __init__(self,session):self.s=session
    def can_view(self,actor,m):
        if m.author_id==actor:return True
        blocked=self.s.scalar(select(UserBlock.id).where(or_(and_(UserBlock.blocker_id==actor,UserBlock.blocked_id==m.author_id),and_(UserBlock.blocker_id==m.author_id,UserBlock.blocked_id==actor))))
        if blocked:return False
        if m.visibility=='PUBLIC':return True
        low,high=sorted((actor,m.author_id));friend=self.s.scalar(select(Friendship.id).where(Friendship.user_low_id==low,Friendship.user_high_id==high))
        if m.visibility=='FRIENDS':return bool(friend)
        if m.visibility=='INCLUDE':return actor in (m.include_user_ids or [])
        if m.visibility=='EXCLUDE':return bool(friend) and actor not in (m.exclude_user_ids or [])
        return False
