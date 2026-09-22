from datetime import datetime, timezone
from decimal import Decimal
import secrets
from uuid import uuid4

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import selectinload

from app.modules.ledger.service import CENT, LedgerService, money
from app.modules.redpacket.models import RedPacket, RedPacketShare
from app.modules.redpacket.claims import RedPacketClaim
from app.modules.identity.payment_pin import PaymentPinService

# ADR-0073：红包手续费与转账同费率、同取整、同下限（0.5%，最低 0.01 点钻）。
RED_PACKET_FEE_RATE = Decimal("0.005")
# ADR-0078：群主抽成 0.1%（本金两位 HALF_UP，无最低，不超过最终保留手续费）；
# 满 OWNER_FEE_EXEMPT_MIN_MEMBERS 名 joined 成员时群主本群发送免手续费。
GROUP_OWNER_COMMISSION_RATE = Decimal("0.001")
OWNER_FEE_EXEMPT_MIN_MEMBERS = 10
COMMISSION_RULES_VERSION = "rp-fee-v2"


def red_packet_fee(total: Decimal) -> Decimal:
    return max(CENT, money(total * RED_PACKET_FEE_RATE))


def owner_commission(total: Decimal, retained_fee: Decimal) -> Decimal:
    """本金×0.001 两位 HALF_UP；不设最低、舍入 0 不补 0.01；上限=保留手续费。"""
    raw = money(total * GROUP_OWNER_COMMISSION_RATE)
    return min(raw, money(retained_fee))


class RedPacketService:
    def __init__(self, session_factory, ledger: LedgerService, *, max_total: Decimal | str = "20000.00", profiles=None, room_membership=None, payment_pin=None, group_registry=None, owner_commission_enabled=True):
        self.session_factory = session_factory
        self.ledger = ledger
        self.payment_pin = payment_pin or PaymentPinService(session_factory)
        self.max_total = money(max_total)
        # 可选的公开资料服务（ProfileService）：为领取详情补充
        # 领取人/发送人的用户名、昵称与自定义头像。
        self.profiles = profiles
        # F06：房间成员授权权威（Matrix join 成员，业务库不复制成员
        # 关系）。None = 未配置（worker 过期退款等非用户请求路径），
        # 此时群红包的成员校验退化为仅允许发起人本人。
        self.room_membership = room_membership
        # ADR-0078：业务群注册表（群主/免手续费权威）。None = 未接线
        # （仅测试/worker 路径）：此时不做免手续费判定（费用照收），
        # 群红包不产生抽成快照（commission_status=NONE）——生产 main.py
        # 始终接线，绝不允许客户端自行决定免手续费或群主身份。
        self.group_registry = group_registry
        self.owner_commission_enabled = owner_commission_enabled

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
            server_time = datetime.now(timezone.utc)
            viewer_claim = next((claim for claim in claims if claim["user_id"] == user_id), None)
            # 总点钻可见性：发起方始终可见；其他成员仅在红包已领完
            # （COMPLETED）或已过期（EXPIRED / expires_at 已过）后可见——
            # 此时总额已由全部领取记录公开，进行中一律隐藏（None）。
            total_visible = (
                packet.sender_id == user_id
                or packet.status in ("COMPLETED", "EXPIRED")
                or (
                    packet.status == "OPEN"
                    and self._aware(packet.expires_at) <= server_time
                )
            )
            best_luck_eligible = (
                packet.room_id is not None
                and packet.mode == "RANDOM"
                and (
                    packet.status == "COMPLETED"
                    or (packet.status != "CANCELLED" and self._aware(packet.expires_at) <= server_time)
                )
            )
            payload = {
                "id": packet.id, "sender_id": packet.sender_id, "mode": packet.mode,
                "asset": "CAIBI",
                # 红包总额：发起方或红包已终结（领完/过期）时可见，
                # 其余情况为 null，前端不得渲染金额。
                "total": str(packet.total) if total_visible else None,
                # ADR-0073：手续费是发起方的成本，只对发起方可见（其他成员
                # 既不需要也不应看到发起方实付金额）。
                "fee": str(packet.fee or Decimal("0.00"))
                if packet.sender_id == user_id
                else None,
                # ADR-0078：发起方可见免手续费原因与抽成状态（待结算不
                # 增加可花余额；客户端只展示服务端口径）。
                "fee_exempt": bool(packet.fee_exempt) if packet.sender_id == user_id else None,
                "fee_exempt_reason": packet.fee_exempt_reason if packet.sender_id == user_id else None,
                "commission_status": packet.commission_status if packet.sender_id == user_id else None,
                "commission_amount": str(packet.commission_amount) if packet.sender_id == user_id and packet.commission_amount is not None else None,
                "share_count": packet.share_count,
                "claimed_count": len(claims), "status": packet.status, "expires_at": packet.expires_at,
                "room_id": packet.room_id, "server_time": server_time.isoformat(),
                "viewer_claim": viewer_claim, "best_luck_eligible": best_luck_eligible,
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

    def _create(self, *, sender_id, total, amounts, mode, idempotency_key, expires_at, room_id=None, recipient_id=None, payment_claims=None, payment_authorization=None):
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
            self.payment_pin.lock_account(session, sender_id)
            existing = session.scalar(select(RedPacket).options(selectinload(RedPacket.shares)).where(RedPacket.sender_id == sender_id, RedPacket.idempotency_key == idempotency_key))
            self.payment_pin.consume(session, user_id=sender_id, claims=payment_claims, action="red_packet.create",
                payload=dict(mode=mode, total=total, share_count=len(amounts), room_id=room_id, recipient_id=recipient_id),
                idempotency_key=idempotency_key, authorization=payment_authorization, existing=existing is not None)
            if existing:
                if existing.total != total or existing.mode != mode or existing.room_id != room_id or existing.recipient_id != recipient_id or existing.share_count != len(amounts):
                    raise ValueError("idempotency key reused with different payload")
                return existing
            # ADR-0078：满 10 人群主本群发送免手续费；否则 ADR-0073 费率。
            # 抽成受益人/费率/成员快照在创建事务内锁定，后续转让不改。
            fee_exempt, fee_exempt_reason, joined_count = False, None, None
            commission_rate, commission_beneficiary = None, None
            if room_id and self.group_registry is not None:
                sender_is_member, joined_count = self._authorize_group_creation(room_id, sender_id, len(amounts))
                owner_user_id = (self.group_registry.owner_for_creation(session, room_id)
                    if hasattr(self.group_registry, "owner_for_creation")
                    else self.group_registry.owner_of(room_id))
                if owner_user_id is None:
                    raise ValueError("room membership required")
                if sender_id == owner_user_id and joined_count >= OWNER_FEE_EXEMPT_MIN_MEMBERS:
                    fee_exempt, fee_exempt_reason = True, "GROUP_OWNER_TEN_PLUS"
                elif self.owner_commission_enabled:
                    commission_rate, commission_beneficiary = GROUP_OWNER_COMMISSION_RATE, owner_user_id
            fee = Decimal("0.00") if fee_exempt else red_packet_fee(total)
            if commission_rate is not None and fee > Decimal("0.00"):
                commission_amount = owner_commission(total, fee)
                commission_status = "PENDING" if commission_amount > Decimal("0.00") else "NONE"
            else:
                commission_amount, commission_status = None, "NONE"
            if room_id and self.group_registry is None:
                self._authorize_group_creation(room_id, sender_id, len(amounts))
            self.ledger.post(entries={sender_id: -(total + fee), escrow: total, "PLATFORM_FEE": fee}, actor_id=sender_id, reason_code="RED_PACKET_CREATE", idempotency_key=idempotency_key, scope="redpacket.create", session=session)
            packet = RedPacket(id=packet_id, sender_id=sender_id, total=total, fee=fee, share_count=len(amounts), mode=mode, status="OPEN", room_id=room_id, recipient_id=recipient_id, idempotency_key=idempotency_key, expires_at=expires_at, created_at=now,
                fee_exempt=fee_exempt, fee_exempt_reason=fee_exempt_reason, group_joined_count=joined_count,
                commission_rate=commission_rate, commission_beneficiary_id=commission_beneficiary,
                commission_status=commission_status, commission_amount=commission_amount,
                rules_version=COMMISSION_RULES_VERSION)
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
                # ADR-0078：全部领取即手续费最终保留——抽成与 COMPLETED
                # 翻转同一事务入账（行锁保证并发完成只结算一次）。
                self._settle_commission(session, packet)
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
            # ADR-0073：红包终结且仍有未领取份额时，未领取本金与该红包手续费
            # 一并退回发送方（与转账到期退款一致）；全部领完（COMPLETED）不退款，
            # 手续费留在 PLATFORM_FEE。
            fee_refund = money(packet.fee or Decimal("0.00"))
            if refund or fee_refund:
                escrow = f"PLATFORM_REDPACKET_ESCROW:{packet_id}"
                entries: dict[str, Decimal] = {}
                if refund:
                    entries[escrow] = -refund
                    entries[packet.sender_id] = refund
                if fee_refund:
                    entries["PLATFORM_FEE"] = -fee_refund
                    entries[packet.sender_id] = entries.get(packet.sender_id, Decimal("0.00")) + fee_refund
                # F01：退款分录与终态变更同一事务（session 注入，不再
                # 各自独立提交）。
                self.ledger.post(entries=entries, actor_id=actor_id, reason_code=reason_code, idempotency_key=idempotency_key, scope="redpacket.refund", session=session, skip_coverage=True)
                # ADR-0078：退还手续费的红包不发抽成（PENDING→FORFEITED）。
                if packet.commission_status == "PENDING":
                    packet.commission_status = "FORFEITED"
            packet.status = final_status
            session.flush()
            return packet

    def _settle_commission(self, session, packet: RedPacket) -> None:
        """群主抽成一次性入账：{PLATFORM_FEE: -c, 群主: +c}，幂等键
        commission:{packet_id}；重复回调/重复任务/并发完成只入账一次。"""
        if packet.commission_status != "PENDING":
            return
        beneficiary = packet.commission_beneficiary_id
        amount = owner_commission(packet.total, packet.fee or Decimal("0.00"))
        if not beneficiary or amount <= Decimal("0.00"):
            packet.commission_status = "NONE"
            return
        self.ledger.post(entries={"PLATFORM_FEE": -amount, beneficiary: amount}, actor_id="redpacket-settlement",
            reason_code="RED_PACKET_COMMISSION", idempotency_key=f"commission:{packet.id}",
            scope="redpacket.commission", session=session, skip_coverage=True)
        packet.commission_amount = amount
        packet.commission_status = "SETTLED"

    def settle_pending_commissions(self, *, limit: int = 100, actor_id: str = "business-worker") -> int:
        """worker 兜底：PENDING+COMPLETED 的历史遗漏补结算（幂等）。"""
        settled = 0
        with self.session_factory() as session:
            ids = list(session.scalars(select(RedPacket.id).where(
                RedPacket.status == "COMPLETED", RedPacket.commission_status == "PENDING").limit(limit)))
        for packet_id in ids:
            with self.session_factory.begin() as session:
                packet = session.scalar(select(RedPacket).where(RedPacket.id == packet_id).with_for_update())
                if packet is None or packet.status != "COMPLETED" or packet.commission_status != "PENDING":
                    continue
                self._settle_commission(session, packet)
                settled += 1
        return settled

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

    def _authorize_group_creation(self, room_id: str, sender_id: str, share_count: int) -> None:
        authority = self.room_membership
        if authority is None:
            raise ValueError("room membership required")
        sender_is_member, member_count = authority.creation_snapshot(room_id, sender_id)
        if not sender_is_member:
            raise ValueError("room membership required")
        if share_count > member_count:
            raise ValueError("share count exceeds room members")
        return sender_is_member, member_count

    @staticmethod
    def _aware(value):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


