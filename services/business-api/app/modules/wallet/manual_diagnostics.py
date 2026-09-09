"""Read-only, bounded operational hints; never authorize recovery or change state."""
from datetime import datetime, timezone

from sqlalchemy import select, func

from app.integrations.tron import diagnostics as diag
from app.integrations.tron.funding_source import FundingSourcePending
from app.modules.wallet.funding_scan_models import WalletFundingScanState
from app.modules.wallet.funding_coverage_models import WalletFundingCoverageEvent as Coverage


MONITOR_REASONS = frozenset('''
ALERT_DELIVERY_UNHEALTHY LEDGER_INTEGRITY MANUAL_BACKING_DEFICIT
MANUAL_CONTROL_ALERTS_NOT_CONFIGURED MANUAL_CONTROL_MISSING
MANUAL_COVERAGE_BACKLOG MANUAL_COVERAGE_CONFLICT MANUAL_COVERAGE_GAP MANUAL_COVERAGE_PENDING
MANUAL_MONITOR_UNAVAILABLE MANUAL_PAYOUT_PENDING_MISMATCH MANUAL_PAYOUT_PENDING
MANUAL_PAYOUT_UNCERTAIN MANUAL_RECEIPT_OBLIGATION_MISSING MANUAL_RESERVE_CHANGED
MANUAL_RESERVE_DEFICIT MANUAL_RESERVE_OVERFLOW MANUAL_SETTLEMENT_AHEAD_OF_CUT
MANUAL_SOURCE_CHANGED MANUAL_SOURCE_INVALID MANUAL_SOURCE_PENDING MANUAL_SOURCE_UNAVAILABLE
MANUAL_SOURCE_UNHEALTHY MANUAL_TRANSACTION_TOO_LARGE MANUAL_UNALLOCATED_OUTFLOW
MANUAL_WALLET_PAUSED MONITOR_SCAN_BUSY WALLET_MONITOR_EVIDENCE_EXPIRED
'''.split())


def safe_review_result(result):
    status = result.get('status')
    status = status if status in ('WAITING', 'RETRY', 'BLOCKED', 'UNAVAILABLE') else 'UNAVAILABLE'
    raw = result.get('codes')
    codes = list(dict.fromkeys(x for x in raw if isinstance(x, str) and x in MONITOR_REASONS)) if isinstance(raw, list) else []
    return status, codes or ['MANUAL_MONITOR_UNAVAILABLE']


def current_diagnostics(factory, source, clock):
    now = clock()
    result = dict(checked_at=now, source_status='UNAVAILABLE', coverage_status='UNAVAILABLE',
                  observation_id=None, heartbeat_at=None, codes=[])
    try:
        cut = source.read_reserve_cut()
    except FundingSourcePending:
        return result | dict(source_status='WAITING', codes=['MANUAL_SOURCE_PENDING'])
    except Exception as exc:
        diag.emit('WARNING', 'diagnostic_source_unavailable', component='manual_monitor',
                  reason_code='MANUAL_SOURCE_UNAVAILABLE', **diag.exception_info(exc))
        return result | dict(codes=['MANUAL_SOURCE_UNAVAILABLE'])
    try:
        now = clock()
        result['checked_at'] = now
        result['observation_id'] = int(cut.observation_id)
        result['heartbeat_at'] = datetime.fromtimestamp(cut.heartbeat_ms / 1000, timezone.utc)
        result['source_status'] = 'HEALTHY' if cut.healthy and cut.heartbeat_ms <= int(now.timestamp()*1000) <= cut.fresh_until_ms else 'UNHEALTHY'
        if result['source_status'] != 'HEALTHY':
            result['codes'].append('MANUAL_SOURCE_UNHEALTHY')
        with factory() as session:
            # No locks, monitor execution, credentials, ledger amounts or addresses.
            state = session.execute(select(WalletFundingScanState.source_identity,
                WalletFundingScanState.cursor_rowid, WalletFundingScanState.source_max_rowid,
                WalletFundingScanState.checkpoint_ms).where(WalletFundingScanState.id=='global')).first()
            statuses = dict(session.execute(select(Coverage.status, func.count()).where(
                Coverage.source_identity==source.source_identity).group_by(Coverage.status)).all())
        if source.read_reserve_cut() != cut:
            return result | dict(source_status='WAITING', coverage_status='WAITING', codes=['MANUAL_SOURCE_CHANGED'])
        if state is None or state.source_identity != source.source_identity:
            result['coverage_status'] = 'CONFLICT'
            result['codes'].append('MANUAL_COVERAGE_GAP')
        elif (state.cursor_rowid > cut.max_rowid or state.source_max_rowid > cut.max_rowid
                or state.checkpoint_ms > cut.checkpoint_ms):
            result['coverage_status'] = 'WAITING'
            result['codes'].append('MANUAL_SOURCE_CHANGED')
        elif statuses.get('CONFLICT', 0):
            result['coverage_status'] = 'CONFLICT'
            result['codes'].append('MANUAL_COVERAGE_CONFLICT')
        elif (state.cursor_rowid < cut.max_rowid or state.source_max_rowid < cut.max_rowid
                or state.checkpoint_ms < cut.checkpoint_ms or statuses.get('PENDING', 0)):
            result['coverage_status'] = 'WAITING'
            result['codes'].append('MANUAL_COVERAGE_PENDING')
        else:
            result['coverage_status'] = 'CURRENT'
        result['checked_at'] = clock()
        if not cut.heartbeat_ms <= int(result['checked_at'].timestamp()*1000) <= cut.fresh_until_ms:
            result['source_status'] = 'UNHEALTHY'
            if 'MANUAL_SOURCE_UNHEALTHY' not in result['codes']:
                result['codes'].append('MANUAL_SOURCE_UNHEALTHY')
        return result
    except Exception as exc:
        diag.emit('WARNING', 'diagnostic_snapshot_unavailable', component='manual_monitor',
                  reason_code='MANUAL_MONITOR_UNAVAILABLE', **diag.exception_info(exc))
        return dict(checked_at=clock(), source_status='UNAVAILABLE', coverage_status='UNAVAILABLE',
                    observation_id=None, heartbeat_at=None, codes=['MANUAL_MONITOR_UNAVAILABLE'])
