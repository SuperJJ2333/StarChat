from datetime import datetime
from sqlalchemy import DateTime, ForeignKey, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column
from app.core.database import Base

class FriendRequest(Base):
    __tablename__='friend_requests'; __table_args__=(UniqueConstraint('requester_id','idempotency_key',name='uq_friend_request_idempotency'),)
    id:Mapped[str]=mapped_column(String(36),primary_key=True);requester_id:Mapped[str]=mapped_column(ForeignKey('users.id'),index=True);target_id:Mapped[str]=mapped_column(ForeignKey('users.id'),index=True);message:Mapped[str]=mapped_column(Text,default='');status:Mapped[str]=mapped_column(String(20));idempotency_key:Mapped[str]=mapped_column(String(128));created_at:Mapped[datetime]=mapped_column(DateTime(timezone=True));resolved_at:Mapped[datetime|None]=mapped_column(DateTime(timezone=True))
class Friendship(Base):
    __tablename__='friendships'; __table_args__=(UniqueConstraint('user_low_id','user_high_id',name='uq_friendship_pair'),)
    id:Mapped[str]=mapped_column(String(36),primary_key=True);user_low_id:Mapped[str]=mapped_column(ForeignKey('users.id'),index=True);user_high_id:Mapped[str]=mapped_column(ForeignKey('users.id'),index=True);created_at:Mapped[datetime]=mapped_column(DateTime(timezone=True))
class ContactProfile(Base):
    __tablename__='contact_profiles';__table_args__=(UniqueConstraint('owner_id','contact_id',name='uq_contact_profile'),)
    id:Mapped[str]=mapped_column(String(36),primary_key=True);owner_id:Mapped[str]=mapped_column(ForeignKey('users.id'),index=True);contact_id:Mapped[str]=mapped_column(ForeignKey('users.id'),index=True);remark:Mapped[str|None]=mapped_column(String(128));tags:Mapped[str]=mapped_column(Text,default='');moments_permission:Mapped[str]=mapped_column(String(30),default='DEFAULT')
class UserBlock(Base):
    __tablename__='user_blocks';__table_args__=(UniqueConstraint('blocker_id','blocked_id',name='uq_user_block'),)
    id:Mapped[str]=mapped_column(String(36),primary_key=True);blocker_id:Mapped[str]=mapped_column(ForeignKey('users.id'),index=True);blocked_id:Mapped[str]=mapped_column(ForeignKey('users.id'),index=True);idempotency_key:Mapped[str]=mapped_column(String(128));created_at:Mapped[datetime]=mapped_column(DateTime(timezone=True))
class ContactTag(Base):
    __tablename__='contact_tags';__table_args__=(UniqueConstraint('owner_id','name',name='uq_contact_tag_owner_name'),)
    id:Mapped[str]=mapped_column(String(36),primary_key=True);owner_id:Mapped[str]=mapped_column(ForeignKey('users.id'),index=True);name:Mapped[str]=mapped_column(String(64));created_at:Mapped[datetime]=mapped_column(DateTime(timezone=True))
