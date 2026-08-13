from datetime import datetime,timezone
from uuid import uuid4
from sqlalchemy import select
from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.moments.models import Moment,MomentComment,MomentLike,MomentReport,MomentsPreference
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
            pref=s.get(MomentsPreference,actor);cutoff=None
            if pref and pref.history_range!='ALL':
                from datetime import timedelta
                cutoff=datetime.now(timezone.utc)-{'THREE_DAYS':timedelta(days=3),'ONE_MONTH':timedelta(days=30),'SIX_MONTHS':timedelta(days=183)}[pref.history_range]
            statement=select(Moment).where(Moment.deleted_at.is_(None),Moment.status=='PUBLISHED').order_by(Moment.created_at.desc()).limit(50);rows=s.scalars(statement).all();policy=VisibilityPolicy(s);return [self.dto(s,m) for m in rows if policy.can_view(actor,m) and (cutoff is None or m.created_at>=cutoff) and (not q or q.casefold() in f'{m.text} {m.location or ""}'.casefold())]
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
    def preferences(self,actor,data=None):
        with self.factory.begin() as s:
            row=s.get(MomentsPreference,actor)
            if row is None:row=MomentsPreference(user_id=actor,history_range='ALL',personalized_recommendations=True,updated_at=datetime.now(timezone.utc));s.add(row)
            if data:row.history_range=data['history_range'];row.personalized_recommendations=data['personalized_recommendations'];row.updated_at=datetime.now(timezone.utc)
            return {'history_range':row.history_range,'personalized_recommendations':row.personalized_recommendations,'cover_url':row.cover_url}
    def report(self,actor,moment,reason,key):
        with self.factory.begin() as s:
            if s.get(Moment,moment) is None:raise AppError(code='MOMENT_NOT_FOUND',message='动态不存在',status_code=404)
            old=s.scalar(select(MomentReport).where(MomentReport.reporter_id==actor,MomentReport.idempotency_key==key))
            if old:return old
            row=MomentReport(id=str(uuid4()),moment_id=moment,reporter_id=actor,reason_code=reason,idempotency_key=key,status='OPEN',created_at=datetime.now(timezone.utc));s.add(row);OutboxPublisher.enqueue(s,topic='moments.moderation',event_type='moment.reported',aggregate_type='moment',aggregate_id=moment,payload={'report_id':row.id,'reason_code':reason});return row
    def dto(self,s,m):
        likes=len(s.scalars(select(MomentLike).where(MomentLike.moment_id==m.id)).all());comments=len(s.scalars(select(MomentComment).where(MomentComment.moment_id==m.id,MomentComment.deleted_at.is_(None))).all());return {'id':m.id,'author_id':m.author_id,'text':m.text,'visibility':m.visibility,'image_urls':m.image_urls,'status':m.status,'like_count':likes,'comment_count':comments,'created_at':m.created_at}
