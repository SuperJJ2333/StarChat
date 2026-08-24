from datetime import datetime,timezone
from hashlib import sha256
import json
from uuid import uuid4
from sqlalchemy import delete,or_,select
from app.core.errors import AppError
from app.core.idempotency import IdempotencyRecord
from app.core.outbox import OutboxPublisher
from app.modules.audit.models import AuditEvent
from app.modules.friendship.models import ContactProfile,ContactTag,FriendRequest,Friendship,UserBlock

class FriendshipService:
    def __init__(self,factory,profile_reader):self.factory=factory;self.profile_reader=profile_reader
    def _audit(self,s,actor,subject,action,reason,key):
        now=datetime.now(timezone.utc);s.add(AuditEvent(id=str(uuid4()),actor_id=actor,subject_type='friendship',subject_id=subject,action=action,result='SUCCESS',reason_code=reason,trace_id=key[:128],created_at=now));OutboxPublisher.enqueue(s,topic='friendship.events',event_type=action,aggregate_type='friendship',aggregate_id=subject,payload={'actor_id':actor})
    def _idempotency(self,s,scope,key,payload):
        digest=sha256(json.dumps(payload,sort_keys=True,separators=(',',':')).encode()).hexdigest()
        record=s.scalar(select(IdempotencyRecord).where(IdempotencyRecord.scope==scope,IdempotencyRecord.idempotency_key==key))
        if record:
            if record.request_hash!=digest:raise AppError(code='IDEMPOTENCY_KEY_REUSED',message='幂等键已用于不同请求',status_code=409)
            return True
        now=datetime.now(timezone.utc);s.add(IdempotencyRecord(id=str(uuid4()),scope=scope,idempotency_key=key,request_hash=digest,status='COMPLETED',response_status=204,response_body={},created_at=now,completed_at=now));return False
    def request(self,actor,target,message,key):
        if actor==target:raise AppError(code='INVALID_FRIEND_TARGET',message='不能添加自己',status_code=422)
        if target not in self.profile_reader.read_public_profiles([target]):raise AppError(code='USER_NOT_FOUND',message='用户不存在',status_code=404)
        now=datetime.now(timezone.utc)
        with self.factory.begin() as s:
            existing=s.scalar(select(FriendRequest).where(FriendRequest.requester_id==actor,FriendRequest.idempotency_key==key));
            if existing:
                if existing.target_id != target or existing.message != message:
                    raise AppError(code='IDEMPOTENCY_KEY_REUSED',message='幂等键已用于不同请求',status_code=409)
                return existing
            low,high=sorted((actor,target))
            if s.scalar(select(Friendship.id).where(Friendship.user_low_id==low,Friendship.user_high_id==high)):
                raise AppError(code='FRIEND_REQUEST_DUPLICATE',message='不能重复发送好友请求',status_code=409)
            prior=list(s.scalars(select(FriendRequest).where(FriendRequest.requester_id==actor,FriendRequest.target_id==target).order_by(FriendRequest.requested_at.desc(),FriendRequest.id.desc())).all())
            pending=next((item for item in prior if item.status=='PENDING'),None)
            if pending:
                raise AppError(code='FRIEND_REQUEST_DUPLICATE',message='不能重复发送好友请求',status_code=409)
            reusable=next((item for item in prior if item.status in {'REJECTED','EXPIRED'}),None)
            if reusable:
                reusable.message=message; reusable.status='PENDING'; reusable.idempotency_key=key; reusable.requested_at=now; reusable.resolved_at=None
                self._audit(s,actor,reusable.id,'friend.request.reused','FRIEND_REQUEST',key); return reusable
            row=FriendRequest(id=str(uuid4()),requester_id=actor,target_id=target,message=message,status='PENDING',idempotency_key=key,created_at=now,requested_at=now);s.add(row);self._audit(s,actor,row.id,'friend.requested','FRIEND_REQUEST',key);return row
    def accept(self,actor,request_id,key):
        with self.factory.begin() as s:
            row=s.get(FriendRequest,request_id)
            if not row or row.target_id!=actor:raise AppError(code='FRIEND_REQUEST_NOT_FOUND',message='好友申请不存在',status_code=404)
            if row.status=='ACCEPTED':return row
            if row.status!='PENDING':raise AppError(code='FRIEND_REQUEST_RESOLVED',message='好友申请已处理',status_code=409)
            low,high=sorted((row.requester_id,row.target_id));friend=Friendship(id=str(uuid4()),user_low_id=low,user_high_id=high,created_at=datetime.now(timezone.utc));s.add(friend);row.status='ACCEPTED';row.resolved_at=datetime.now(timezone.utc);self._audit(s,actor,friend.id,'friend.accepted','FRIEND_ACCEPT',key);return row
    def reject(self,actor,request_id,key):
        with self.factory.begin() as s:
            row=s.get(FriendRequest,request_id)
            if not row or row.target_id!=actor:raise AppError(code='FRIEND_REQUEST_NOT_FOUND',message='好友申请不存在',status_code=404)
            if row.status=='REJECTED':return row
            if row.status!='PENDING':raise AppError(code='FRIEND_REQUEST_RESOLVED',message='好友申请已处理',status_code=409)
            row.status='REJECTED';row.resolved_at=datetime.now(timezone.utc);self._audit(s,actor,row.id,'friend.rejected','FRIEND_REJECT',key);return row
    def list(self,actor):
        with self.factory() as s:
            rows=s.scalars(select(Friendship).where(or_(Friendship.user_low_id==actor,Friendship.user_high_id==actor)).order_by(Friendship.created_at,Friendship.id)).all();ids=[r.user_high_id if r.user_low_id==actor else r.user_low_id for r in rows];contact_rows=s.scalars(select(ContactProfile).where(ContactProfile.owner_id==actor,ContactProfile.contact_id.in_(ids))).all() if ids else [];contacts={row.contact_id:row for row in contact_rows}
        profiles=self.profile_reader.read_public_profiles(ids);items=[]
        for user_id in ids:
            profile=profiles.get(user_id)
            if profile is None:continue
            contact=contacts.get(user_id);items.append({'user_id':profile.user_id,'username':profile.username,'nickname':profile.nickname,'remark':contact.remark if contact else None,'avatar_url':profile.avatar_url,'matrix_user_id':profile.matrix_user_id,'nudge_suffix':profile.nudge_suffix,'moments_permission':contact.moments_permission if contact else 'DEFAULT','tags':contact.tags.split(',') if contact and contact.tags else []})
        return items
    def requests(self,actor):
        with self.factory() as s:rows=list(s.scalars(select(FriendRequest).where(FriendRequest.target_id==actor).order_by(FriendRequest.requested_at.desc(),FriendRequest.id.desc())))
        profiles=self.profile_reader.read_public_profiles([row.requester_id for row in rows]);return [{'id':row.id,'username':profiles[row.requester_id].username,'nickname':profiles[row.requester_id].nickname,'avatar_url':profiles[row.requester_id].avatar_url,'message':row.message,'status':row.status,'requested_at':row.requested_at.isoformat()} for row in rows if row.requester_id in profiles]
    def block(self,actor,target,key):
        with self.factory.begin() as s:
            row=s.scalar(select(UserBlock).where(UserBlock.blocker_id==actor,UserBlock.blocked_id==target))
            if row:return row
            row=UserBlock(id=str(uuid4()),blocker_id=actor,blocked_id=target,idempotency_key=key,created_at=datetime.now(timezone.utc));s.add(row);self._audit(s,actor,row.id,'friend.blocked','USER_BLOCK',key);return row
    def blocks(self,actor):
        with self.factory() as s:return [{'id':row.id,'user_id':row.blocked_id} for row in s.scalars(select(UserBlock).where(UserBlock.blocker_id==actor).order_by(UserBlock.created_at,UserBlock.id)).all()]
    def unblock(self,actor,target,key):
        with self.factory.begin() as s:
            row=s.scalar(select(UserBlock).where(UserBlock.blocker_id==actor,UserBlock.blocked_id==target))
            if row:s.delete(row);self._audit(s,actor,row.id,'friend.unblocked','USER_UNBLOCK',key)
    def create_tag(self,actor,name,key):
        with self.factory.begin() as s:
            old=s.scalar(select(ContactTag).where(ContactTag.owner_id==actor,ContactTag.name==name))
            if old:return old
            row=ContactTag(id=str(uuid4()),owner_id=actor,name=name,created_at=datetime.now(timezone.utc));s.add(row);self._audit(s,actor,row.id,'friend.tag_created','CONTACT_TAG_CREATE',key);return row
    def tags(self,actor):
        with self.factory() as s:
            rows=s.scalars(select(ContactTag).where(ContactTag.owner_id==actor).order_by(ContactTag.name,ContactTag.id)).all()
            profiles=s.scalars(select(ContactProfile).where(ContactProfile.owner_id==actor)).all()
            return [{'id':row.id,'name':row.name,'friend_count':sum(row.name in set(filter(None,(profile.tags or '').split(','))) for profile in profiles)} for row in rows]
    def delete_tag(self,actor,tag_id,key):
        self.delete_tags(actor,[tag_id],key)
    def delete_tags(self,actor,tag_ids,key):
        ids=list(dict.fromkeys(tag_ids))
        with self.factory.begin() as s:
            if self._idempotency(s,f'friend.tag.delete:{actor}',key,{'tag_ids':ids}):return
            rows=list(s.scalars(select(ContactTag).where(ContactTag.id.in_(ids),ContactTag.owner_id==actor)).all())
            if len(rows)!=len(ids):raise AppError(code='CONTACT_TAG_NOT_FOUND',message='标签不存在',status_code=404)
            names={row.name for row in rows}
            for profile in s.scalars(select(ContactProfile).where(ContactProfile.owner_id==actor)).all():
                values=[value for value in (profile.tags or '').split(',') if value and value not in names]
                profile.tags=','.join(values)
            for row in rows:
                self._audit(s,actor,row.id,'friend.tag_deleted','CONTACT_TAG_DELETE',key)
                s.delete(row)
    def rename_tag(self,actor,tag_id,name,key):
        name=name.strip()
        with self.factory.begin() as s:
            row=s.get(ContactTag,tag_id)
            if not row or row.owner_id!=actor:raise AppError(code='CONTACT_TAG_NOT_FOUND',message='标签不存在',status_code=404)
            existing=s.scalar(select(ContactTag).where(ContactTag.owner_id==actor,ContactTag.name==name))
            if existing is not None and existing.id!=tag_id:raise AppError(code='CONTACT_TAG_DUPLICATE',message='标签名称已存在',status_code=409)
            old_name=row.name
            for profile in s.scalars(select(ContactProfile).where(ContactProfile.owner_id==actor)).all():
                values=[name if value==old_name else value for value in (profile.tags or '').split(',') if value]
                profile.tags=','.join(values)
            row.name=name;self._audit(s,actor,tag_id,'friend.tag_renamed','CONTACT_TAG_RENAME',key);return row
    def update_profile(self,actor,target,remark,tags,permission,key):
        low,high=sorted((actor,target))
        with self.factory.begin() as s:
            if not s.scalar(select(Friendship.id).where(Friendship.user_low_id==low,Friendship.user_high_id==high)):raise AppError(code='FRIEND_NOT_FOUND',message='好友不存在',status_code=404)
            row=s.scalar(select(ContactProfile).where(ContactProfile.owner_id==actor,ContactProfile.contact_id==target))
            if self._idempotency(s,f'friend.profile:{actor}',key,{'target':target,'remark':remark,'tags':tags,'permission':permission}):return row
            if row is None:row=ContactProfile(id=str(uuid4()),owner_id=actor,contact_id=target,remark=remark,tags=','.join(tags),moments_permission=permission);s.add(row)
            else:row.remark=remark;row.tags=','.join(tags);row.moments_permission=permission
            self._audit(s,actor,row.id,'friend.profile_updated','CONTACT_PROFILE_UPDATE',key);return row
    def delete_friend(self,actor,target,key):
        low,high=sorted((actor,target))
        with self.factory.begin() as s:
            if self._idempotency(s,f'friend.delete:{actor}',key,{'target':target}):return
            row=s.scalar(select(Friendship).where(Friendship.user_low_id==low,Friendship.user_high_id==high))
            if not row:raise AppError(code='FRIEND_NOT_FOUND',message='好友不存在',status_code=404)
            subject=row.id;self._audit(s,actor,subject,'friend.deleted','FRIEND_DELETE',key);s.delete(row);s.execute(delete(ContactProfile).where(or_(ContactProfile.owner_id==actor,ContactProfile.contact_id==actor),or_(ContactProfile.owner_id==target,ContactProfile.contact_id==target)))
    def search(self,actor,q):
        with self.factory() as s:
            blocked=set(s.scalars(select(UserBlock.blocked_id).where(UserBlock.blocker_id==actor)).all())|set(s.scalars(select(UserBlock.blocker_id).where(UserBlock.blocked_id==actor)).all())
            pending={row.target_id for row in s.scalars(select(FriendRequest).where(FriendRequest.requester_id==actor,FriendRequest.status=='PENDING')).all()}
            reusable={row.target_id for row in s.scalars(select(FriendRequest).where(FriendRequest.requester_id==actor,FriendRequest.status.in_(['REJECTED','EXPIRED']))).all()}
            friendships=list(s.scalars(select(Friendship).where(or_(Friendship.user_low_id==actor,Friendship.user_high_id==actor))).all())
            friends={row.user_high_id if row.user_low_id==actor else row.user_low_id for row in friendships}
        profiles=self.profile_reader.search_public_profiles(q,exclude_user_ids=blocked|{actor})
        return [{'user_id':p.user_id,'username':p.username,'nickname':p.nickname,'avatar_url':p.avatar_url,'matrix_user_id':p.matrix_user_id,'relationship_state':'FRIEND' if p.user_id in friends else 'OUTGOING_PENDING' if p.user_id in pending else 'REUSABLE' if p.user_id in reusable else 'NONE'} for p in profiles]
