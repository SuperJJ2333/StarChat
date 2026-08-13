from datetime import datetime,timezone
from uuid import uuid4
from sqlalchemy import or_,select
from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.audit.models import AuditEvent
from app.modules.identity.models import User
from app.modules.friendship.models import ContactProfile,FriendRequest,Friendship,UserBlock

class FriendshipService:
    def __init__(self,factory):self.factory=factory
    def _audit(self,s,actor,subject,action,reason,key):
        now=datetime.now(timezone.utc);s.add(AuditEvent(id=str(uuid4()),actor_id=actor,subject_type='friendship',subject_id=subject,action=action,result='SUCCESS',reason_code=reason,trace_id=key[:128],created_at=now));OutboxPublisher.enqueue(s,topic='friendship.events',event_type=action,aggregate_type='friendship',aggregate_id=subject,payload={'actor_id':actor})
    def request(self,actor,target,message,key):
        if actor==target:raise AppError(code='INVALID_FRIEND_TARGET',message='不能添加自己',status_code=422)
        now=datetime.now(timezone.utc)
        with self.factory.begin() as s:
            existing=s.scalar(select(FriendRequest).where(FriendRequest.requester_id==actor,FriendRequest.idempotency_key==key));
            if existing:return existing
            if s.get(User,target) is None:raise AppError(code='USER_NOT_FOUND',message='用户不存在',status_code=404)
            row=FriendRequest(id=str(uuid4()),requester_id=actor,target_id=target,message=message,status='PENDING',idempotency_key=key,created_at=now);s.add(row);self._audit(s,actor,row.id,'friend.requested','FRIEND_REQUEST',key);return row
    def accept(self,actor,request_id,key):
        with self.factory.begin() as s:
            row=s.get(FriendRequest,request_id)
            if not row or row.target_id!=actor:raise AppError(code='FRIEND_REQUEST_NOT_FOUND',message='好友申请不存在',status_code=404)
            if row.status=='ACCEPTED':return row
            if row.status!='PENDING':raise AppError(code='FRIEND_REQUEST_RESOLVED',message='好友申请已处理',status_code=409)
            low,high=sorted((row.requester_id,row.target_id));friend=Friendship(id=str(uuid4()),user_low_id=low,user_high_id=high,created_at=datetime.now(timezone.utc));s.add(friend);row.status='ACCEPTED';row.resolved_at=datetime.now(timezone.utc);self._audit(s,actor,friend.id,'friend.accepted','FRIEND_ACCEPT',key);return row
    def list(self,actor):
        with self.factory() as s:
            rows=s.scalars(select(Friendship).where(or_(Friendship.user_low_id==actor,Friendship.user_high_id==actor))).all();ids=[r.user_high_id if r.user_low_id==actor else r.user_low_id for r in rows];users={u.id:u for u in s.scalars(select(User).where(User.id.in_(ids))).all()} if ids else {};return [{'user_id':i,'username':users[i].username} for i in ids if i in users]
    def block(self,actor,target,key):
        with self.factory.begin() as s:
            row=s.scalar(select(UserBlock).where(UserBlock.blocker_id==actor,UserBlock.blocked_id==target))
            if row:return row
            row=UserBlock(id=str(uuid4()),blocker_id=actor,blocked_id=target,idempotency_key=key,created_at=datetime.now(timezone.utc));s.add(row);self._audit(s,actor,row.id,'friend.blocked','USER_BLOCK',key);return row
    def search(self,actor,q):
        with self.factory() as s:
            blocked=set(s.scalars(select(UserBlock.blocked_id).where(UserBlock.blocker_id==actor)).all())|set(s.scalars(select(UserBlock.blocker_id).where(UserBlock.blocked_id==actor)).all());rows=s.scalars(select(User).where(User.username_normalized.contains(q.casefold())).limit(20)).all();return [{'id':u.id,'username':u.username} for u in rows if u.id!=actor and u.id not in blocked]
