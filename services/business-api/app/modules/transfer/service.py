from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from uuid import uuid4

from sqlalchemy import select

from app.modules.ledger.service import CENT, LedgerService, money
from app.modules.transfer.models import ChatTransfer

TRANSFER_FEE_RATE = Decimal("0.005")


def transfer_fee(amount: Decimal) -> Decimal:
    return max(CENT, money(amount * TRANSFER_FEE_RATE))


class ChatTransferService:
    def __init__(self, session_factory, ledger: LedgerService):
        self.session_factory = session_factory
        self.ledger = ledger

    def create(self, *, sender_id: str, receiver_id: str, amount: Decimal, idempotency_key: str, expires_at: datetime, note: str | None = None, room_id: str | None = None) -> ChatTransfer:
        amount = money(amount)
        if amount <= 0 or sender_id == receiver_id or not receiver_id:
            raise ValueError("invalid transfer")
        note = (note or "").strip() or None
        if note and len(note) > 64:
            raise ValueError("transfer note too long")
        transfer_id = str(uuid4())
        fee = transfer_fee(amount)
        escrow = f"PLATFORM_TRANSFER_ESCROW:{transfer_id}"
        now = datetime.now(timezone.utc)
        # F01：幂等检查、账本（扣款+手续费+入托管）、业务单据在同一
        # 事务提交——记账后、单据插入前崩溃即整体回滚。
        with self.session_factory.begin() as session:
            existing = session.scalar(select(ChatTransfer).where(ChatTransfer.sender_id == sender_id, ChatTransfer.idempotency_key == idempotency_key))
            if existing:
                if existing.amount != amount or existing.receiver_id != receiver_id or (existing.note or None) != note:
                    raise ValueError("idempotency key reused with different payload")
                return existing
            self.ledger.post(
                entries={sender_id: -(amount + fee), escrow: amount, "PLATFORM_FEE": fee},
                actor_id=sender_id,
                reason_code="CHAT_TRANSFER_CREATE",
                idempotency_key=idempotency_key,
                scope="chat_transfer.create",
                session=session,
            )
            transfer = ChatTransfer(id=transfer_id, sender_id=sender_id, receiver_id=receiver_id, amount=amount, fee=fee, note=note, room_id=room_id, status="PENDING", idempotency_key=idempotency_key, expires_at=expires_at, created_at=now, updated_at=now)
            session.add(transfer)
            session.flush()
            return transfer

    def detail(self, transfer_id: str, *, user_id: str) -> dict:
        with self.session_factory() as session:
            transfer = session.scalar(select(ChatTransfer).where(ChatTransfer.id == transfer_id))
            if not transfer:
                raise ValueError("transfer not found")
            if user_id not in (transfer.sender_id, transfer.receiver_id):
                raise ValueError("transfer is not visible to this user")
            return self.snapshot(transfer)

    def accept(self, transfer_id: str, *, user_id: str, idempotency_key: str) -> ChatTransfer:
        with self.session_factory.begin() as session:
            transfer = session.scalar(select(ChatTransfer).where(ChatTransfer.id == transfer_id).with_for_update())
            self._ensure_pending(transfer, user_id=user_id, require_recipient=True)
            escrow = f"PLATFORM_TRANSFER_ESCROW:{transfer.id}"
            self.ledger.post(entries={escrow: -transfer.amount, user_id: transfer.amount}, actor_id=user_id, reason_code="CHAT_TRANSFER_ACCEPT", idempotency_key=idempotency_key, scope="chat_transfer.accept", session=session)
            transfer.status = "ACCEPTED"
            transfer.updated_at = datetime.now(timezone.utc)
            session.flush()
            return transfer

    def decline(self, transfer_id: str, *, user_id: str, reason_code: str, idempotency_key: str) -> ChatTransfer:
        with self.session_factory.begin() as session:
            transfer = session.scalar(select(ChatTransfer).where(ChatTransfer.id == transfer_id).with_for_update())
            self._ensure_pending(transfer, user_id=user_id, require_recipient=True)
            self._refund(transfer, actor_id=user_id, reason_code=reason_code, idempotency_key=idempotency_key, session=session)
            transfer.status = "DECLINED"
            transfer.updated_at = datetime.now(timezone.utc)
            session.flush()
            return transfer

    def expire(self, transfer_id: str, *, now: datetime, actor_id: str, idempotency_key: str) -> ChatTransfer:
        with self.session_factory.begin() as session:
            transfer = session.scalar(select(ChatTransfer).where(ChatTransfer.id == transfer_id).with_for_update())
            if not transfer:
                raise ValueError("transfer not found")
            if transfer.status != "PENDING":
                return transfer
            if self._aware(transfer.expires_at) > now:
                raise ValueError("transfer has not expired")
            self._refund(transfer, actor_id=actor_id, reason_code="CHAT_TRANSFER_EXPIRED", idempotency_key=idempotency_key, session=session)
            transfer.status = "EXPIRED"
            transfer.updated_at = now
            session.flush()
            return transfer

    def list_expired(self, *, now: datetime, limit: int = 100) -> list[str]:
        with self.session_factory() as session:
            return list(session.scalars(select(ChatTransfer.id).where(ChatTransfer.status == "PENDING", ChatTransfer.expires_at <= now).limit(limit)))

    def _ensure_pending(self, transfer: ChatTransfer | None, *, user_id: str, require_recipient: bool) -> ChatTransfer:
        if not transfer:
            raise ValueError("transfer not found")
        if transfer.status != "PENDING":
            raise ValueError("transfer unavailable")
        if self._aware(transfer.expires_at) <= datetime.now(timezone.utc):
            raise ValueError("transfer expired")
        if require_recipient and transfer.receiver_id != user_id:
            raise ValueError("only the recipient can operate this transfer")
        return transfer

    def _refund(self, transfer: ChatTransfer, *, actor_id: str, reason_code: str, idempotency_key: str, session=None) -> None:
        """F01：本金与手续费在**一次**平衡分录内完成退款，且与业务状态
        变更同一事务（session 由 decline/expire 注入）。

        旧实现拆成两笔独立记账（本金 `key`、手续费 `key:fee`）且各自
        提交——中间崩溃会留下半退款。合并后单事务原子完成。
        """
        escrow = f"PLATFORM_TRANSFER_ESCROW:{transfer.id}"
        self.ledger.post(
            entries={escrow: -transfer.amount, "PLATFORM_FEE": -transfer.fee, transfer.sender_id: transfer.amount + transfer.fee},
            actor_id=actor_id,
            reason_code=reason_code,
            idempotency_key=idempotency_key,
            scope="chat_transfer.refund",
            session=session,
        )

    def snapshot(self, transfer: ChatTransfer) -> dict:
        return {
            "id": transfer.id,
            "sender_id": transfer.sender_id,
            "receiver_id": transfer.receiver_id,
            "asset": "CAIBI",
            "amount": str(transfer.amount),
            "fee": str(transfer.fee),
            "note": transfer.note,
            "room_id": transfer.room_id,
            "status": transfer.status,
            "expires_at": transfer.expires_at,
            "created_at": transfer.created_at,
        }

    @staticmethod
    def _aware(value: datetime) -> datetime:
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
