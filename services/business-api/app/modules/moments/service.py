from datetime import datetime,timezone
from uuid import uuid4
from sqlalchemy import select
from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.moments.models import Moment,MomentComment,MomentLike
from app.modules.moments.visibility import VisibilityPolicy
class MomentsService:
    def __init__(self,factory):self.factory=factory
    def create(self,actor,data,key):
        if len(data.get('image_urls',[]))>9:raise AppError(code='MOMENT_IMAGE_LIMIT',message='最多上传9张图片',status_code=422)
        with self.factory.begin() as s:
            old=s.scalar(select(Moment).where(Moment.author_id==actor,Moment.idempotency_key==key))
            if old:return old
            row=Moment(id=str(uuid4()),author_id=actor,text=data.get('text',''),visibility=data['visibility'],image_urls=data.get('image_urls',[]),include_user_ids=data.get('include_user_ids',[]),exclude_user_ids=data.get('exclude_user_ids',[]),location=data.get('location'),link_url=data.get('link_url'),status='PUBLISHED',idempotency_key=key,created_at=datetime.now(timezone.utc));s.add(row);OutboxPublisher.enqueue(s,topic='moments.events',event_type='moment.published',aggregate_type='moment',aggregate_id=row.id,payload={'author_id':actor});return row
    def feed(self,actor,q=None):
        with self.factory() as s:
            statement=select(Moment).where(Moment.deleted_at.is_(None),Moment.status=='PUBLISHED').order_by(Moment.created_at.desc()).limit(50);rows=s.scalars(statement).all();policy=VisibilityPolicy(s);return [self.dto(s,m) for m in rows if policy.can_view(actor,m) and (not q or q.casefold() in m.text.casefold())]
    def like(self,actor,moment,key):
        with self.factory.begin() as s:
            m=s.get(Moment,moment)
            if not m or not VisibilityPolicy(s).can_view(actor,m):raise AppError(code='MOMENT_NOT_FOUND',message='动态不存在',status_code=404)
            old=s.scalar(select(MomentLike).where(MomentLike.user_id==actor,MomentLike.idempotency_key==key))
            if old:return old
            row=MomentLike(id=str(uuid4()),moment_id=moment,user_id=actor,idempotency_key=key,created_at=datetime.now(timezone.utc));s.add(row);return row
    def comment(self,actor,moment,text,key):
        with self.factory.begin() as s:
            m=s.get(Moment,moment)
            if not m or not VisibilityPolicy(s).can_view(actor,m):raise AppError(code='MOMENT_NOT_FOUND',message='动态不存在',status_code=404)
            row=MomentComment(id=str(uuid4()),moment_id=moment,user_id=actor,text=text,idempotency_key=key,created_at=datetime.now(timezone.utc));s.add(row);return row
    def dto(self,s,m):
        likes=len(s.scalars(select(MomentLike).where(MomentLike.moment_id==m.id)).all());comments=len(s.scalars(select(MomentComment).where(MomentComment.moment_id==m.id,MomentComment.deleted_at.is_(None))).all());return {'id':m.id,'author_id':m.author_id,'text':m.text,'visibility':m.visibility,'image_urls':m.image_urls,'status':m.status,'like_count':likes,'comment_count':comments,'created_at':m.created_at}
