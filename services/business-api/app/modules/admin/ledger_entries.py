"""Read-only ledger classification from persisted business associations."""
import base64
import binascii
import hashlib
import json
from datetime import datetime, timezone

from sqlalchemy import and_, case, func, literal, or_, select
from sqlalchemy.orm import aliased

from app.modules.identity.models import User
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.redpacket.models import RedPacket
from app.modules.admin.user_reports import utc_text
from app.modules.audit.models import AuditEvent

REASONS = {
    'RED_PACKET_CREATE': '发出红包', 'RED_PACKET_CLAIM': '领取红包',
    'RED_PACKET_EXPIRED': '红包到期退回', 'CHAT_TRANSFER_CREATE': '发起转账',
    'CHAT_TRANSFER_ACCEPT': '接收转账', 'CHAT_TRANSFER_EXPIRED': '转账到期退回',
    'CHAT_TRANSFER_DECLINED': '转账拒收退回', 'USER_TRANSFER': '用户转账',
    'SUPPORT_CAIBI_GRANT': '客服点钻发放', 'SUPPORT_GRANT': '客服点钻发放',
    'SUPPORT_ADJUSTMENT': '客服点钻调整', 'ADMIN_ADJUSTMENT': '管理员调整',
    'ADJUSTMENT': '点钻调整', 'ADJUSTMENT_REVIEW': '点钻调整审核',
    'INITIAL_ISSUANCE': '初始发行', 'INITIAL_GRANT': '初始发放',
    'ISSUANCE': '点钻发行', 'ISSUE': '点钻发行', 'RECOVERY': '点钻回收',
    'RETURN': '点钻回收', 'REVERSAL': '交易冲正', 'LEDGER_REVERSAL': '账本冲正',
    'CORRECTION': '差错更正', 'CAIBI_ISSUANCE': '点钻发行', 'CAIBI_RECOVERY': '点钻回收',
    'TRANSFER': '用户转账', 'TRANSFER_FEE': '转账手续费',
    'RED_PACKET_SEND': '发送红包', 'RED_PACKET_REFUND': '红包退回',
}
SCENES = ('GROUP', 'EXCLUSIVE', 'DIRECT', 'TRANSFER', 'OTHER', 'UNKNOWN')
MODES = ('RANDOM', 'EQUAL', 'EXCLUSIVE', 'OTHER')


def ledger_page(session, *, filters, limit=50, cursor=None):
    if type(limit) is not int or not 1 <= limit <= 100:
        raise ValueError('invalid ledger limit')
    if set(filters) - {'username', 'nickname', 'email', 'scene', 'mode', 'start_at', 'end_at'}:
        raise ValueError('invalid ledger filters')
    query = {k: v.strip() for k, v in filters.items() if isinstance(v, str) and v.strip()}
    if any(v is not None and not isinstance(v, str) for v in filters.values()) or any(len(v) > 128 for v in query.values()):
        raise ValueError('invalid ledger filter value')
    if query.get('scene', 'OTHER') not in SCENES or query.get('mode', 'OTHER') not in MODES:
        raise ValueError('invalid ledger classification')
    dates = {}
    for key in ('start_at', 'end_at'):
        if key in query:
            dates[key] = datetime.fromisoformat(query[key])
            if dates[key].tzinfo is None:
                raise ValueError('timezone required')
            query[key] = dates[key].astimezone(timezone.utc).isoformat()
    if len(dates) == 2 and dates['start_at'] >= dates['end_at']:
        raise ValueError('reversed date range')
    digest = hashlib.sha256(json.dumps(query, sort_keys=True).encode()).hexdigest()
    cutoff = datetime.now(timezone.utc)
    position = None
    if cursor:
        try:
            if not isinstance(cursor, str) or len(cursor) > 1024:
                raise ValueError('cursor length')
            value = json.loads(base64.b64decode(cursor, altchars=b'-_', validate=True))
            if not isinstance(value, list) or len(value) != 4 or value[3] != digest:
                raise ValueError('cursor filters')
            cutoff, stamp = (datetime.fromisoformat(v) for v in value[:2])
            if cutoff.tzinfo is None or stamp.tzinfo is None or not isinstance(value[2], str) or not 1 <= len(value[2]) <= 36:
                raise ValueError('cursor values')
            position = (stamp, value[2])
        except (ValueError, TypeError, UnicodeError, binascii.Error) as exc:
            raise ValueError('invalid ledger cursor') from exc
    escrow = aliased(LedgerEntry)
    packets = (select(escrow.transaction_id.label('tx'), func.count(func.distinct(RedPacket.id)).label('matches'),
        func.min(RedPacket.mode).label('packet_mode'), func.min(RedPacket.room_id).label('room'),
        func.min(RedPacket.recipient_id).label('recipient'))
        .join(RedPacket, escrow.account_id == literal('PLATFORM_REDPACKET_ESCROW:') + RedPacket.id)
        .group_by(escrow.transaction_id).subquery())
    scene = case(
        (LedgerTransaction.scope.in_(['caibi.transfer', 'chat_transfer.create', 'chat_transfer.accept', 'chat_transfer.refund']), 'TRANSFER'),
        (and_(packets.c.matches == 1, packets.c.packet_mode == 'EXCLUSIVE'), 'EXCLUSIVE'),
        # Historical room_id does not establish a Matrix room's group type.
        (and_(packets.c.matches == 1, packets.c.room.is_not(None), packets.c.recipient.is_(None)), 'UNKNOWN'),
        (and_(packets.c.matches == 1, packets.c.room.is_(None), packets.c.recipient.is_not(None)), 'DIRECT'),
        else_='OTHER')
    mode = case((and_(packets.c.matches == 1, packets.c.packet_mode.in_(MODES)), packets.c.packet_mode), else_='OTHER')
    statement = (select(LedgerEntry.id.label('entry_id'), LedgerEntry.transaction_id,
        LedgerEntry.account_id, LedgerEntry.asset, LedgerEntry.amount, LedgerEntry.created_at,
        LedgerTransaction.reason_code, LedgerTransaction.scope, User.username, User.nickname,
        User.id.label('user_id'), scene.label('scene'), mode.label('mode'), packets.c.matches)
        .join(LedgerTransaction, LedgerTransaction.id == LedgerEntry.transaction_id)
        .outerjoin(User, User.id == LedgerEntry.account_id)
        .outerjoin(packets, packets.c.tx == LedgerEntry.transaction_id))
    conditions = [LedgerEntry.created_at <= cutoff, LedgerEntry.asset == 'CAIBI']
    for key, column in [('username', User.username_normalized), ('nickname', User.nickname), ('email', User.email_normalized)]:
        if key in query:
            escaped = query[key].replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_')
            conditions.append(column.ilike('%' + escaped + '%', escape='\\'))
    for key, column in [('scene', scene), ('mode', mode)]:
        if key in query:
            conditions.append(column == query[key])
    if 'start_at' in dates:
        conditions.append(LedgerEntry.created_at >= dates['start_at'])
    if 'end_at' in dates:
        conditions.append(LedgerEntry.created_at < dates['end_at'])
    statement = statement.where(*conditions)
    total = session.scalar(select(func.count()).select_from(statement.subquery()))
    if position:
        statement = statement.where(or_(LedgerEntry.created_at < position[0], and_(LedgerEntry.created_at == position[0], LedgerEntry.id < position[1])))
    rows = session.execute(statement.order_by(LedgerEntry.created_at.desc(), LedgerEntry.id.desc()).limit(limit + 1)).mappings().all()
    unknown = {row['transaction_id'] for row in rows[:limit] if row['reason_code'] not in REASONS}
    details = {}
    if unknown:
        audits = session.execute(select(AuditEvent.subject_id, AuditEvent.reason_code, AuditEvent.after_data)
            .where(AuditEvent.subject_type == 'ledger_transaction', AuditEvent.subject_id.in_(unknown),
                AuditEvent.result == 'SUCCESS', AuditEvent.after_data.is_not(None))
            .order_by(AuditEvent.created_at.desc(), AuditEvent.id.desc())).all()
        for audit in audits:
            value = audit.after_data.get('reason_detail') if isinstance(audit.after_data, dict) else None
            if isinstance(value, str) and value.strip() and len(value) <= 500:
                details.setdefault((audit.subject_id, audit.reason_code), value.strip())
    items = []
    for row in rows[:limit]:
        item = dict(row)
        item.pop('matches')
        item['created_at'] = utc_text(item['created_at'])
        item['amount'] = format(item['amount'], '.2f')
        item['reason_text'] = REASONS.get(item['reason_code'], '原因待补充')
        item['anomalies'] = [] if item['reason_code'] in REASONS else ['MISSING_REASON']
        item['reason_detail'] = details.get((item['transaction_id'], item['reason_code']))
        if item['reason_code'] not in REASONS and item['reason_detail']:
            item['reason_text'] = '其他：' + item['reason_detail']
            item['anomalies'] = []
        if item['scene'] == 'UNKNOWN':
            item['anomalies'].append('SCENE_UNVERIFIED')
        if row['matches'] and row['matches'] != 1:
            item['anomalies'].append('AMBIGUOUS_BUSINESS_LINK')
        item['account_kind'] = 'USER' if item['user_id'] else ('ESCROW' if item['account_id'].startswith(('PLATFORM_REDPACKET_ESCROW:', 'PLATFORM_TRANSFER_ESCROW:')) else 'PLATFORM' if item['account_id'] in ('PLATFORM_CLEARING', 'PLATFORM_FEE') else 'UNKNOWN')
        items.append(item)
    next_cursor = None
    if len(rows) > limit:
        last = rows[limit - 1]
        next_cursor = base64.urlsafe_b64encode(json.dumps([utc_text(cutoff), utc_text(last['created_at']), last['entry_id'], digest]).encode()).decode()
    return {'items': items, 'total': total, 'next_cursor': next_cursor}
