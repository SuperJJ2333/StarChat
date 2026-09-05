from datetime import datetime, timezone
from decimal import Decimal
import secrets
from uuid import uuid4

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import selectinload

from app.modules.ledger.service import LedgerService, money
from app.modules.redpacket.models import RedPacket, RedPacketShare
from app.modules.redpacket.claims import RedPacketClaim

class RedPacketService:
    def __init__(self, session_factory, ledger: LedgerService, *, max_total: Decimal | str = "20000.00", profiles=None, room_membership=None):
        self.session_factory = session_factory
        self.ledger = ledger
        self.max_total = money(max_total)
        # 可选的公开资料服务（ProfileService）：为领取详情补充
        # 领取人/发送人的用户名、昵称与自定义头像。
        self.profiles = profiles
        # F06：房间成员授权权威（Matrix join 成员，业务库不复制成员
        # 关系）。None = 未配置（worker 过期退款等非用户请求路径），
        # 此时群红包的成员校验退化为仅允许发起人本人。
        self.room_membership = room_membership

    def create_equal(self, **kwargs) -> RedPacket:
        total, count = self._validate(kwargs["total"], kwargs["share_count"])
        cents = int(total * 100)
        base, remainder = divmod(cents, count)
        amounts = [Decimal(base + (1 if i < remainder else 0)) / 100 for i in range(count)]
        return self._create(mode="EQUAL", amounts=amounts, total=total, **{k:v for k,v in kwargs.items() if k not in ("total", "share_count")})

    def create_exclusive(self, **kwargs) -> RedPacket:
        total, count = self._validate(kwargs["total"], kwargs.get("share_count", 1))
        if count != 1:
            raise ValueError("exclusive red packet must contain exactly one share")
        return self._create(mode="EXCLUSIVE", amounts=[total], total=total, **{k:v for k,v in kwargs.items() if k not in ("total", "share_count")})

    def detail(self, packet_id: str, *, user_id: str) -> dict:
        with self.session_factory() as session:
            packet = session.scalar(select(RedPacket).options(selectinload(RedPacket.shares)).where(RedPacket.id == packet_id))
            if not packet:
                raise ValueError("red packet not found")
            if packet.recipient_id and user_id not in (packet.sender_id, packet.recipient_id):
                raise ValueError("recipient mismatch")
            # F06：普通群红包——发起人本人或当前房间成员才可见；
            # 退群/被踢后不可见。
            self._authorize_room_access(packet, user_id=user_id)
            claims = [
                {"user_id": share.claimed_by, "amount": str(share.amount), "claimed_at": share.claimed_at}
                for share in packet.shares if share.claimed_by is not None
            ]
            payload = {
                "id": packet.id, "sender_id": packet.sender_id, "mode": packet.mode,
                "asset": "CAIBI", "total": str(packet.total), "share_count": packet.share_count,
                "claimed_count": len(claims), "status": packet.status, "expires_at": packet.expires_at,
                "claims": claims,
            }
            self._attach_public_profiles(payload, claims, sender_id=packet.sender_id)
            return payload

    def _attach_public_profiles(self, payload: dict, claims: list[dict], *, sender_id: str | None) -> None:
        """补充用户名/昵称/头像（公开资料），失败时静默降级为基础详情。"""
        if self.profiles is None:
            return
        user_ids = {claim["user_id"] for claim in claims}
        if sender_id:
            user_ids.add(sender_id)
        user_ids.discard(None)
        if not user_ids:
            return
        try:
            profiles = self.profiles.read_public_profiles(list(user_ids))
        except Exception:
            return
        for claim in claims:
            profile = profiles.get(claim["user_id"])
            if profile is not None:
                claim["nickname"] = profile.nickname
                claim["username"] = profile.username
                claim["avatar_url"] = profile.avatar_url
        sender = profiles.get(sender_id) if sender_id else None
        if sender is not None:
            payload["sender_nickname"] = sender.nickname
            payload["sender_username"] = sender.username
            payload["sender_avatar_url"] = sender.avatar_url

    def create_random(self, **kwargs) -> RedPacket:
        total, count = self._validate(kwargs["total"], kwargs["share_count"])
        remaining = int(total * 100)
        amounts = []
        for index in range(count - 1):
            shares_left = count - index
            maximum = remaining - (shares_left - 1)
            cap = max(1, min(maximum, (remaining // shares_left) * 2))
            value = secrets.randbelow(cap) + 1
            amounts.append(Decimal(value) / 100)
            remaining -= value
        amounts.append(Decimal(remaining) / 100)
        secrets.SystemRandom().shuffle(amounts)
        return self._create(mode="RANDOM", amounts=amounts, total=total, **{k:v for k,v in kwargs.items() if k not in ("total", "share_count")})

    def _validate(self, total, count):
        total = money(total)
        if count < 1 or total < Decimal(count) * Decimal("0.01"):
            raise ValueError("invalid red packet total or share count")
        if total > self.max_total:
            raise ValueError("RED_PACKET_LIMIT_EXCEEDED")
        return total, count

    def _create(self, *, sender_id, total, amounts, mode, idempotency_key, expires_at, room_id=None, recipient_id=None):
        if mode == "EXCLUSIVE":
            if not room_id or not recipient_id:
                raise ValueError("exclusive red packet requires room and recipient")
        elif bool(room_id) == bool(recipient_id):
            raise ValueError("exactly one destination is required")
        now = datetime.now(timezone.utc)
        packet_id = str(uuid4())
        escrow = f"PLATFORM_REDPACKET_ESCROW:{packet_id}"
        # F01：幂等检查、账本扣款/入托管、业务单据在同一事务提交——
        # 记账后、单据插入前崩溃即整体回滚，不再留下"钱进了托管但没有
        # 红包"的中间态。并发同键：账本与单据唯一约束互证，败者回滚后
        # 由幂等路径返回同一单据。
        with self.session_factory.begin() as session:
            existing = session.scalar(select(RedPacket).options(selectinload(RedPacket.shares)).where(RedPacket.sender_id == sender_id, RedPacket.idempotency_key == idempotency_key))
            if existing:
                if existing.total != total or existing.mode != mode or existing.room_id != room_id or existing.recipient_id != recipient_id:
                    raise ValueError("idempotency key reused with different payload")
                return existing
            self.ledger.post(entries={sender_id: -total, escrow: total}, actor_id=sender_id, reason_code="RED_PACKET_CREATE", idempotency_key=idempotency_key, scope="redpacket.create", session=session)
            packet = RedPacket(id=packet_id, sender_id=sender_id, total=total, share_count=len(amounts), mode=mode, status="OPEN", room_id=room_id, recipient_id=recipient_id, idempotency_key=idempotency_key, expires_at=expires_at, created_at=now)
            packet.shares = [RedPacketShare(id=str(uuid4()), ordinal=i, amount=money(amount)) for i, amount in enumerate(amounts)]
            session.add(packet)
            session.flush()
            return packet

    def claim(self, packet_id: str, *, user_id: str, idempotency_key: str) -> RedPacketShare:
        now = datetime.now(timezone.utc)
        with self.session_factory.begin() as session:
            packet = session.scalar(select(RedPacket).where(RedPacket.id == packet_id).with_for_update())
            if not packet or packet.status != "OPEN" or self._aware(packet.expires_at) <= now:
                raise ValueError("red packet unavailable")
            if packet.recipient_id and packet.recipient_id != user_id:
                raise ValueError("recipient mismatch")
            # F06：普通群红包——发起人本人或当前房间成员才可领取；
            # 退群/被踢后不可领取（授权失败在写任何领取记录/账本分录
            # 之前完成）。
            self._authorize_room_access(packet, user_id=user_id)
            existing_claim = session.scalar(select(RedPacketClaim).where(RedPacketClaim.packet_id == packet_id, RedPacketClaim.user_id == user_id))
            if existing_claim:
                if existing_claim.idempotency_key == idempotency_key:
                    return session.get(RedPacketShare, existing_claim.share_id)
                raise ValueError("user already claimed")
            share = session.scalar(select(RedPacketShare).where(RedPacketShare.packet_id == packet_id, RedPacketShare.claimed_by.is_(None)).order_by(RedPacketShare.ordinal).limit(1).with_for_update(skip_locked=True))
            if not share:
                raise ValueError("red packet exhausted")
            session.add(RedPacketClaim(id=str(uuid4()), packet_id=packet_id, share_id=share.id, user_id=user_id, idempotency_key=idempotency_key, created_at=now))
            session.flush()
            escrow = f"PLATFORM_REDPACKET_ESCROW:{packet_id}"
            self.ledger.post(entries={escrow: -share.amount, user_id: share.amount}, actor_id=user_id, reason_code="RED_PACKET_CLAIM", idempotency_key=idempotency_key, scope="redpacket.claim", session=session)
            share.claimed_by, share.claimed_at = user_id, now
            if session.scalar(select(RedPacketShare.id).where(RedPacketShare.packet_id == packet_id, RedPacketShare.claimed_by.is_(None), RedPacketShare.id != share.id).limit(1)) is None:
                packet.status = "COMPLETED"
            session.flush()
            return share

    def expire(self, packet_id: str, *, now: datetime, actor_id: str, idempotency_key: str):
        return self._refund(packet_id, now=now, actor_id=actor_id, reason_code="RED_PACKET_EXPIRED", idempotency_key=idempotency_key, final_status="EXPIRED", require_expired=True)

    def cancel_unclaimed(self, packet_id: str, *, actor_id: str, reason_code: str, idempotency_key: str):
        return self._refund(packet_id, now=datetime.now(timezone.utc), actor_id=actor_id, reason_code=reason_code, idempotency_key=idempotency_key, final_status="CANCELLED", require_expired=False)

    def _refund(self, packet_id, *, now, actor_id, reason_code, idempotency_key, final_status, require_expired):
        with self.session_factory.begin() as session:
            packet = session.scalar(select(RedPacket).where(RedPacket.id == packet_id).with_for_update())
            if not packet:
                raise ValueError("red packet not found")
            if packet.status in ("EXPIRED", "CANCELLED", "COMPLETED"):
                return packet
            if require_expired and self._aware(packet.expires_at) > now:
                raise ValueError("red packet has not expired")
            unclaimed = session.scalars(select(RedPacketShare).where(RedPacketShare.packet_id == packet_id, RedPacketShare.claimed_by.is_(None))).all()
            refund = money(sum((share.amount for share in unclaimed), Decimal("0.00")))
            if refund:
                escrow = f"PLATFORM_REDPACKET_ESCROW:{packet_id}"
                # F01：退款分录与终态变更同一事务（session 注入，不再
                # 各自独立提交）。
                self.ledger.post(entries={escrow: -refund, packet.sender_id: refund}, actor_id=actor_id, reason_code=reason_code, idempotency_key=idempotency_key, scope="redpacket.refund", session=session)
            packet.status = final_status
            session.flush()
            return packet

    def _authorize_room_access(self, packet: RedPacket, *, user_id: str) -> None:
        """F06：群红包房间成员授权。

        - 专属红包（有 recipient_id）：既有 recipient 判定已覆盖，跳过；
        - 发起人本人：可见/可领自己的红包；
        - 其他人：必须通过权威成员检查（Matrix 当前 join 成员）；
        - 退群/被踢成员：不再是 join 成员 → 拒绝；
        - 权威不可配置/不可达：fail closed（无法证明成员身份即拒绝）。
        """
        if packet.recipient_id or not packet.room_id:
            return
        if user_id == packet.sender_id:
            return
        authority = self.room_membership
        if authority is None or not authority.is_member(packet.room_id, user_id):
            raise ValueError("room membership required")

    @staticmethod
    def _aware(value):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


