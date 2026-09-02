import hashlib
import json
from datetime import datetime, timedelta, timezone
from uuid import uuid4

from sqlalchemy import select

from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.admin.models import AdminBan, AdminCommand, OfficialNotice, NoticeReceipt, NativeAdCampaign
from app.modules.audit.writer import AuditWriter
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import User, UserRole
from app.modules.moments.models import NativeMomentAd


class AdminControlService:
    def __init__(self, session_factory, *, now_factory=None):
        self._session_factory = session_factory
        self._now = now_factory or (lambda: datetime.now(timezone.utc))
        self._audit = AuditWriter(session_factory, now_factory=self._now)

    def ban(self, *, actor_id: str, target_type: str, target: str, reason_code: str, duration_minutes: int | None, idempotency_key: str, trace_id: str) -> dict:
        if target_type not in {"user", "ip"} or not target or not reason_code:
            raise AppError(code="ADMIN_COMMAND_INVALID", message="封禁参数无效", status_code=422)
        now = self._now()
        def mutate(session):
            existing = session.scalar(select(AdminBan).where(AdminBan.subject_type == target_type, AdminBan.subject_value == target).with_for_update())
            if existing is None:
                existing = AdminBan(id=str(uuid4()), subject_type=target_type, subject_value=target, reason_code=reason_code, starts_at=now, ends_at=now + timedelta(minutes=duration_minutes) if duration_minutes else None, revoked_at=None, created_by=actor_id, created_at=now)
                session.add(existing)
            else:
                existing.reason_code, existing.starts_at, existing.ends_at, existing.revoked_at, existing.created_by = reason_code, now, now + timedelta(minutes=duration_minutes) if duration_minutes else None, None, actor_id
            if target_type == "user":
                user = session.get(User, target)
                if user is None: raise AppError(code="USER_NOT_FOUND", message="用户不存在", status_code=404)
                user.status = AccountStatus.SUSPENDED
            result = {"id": existing.id, "target_type": target_type, "target": target, "status": "ACTIVE"}
            self._record(session, actor_id, "admin_ban", existing.id, "admin.ban.created", reason_code, trace_id, {"target_type": target_type})
            OutboxPublisher.enqueue(session, topic="admin", event_type="admin.ban.created", aggregate_type="admin_ban", aggregate_id=existing.id, payload={"subject_type": target_type, "subject_id": target})
            return result
        return self._command("admin.ban", idempotency_key, {"target_type":target_type,"target":target,"reason_code":reason_code,"duration_minutes":duration_minutes}, mutate)

    def unban(self, *, actor_id: str, ban_id: str, reason_code: str, idempotency_key: str, trace_id: str) -> dict:
        def mutate(session):
            ban = session.get(AdminBan, ban_id)
            if ban is None: raise AppError(code="BAN_NOT_FOUND", message="封禁记录不存在", status_code=404)
            ban.revoked_at = self._now()
            if ban.subject_type == "user":
                user = session.get(User, ban.subject_value)
                if user is not None and user.status == AccountStatus.SUSPENDED: user.status = AccountStatus.ACTIVE
            result = {"id": ban.id, "status":"REVOKED"}
            self._record(session, actor_id, "admin_ban", ban.id, "admin.ban.revoked", reason_code, trace_id)
            OutboxPublisher.enqueue(session, topic="admin", event_type="admin.ban.revoked", aggregate_type="admin_ban", aggregate_id=ban.id, payload={"subject_type":ban.subject_type,"subject_id":ban.subject_value})
            return result
        return self._command("admin.unban", idempotency_key, {"ban_id":ban_id,"reason_code":reason_code}, mutate)

    def set_support_role(self, *, actor_id: str, user_id: str, role_code: RoleCode, idempotency_key: str, trace_id: str) -> dict:
        if role_code not in {RoleCode.SUPPORT_AGENT, RoleCode.FINANCE_SUPPORT, RoleCode.SUPPORT_SUPERVISOR}:
            raise AppError(code="ADMIN_ROLE_INVALID", message="仅可配置客服角色", status_code=422)
        def mutate(session):
            if session.get(User, user_id) is None: raise AppError(code="USER_NOT_FOUND", message="用户不存在", status_code=404)
            row = session.scalar(select(UserRole).where(UserRole.user_id == user_id, UserRole.role_code == role_code))
            if row is None: session.add(UserRole(id=str(uuid4()), user_id=user_id, role_code=role_code, assigned_by=actor_id, assigned_at=self._now()))
            result={"user_id":user_id,"role_code":role_code.value,"status":"ASSIGNED"}
            self._record(session, actor_id, "user_role", user_id, "admin.support_role.assigned", "SUPPORT_ROLE_ASSIGN", trace_id, {"role_code":role_code.value})
            OutboxPublisher.enqueue(session, topic="admin", event_type="admin.support_role.assigned", aggregate_type="user", aggregate_id=user_id, payload={"role_code":role_code.value})
            return result
        return self._command("admin.support-role", idempotency_key, {"user_id":user_id,"role_code":role_code.value}, mutate)

    def create_notice(self, *, actor_id: str, title: str, content: str, audience: str, publish_at: datetime | None, idempotency_key: str, trace_id: str) -> dict:
        now=self._now()
        def mutate(session):
            row=OfficialNotice(id=str(uuid4()),title=title,content=content,audience=audience,status="SCHEDULED" if publish_at and publish_at>now else "PUBLISHED",publish_at=publish_at,created_by=actor_id,idempotency_key=idempotency_key,created_at=now,updated_at=now); session.add(row)
            result={"id":row.id,"title":row.title,"audience":row.audience,"status":row.status}
            self._record(session, actor_id, "official_notice", row.id, "admin.notice.created", "NOTICE_CREATE", trace_id, {"audience":audience,"status":row.status})
            OutboxPublisher.enqueue(session,topic="notification",event_type="notice.publish.requested",aggregate_type="official_notice",aggregate_id=row.id,payload={"audience":audience,"status":row.status})
            return result
        return self._command("admin.notice",idempotency_key,{"title":title,"content":content,"audience":audience,"publish_at":publish_at.isoformat() if publish_at else None},mutate)

    def update_notice(self, *, actor_id: str, notice_id: str, title: str, content: str, audience: str, publish_at: datetime | None, idempotency_key: str, trace_id: str) -> dict:
        now = self._now()
        def mutate(session):
            row = session.get(OfficialNotice, notice_id)
            if row is None or row.status == "RETRACTED": raise AppError(code="NOTICE_NOT_FOUND", message="公告不存在", status_code=404)
            row.title, row.content, row.audience, row.publish_at, row.updated_at = title, content, audience, publish_at, now
            row.status = "SCHEDULED" if publish_at and publish_at > now else "PUBLISHED"
            result = {"id":row.id,"title":row.title,"audience":row.audience,"status":row.status}
            self._record(session, actor_id, "official_notice", row.id, "admin.notice.updated", "NOTICE_UPDATE", trace_id, {"status":row.status})
            OutboxPublisher.enqueue(session, topic="notification", event_type="notice.publish.requested", aggregate_type="official_notice", aggregate_id=row.id, payload={"audience":row.audience,"status":row.status})
            return result
        return self._command("admin.notice.update", idempotency_key, {"notice_id":notice_id,"title":title,"content":content,"audience":audience,"publish_at":publish_at.isoformat() if publish_at else None}, mutate)

    def retract_notice(self, *, actor_id: str, notice_id: str, reason_code: str, idempotency_key: str, trace_id: str) -> dict:
        def mutate(session):
            row=session.get(OfficialNotice,notice_id)
            if row is None: raise AppError(code="NOTICE_NOT_FOUND",message="公告不存在",status_code=404)
            row.status, row.updated_at = "RETRACTED", self._now()
            result={"id":row.id,"status":row.status}
            self._record(session,actor_id,"official_notice",row.id,"admin.notice.retracted",reason_code,trace_id,{"status":"RETRACTED"})
            OutboxPublisher.enqueue(session,topic="notification",event_type="notice.retracted",aggregate_type="official_notice",aggregate_id=row.id,payload={})
            return result
        return self._command("admin.notice.retract",idempotency_key,{"notice_id":notice_id,"reason_code":reason_code},mutate)

    def record_notice_read(self, *, user_id: str, notice_id: str, idempotency_key: str) -> dict:
        with self._session_factory.begin() as session:
            notice=session.get(OfficialNotice,notice_id)
            if notice is None or notice.status != "PUBLISHED": raise AppError(code="NOTICE_NOT_FOUND",message="公告不存在",status_code=404)
            row=session.scalar(select(NoticeReceipt).where(NoticeReceipt.notice_id==notice_id,NoticeReceipt.user_id==user_id))
            if row is None:
                row=NoticeReceipt(id=str(uuid4()),notice_id=notice_id,user_id=user_id,read_at=self._now(),idempotency_key=idempotency_key);session.add(row)
            read_at = row.read_at if row.read_at.tzinfo else row.read_at.replace(tzinfo=timezone.utc)
            return {"notice_id":notice_id,"read_at":read_at.isoformat()}

    def create_ad(self, *, actor_id: str, advertiser_name: str, text: str, link_url: str, idempotency_key: str, trace_id: str) -> dict:
        now=self._now()
        def mutate(session):
            row=NativeMomentAd(id=str(uuid4()),advertiser_name=advertiser_name,avatar_url=None,text=text,image_urls=[],link_url=link_url,status="DRAFT",created_at=now);session.add(row)
            result={"id":row.id,"advertiser_name":row.advertiser_name,"status":row.status}
            self._record(session,actor_id,"native_moment_ad",row.id,"admin.ad.created","AD_CREATE",trace_id,{"status":row.status})
            OutboxPublisher.enqueue(session,topic="moments",event_type="native_ad.created",aggregate_type="native_moment_ad",aggregate_id=row.id,payload={"status":row.status})
            return result
        return self._command("admin.ad",idempotency_key,{"advertiser_name":advertiser_name,"text":text,"link_url":link_url},mutate)

    def schedule_ad(self, *, actor_id: str, ad_id: str, starts_at: datetime, ends_at: datetime, audience: dict, idempotency_key: str, trace_id: str) -> dict:
        if starts_at >= ends_at: raise AppError(code="AD_SCHEDULE_INVALID", message="投放结束时间必须晚于开始时间", status_code=422)
        now=self._now()
        def mutate(session):
            ad=session.get(NativeMomentAd,ad_id)
            if ad is None: raise AppError(code="AD_NOT_FOUND",message="广告不存在",status_code=404)
            campaign=session.scalar(select(NativeAdCampaign).where(NativeAdCampaign.ad_id==ad_id).with_for_update())
            if campaign is None:
                campaign=NativeAdCampaign(id=str(uuid4()),ad_id=ad_id,starts_at=starts_at,ends_at=ends_at,audience=audience,status="SCHEDULED" if starts_at>now else "ACTIVE",created_by=actor_id,created_at=now);session.add(campaign)
            else:
                campaign.starts_at,campaign.ends_at,campaign.audience,campaign.status=starts_at,ends_at,audience,"SCHEDULED" if starts_at>now else "ACTIVE"
            ad.status=campaign.status
            result={"id":campaign.id,"ad_id":ad_id,"status":campaign.status,"starts_at":starts_at.isoformat(),"ends_at":ends_at.isoformat(),"audience":audience}
            self._record(session,actor_id,"native_ad_campaign",campaign.id,"admin.ad.scheduled","AD_SCHEDULE",trace_id,{"status":campaign.status})
            OutboxPublisher.enqueue(session,topic="moments",event_type="native_ad.schedule.changed",aggregate_type="native_ad_campaign",aggregate_id=campaign.id,payload={"ad_id":ad_id,"status":campaign.status})
            return result
        return self._command("admin.ad.schedule",idempotency_key,{"ad_id":ad_id,"starts_at":starts_at.isoformat(),"ends_at":ends_at.isoformat(),"audience":audience},mutate)

    def record_ad_event(self, *, ad_id: str, event_type: str) -> dict:
        if event_type not in {"impression", "click"}: raise AppError(code="AD_EVENT_INVALID",message="广告事件无效",status_code=422)
        now=self._now()
        with self._session_factory.begin() as session:
            campaign=session.scalar(select(NativeAdCampaign).where(NativeAdCampaign.ad_id==ad_id).with_for_update())
            if campaign is None or campaign.status not in {"SCHEDULED","ACTIVE"} or campaign.starts_at>now or campaign.ends_at<=now: raise AppError(code="AD_NOT_ACTIVE",message="广告未在投放期",status_code=404)
            campaign.status="ACTIVE"
            if event_type=="impression": campaign.impressions+=1
            else: campaign.clicks+=1
            return {"ad_id":ad_id,"impressions":campaign.impressions,"clicks":campaign.clicks}

    def revoke_support_role(self, *, actor_id: str, user_id: str, role_code: RoleCode, idempotency_key: str, trace_id: str) -> dict:
        def mutate(session):
            row=session.scalar(select(UserRole).where(UserRole.user_id==user_id,UserRole.role_code==role_code))
            if row is not None: session.delete(row)
            result={"user_id":user_id,"role_code":role_code.value,"status":"REVOKED"}
            self._record(session,actor_id,"user_role",user_id,"admin.support_role.revoked","SUPPORT_ROLE_REVOKE",trace_id,{"role_code":role_code.value})
            OutboxPublisher.enqueue(session,topic="admin",event_type="admin.support_role.revoked",aggregate_type="user",aggregate_id=user_id,payload={"role_code":role_code.value})
            return result
        return self._command("admin.support-role.revoke",idempotency_key,{"user_id":user_id,"role_code":role_code.value},mutate)

    def _command(self, scope, key, payload, mutate):
        request_hash=hashlib.sha256(json.dumps(payload,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()
        with self._session_factory.begin() as session:
            command=session.scalar(select(AdminCommand).where(AdminCommand.scope==scope,AdminCommand.idempotency_key==key).with_for_update())
            if command is not None:
                if command.request_hash != request_hash: raise AppError(code="IDEMPOTENCY_KEY_REUSED",message="幂等键与请求不匹配",status_code=409)
                return command.result
            result=mutate(session)
            session.add(AdminCommand(id=str(uuid4()),scope=scope,idempotency_key=key,request_hash=request_hash,result=result,created_at=self._now()))
            return result

    def _record(self, session, actor_id, subject_type, subject_id, action, reason_code, trace_id, after=None):
        self._audit.record_in_session(session,actor_id=actor_id,subject_type=subject_type,subject_id=subject_id,action=action,result="SUCCESS",reason_code=reason_code,trace_id=trace_id,after=after)
