"""Public, read-only CAIBI statement projections."""
import base64
import json
from datetime import datetime, timezone
from decimal import Decimal

from sqlalchemy import and_, func, or_, select

from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.ledger.service import money
from app.modules.transfer.projections import TransferReadProjection


class StatementService:
    def __init__(self, session_factory):
        self.session_factory = session_factory

    @staticmethod
    def kind_for(transaction: LedgerTransaction) -> str:
        if transaction.scope.startswith("redpacket."):
            return "redpacket"
        if transaction.scope in {"caibi.transfer", "chat_transfer.create", "chat_transfer.accept", "chat_transfer.refund"}:
            return "transfer"
        if transaction.scope == "wallet.conversion" and transaction.reason_code == "USDT_TO_CAIBI":
            return "deposit"
        if transaction.scope == "wallet.conversion_reversal" or (transaction.scope == "wallet.conversion" and transaction.reason_code == "CAIBI_TO_USDT"):
            return "withdrawal"
        return "other"

    def list(self, *, user_id: str, kind: str | None = None, start_at: datetime | None = None,
             end_at: datetime | None = None, q: str | None = None, cursor: str | None = None,
             limit: int = 50) -> dict:
        marker = self._decode_cursor(cursor) if cursor else None
        with self.session_factory() as session:
            amount = func.sum(LedgerEntry.amount).label("amount")
            query = (select(LedgerTransaction, amount)
                .join(LedgerEntry, LedgerEntry.transaction_id == LedgerTransaction.id)
                .where(LedgerEntry.account_id == user_id, LedgerEntry.asset == "CAIBI", LedgerTransaction.asset == "CAIBI")
                .group_by(LedgerTransaction.id))
            if start_at:
                query = query.where(LedgerTransaction.created_at >= start_at)
            if end_at:
                query = query.where(LedgerTransaction.created_at < end_at)
            if kind:
                query = self._kind_filter(query, kind)
            if q:
                escaped = q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
                pattern = f"%{escaped}%"
                kind_match = self._kind_from_query(q)
                note_ids = TransferReadProjection.matching_transaction_ids(session, pattern)
                terms = [LedgerTransaction.id.ilike(pattern, escape="\\"), LedgerTransaction.reason_code.ilike(pattern, escape="\\"), LedgerTransaction.scope.ilike(pattern, escape="\\"), LedgerTransaction.id.in_(note_ids)]
                if kind_match:
                    terms.append(self._kind_clause(kind_match))
                query = query.where(or_(*terms))
            if marker:
                query = query.where(or_(LedgerTransaction.created_at < marker[0], and_(LedgerTransaction.created_at == marker[0], LedgerTransaction.id < marker[1])))
            rows = session.execute(query.order_by(LedgerTransaction.created_at.desc(), LedgerTransaction.id.desc()).limit(limit + 1)).all()
            items = self._project_rows(session, rows[:limit])
        next_cursor = self._encode_cursor(rows[limit - 1][0]) if len(rows) > limit else None
        return {"items": items, "next_cursor": next_cursor}

    def get(self, *, user_id: str, transaction_id: str) -> dict | None:
        with self.session_factory() as session:
            amount = func.sum(LedgerEntry.amount).label("amount")
            row = session.execute(select(LedgerTransaction, amount).join(LedgerEntry).where(
                LedgerTransaction.id == transaction_id, LedgerTransaction.asset == "CAIBI",
                LedgerEntry.account_id == user_id, LedgerEntry.asset == "CAIBI").group_by(LedgerTransaction.id)).first()
            return self._project_rows(session, [row])[0] if row else None

    def _project_rows(self, session, rows):
        tx_ids = [transaction.id for transaction, _amount in rows]
        transfer_for_tx = TransferReadProjection.for_transactions(session, tx_ids)
        return [self._project(transaction, amount, transfer_for_tx.get(transaction.id)) for transaction, amount in rows]

    def _project(self, transaction, amount, transfer):
        return {"id": transaction.id, "asset": "CAIBI", "amount": f"{money(Decimal(amount)):.2f}",
            "kind": self.kind_for(transaction), "reason_code": transaction.reason_code,
            "created_at": self._utc(transaction.created_at), "reversal_of_id": transaction.reversal_of_id,
            "status": transfer.status if transfer else None,
            "note": transfer.note if transfer else None, "business_id": transfer.id if transfer else None,
            "transfer_amount": f"{money(transfer.amount):.2f}" if transfer else None,
            "fee": f"{money(transfer.fee):.2f}" if transfer else None,
            "accepted_at": self._utc(transfer.updated_at) if transfer and transfer.status == "ACCEPTED" else None,
            "transfer_created_at": self._utc(transfer.created_at) if transfer else None}

    @staticmethod
    def _kind_filter(query, kind):
        return query.where(StatementService._kind_clause(kind))

    @staticmethod
    def _kind_clause(kind):
        if kind == "redpacket": return LedgerTransaction.scope.like("redpacket.%")
        if kind == "transfer": return LedgerTransaction.scope.in_(("caibi.transfer", "chat_transfer.create", "chat_transfer.accept", "chat_transfer.refund"))
        if kind == "deposit": return and_(LedgerTransaction.scope == "wallet.conversion", LedgerTransaction.reason_code == "USDT_TO_CAIBI")
        if kind == "withdrawal": return or_(LedgerTransaction.scope == "wallet.conversion_reversal", and_(LedgerTransaction.scope == "wallet.conversion", LedgerTransaction.reason_code == "CAIBI_TO_USDT"))
        known = or_(
            LedgerTransaction.scope.like("redpacket.%"),
            LedgerTransaction.scope.in_(("caibi.transfer", "chat_transfer.create", "chat_transfer.accept", "chat_transfer.refund")),
            and_(LedgerTransaction.scope == "wallet.conversion", LedgerTransaction.reason_code.in_(("USDT_TO_CAIBI", "CAIBI_TO_USDT"))),
            LedgerTransaction.scope == "wallet.conversion_reversal",
        )
        return ~known

    @staticmethod
    def _encode_cursor(tx):
        created = tx.created_at.replace(tzinfo=timezone.utc) if tx.created_at.tzinfo is None else tx.created_at.astimezone(timezone.utc)
        raw = json.dumps([created.isoformat(), tx.id]).encode()
        return base64.urlsafe_b64encode(raw).decode()

    @staticmethod
    def _decode_cursor(value):
        try:
            date, tx_id = json.loads(base64.urlsafe_b64decode(value.encode()))
            parsed = datetime.fromisoformat(date)
            if not isinstance(tx_id, str) or not 1 <= len(tx_id) <= 36 or parsed.tzinfo is None:
                raise ValueError("invalid statement cursor")
            return parsed, tx_id
        except Exception as error:
            raise ValueError("invalid statement cursor") from error

    @staticmethod
    def _utc(value):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)

    @staticmethod
    def _kind_from_query(value):
        return {"红包": "redpacket", "redpacket": "redpacket", "转账": "transfer", "transfer": "transfer",
                "提现": "withdrawal", "withdrawal": "withdrawal", "充值": "deposit", "deposit": "deposit",
                "其他": "other", "other": "other"}.get(value.casefold())
