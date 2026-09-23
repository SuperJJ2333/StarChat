"""At-least-once support notifications without a producer timestamp watermark.

Callers must authenticate the management session and authorize FINANCE_REVIEW
before passing its actor ID. This projection grants no financial authority.
Outbox identities are retained independently of delivery/worker status. Each
poll discovers committed events not yet in this actor's inbox; old timestamps
and producers committing out of order therefore cannot fall behind a cursor.
"""
from datetime import timezone
from uuid import uuid4

from sqlalchemy import and_, exists, or_, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert

from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.modules.recharge.notification_models import SupportOrderInbox, SupportOrderSubscription


PAYOUT_EVENTS = (
    'wallet.manual_payout_request', 'wallet.manual_payout_claim',
    'wallet.manual_payout_adjust_rate', 'wallet.manual_payout_cancel',
    'wallet.manual_payout_submit_txid', 'wallet.manual_payout_correct_candidate',
    'wallet.manual_payout_review', 'wallet.manual_payout_settled',
    'wallet.manual_payout_begin_payment', 'wallet.manual_payout_expired',
    'wallet.manual_payout_support_claim', 'wallet.manual_payout_support_review_claim',
    'wallet.support_payout_started',
    'wallet.support_payout_expired',
)


def _invalid():
    raise AppError(code='RECHARGE_CURSOR_INVALID', message='消息游标无效，请重新打开工作台', status_code=400)


class SupportOrderNotifications:
    def __init__(self, session_factory):
        self.factory = session_factory

    def poll(self, *, actor_id: str, cursor: str | None = None, limit: int = 50):
        if not isinstance(actor_id, str) or not actor_id or len(actor_id) > 36:
            raise ValueError('authenticated actor_id is required')
        if not isinstance(limit, int) or isinstance(limit, bool):
            _invalid()
        limit = min(max(limit, 1), 100)
        if cursor is not None and (not isinstance(cursor, str) or len(cursor) != 36):
            _invalid()
        with self.factory.begin() as session:
            dialect = session.get_bind().dialect.name
            # SQLite's database writer lock is only the test/local fallback.
            # PostgreSQL serializes this actor using the subscription row lock.
            if dialect == 'sqlite':
                session.connection().exec_driver_sql('BEGIN IMMEDIATE')
                insert = sqlite_insert
            elif dialect == 'postgresql':
                insert = pg_insert
            else:
                raise RuntimeError('support inbox requires PostgreSQL or SQLite')
            session.execute(insert(SupportOrderSubscription).values(actor_id=actor_id, last_sequence=0)
                            .on_conflict_do_nothing(index_elements=['actor_id']))
            subscription = session.scalar(select(SupportOrderSubscription)
                .where(SupportOrderSubscription.actor_id == actor_id).with_for_update())
            after = 0
            if cursor is not None:
                position = session.scalar(select(SupportOrderInbox).where(
                    SupportOrderInbox.cursor_id == cursor, SupportOrderInbox.actor_id == actor_id))
                if position is None:
                    _invalid()
                after = position.sequence
            rows = list(session.scalars(select(SupportOrderInbox).where(
                SupportOrderInbox.actor_id == actor_id, SupportOrderInbox.sequence > after)
                .order_by(SupportOrderInbox.sequence).limit(limit)))
            if len(rows) < limit:
                known = exists(select(SupportOrderInbox.cursor_id).where(
                    SupportOrderInbox.actor_id == actor_id, SupportOrderInbox.event_id == OutboxEvent.id))
                sources = list(session.scalars(select(OutboxEvent).where(
                    or_(and_(OutboxEvent.topic == 'recharge', OutboxEvent.aggregate_type.in_(
                        ('recharge_request', 'recharge_credit_binding'))),
                        and_(OutboxEvent.topic == 'wallet', OutboxEvent.event_type.in_(PAYOUT_EVENTS))),
                    ~known).order_by(OutboxEvent.created_at, OutboxEvent.id).limit(limit - len(rows))))
                for event in sources:
                    subscription.last_sequence += 1
                    row = SupportOrderInbox(cursor_id=str(uuid4()), actor_id=actor_id,
                        event_id=event.id, sequence=subscription.last_sequence,
                        kind='recharge' if event.topic == 'recharge' else 'payout',
                        order_id=str(event.payload.get('request_id') or event.aggregate_id),
                        event_type=event.event_type, created_at=event.created_at)
                    session.add(row)
                    rows.append(row)
            # Commit of the inbox and its sequence precedes returning any cursor.
            result = {'items': [self._view(row) for row in rows],
                      'next_cursor': rows[-1].cursor_id if rows else cursor}
        return result

    @staticmethod
    def _view(row):
        created = row.created_at
        if created.tzinfo is None:
            created = created.replace(tzinfo=timezone.utc)
        return {'id': row.event_id, 'kind': row.kind, 'order_id': row.order_id,
                'event_type': row.event_type, 'created_at': created.astimezone(timezone.utc).isoformat()}
