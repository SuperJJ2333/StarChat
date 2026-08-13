from datetime import datetime
from sqlalchemy import DateTime,ForeignKey,JSON,String,Text,UniqueConstraint
from sqlalchemy.orm import Mapped,mapped_column
from app.core.database import Base
class Moment(Base):
    __tablename__='moments';__table_args__=(UniqueConstraint('author_id','idempotency_key',name='uq_moment_idempotency'),)
    id:Mapped[str]=mapped_column(String(36),primary_key=True);author_id:Mapped[str]=mapped_column(ForeignKey('users.id'),index=True);text:Mapped[str]=mapped_column(Text);visibility:Mapped[str]=mapped_column(String(30),index=True);image_urls:Mapped[list]=mapped_column(JSON);include_user_ids:Mapped[list]=mapped_column(JSON,default=list);exclude_user_ids:Mapped[list]=mapped_column(JSON,default=list);location:Mapped[str|None]=mapped_column(String(255));link_url:Mapped[str|None]=mapped_column(String(2048));status:Mapped[str]=mapped_column(String(30),index=True);idempotency_key:Mapped[str]=mapped_column(String(128));created_at:Mapped[datetime]=mapped_column(DateTime(timezone=True),index=True);deleted_at:Mapped[datetime|None]=mapped_column(DateTime(timezone=True))
class MomentLike(Base):
    __tablename__='moment_likes';__table_args__=(UniqueConstraint('moment_id','user_id',name='uq_moment_like'),UniqueConstraint('user_id','idempotency_key',name='uq_moment_like_idempotency'))
    id:Mapped[str]=mapped_column(String(36),primary_key=True);moment_id:Mapped[str]=mapped_column(ForeignKey('moments.id'),index=True);user_id:Mapped[str]=mapped_column(ForeignKey('users.id'));idempotency_key:Mapped[str]=mapped_column(String(128));created_at:Mapped[datetime]=mapped_column(DateTime(timezone=True))
class MomentComment(Base):
    __tablename__='moment_comments';__table_args__=(UniqueConstraint('user_id','idempotency_key',name='uq_moment_comment_idempotency'),)
    id:Mapped[str]=mapped_column(String(36),primary_key=True);moment_id:Mapped[str]=mapped_column(ForeignKey('moments.id'),index=True);user_id:Mapped[str]=mapped_column(ForeignKey('users.id'));parent_id:Mapped[str|None]=mapped_column(String(36));text:Mapped[str]=mapped_column(Text);idempotency_key:Mapped[str]=mapped_column(String(128));created_at:Mapped[datetime]=mapped_column(DateTime(timezone=True));deleted_at:Mapped[datetime|None]=mapped_column(DateTime(timezone=True))
class MomentsPreference(Base):
    __tablename__='moments_preferences'
    user_id:Mapped[str]=mapped_column(ForeignKey('users.id'),primary_key=True);history_range:Mapped[str]=mapped_column(String(20),default='ALL');personalized_recommendations:Mapped[bool]=mapped_column(default=True);cover_url:Mapped[str|None]=mapped_column(String(2048));updated_at:Mapped[datetime]=mapped_column(DateTime(timezone=True))
class MomentReport(Base):
    __tablename__='moment_reports';__table_args__=(UniqueConstraint('reporter_id','idempotency_key',name='uq_moment_report_idempotency'),)
    id:Mapped[str]=mapped_column(String(36),primary_key=True);moment_id:Mapped[str]=mapped_column(ForeignKey('moments.id'),index=True);reporter_id:Mapped[str]=mapped_column(ForeignKey('users.id'));reason_code:Mapped[str]=mapped_column(String(100));idempotency_key:Mapped[str]=mapped_column(String(128));status:Mapped[str]=mapped_column(String(20));created_at:Mapped[datetime]=mapped_column(DateTime(timezone=True))
