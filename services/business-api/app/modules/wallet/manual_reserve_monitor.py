"""Publish manual-wallet reserves only from covered immutable observer cuts.

Source max_rowid is a discovery watermark, not an eligible-event count: history
excluded by the activation baseline still occupies source row IDs. Coverage
assumes trustworthy atomic scan state and immutable facts. Mismatched manual
or partial database restores require controlled revalidation before operation.
"""
from dataclasses import asdict
from datetime import datetime, timedelta, timezone
from decimal import Decimal, localcontext
import hashlib
from itertools import groupby
import json
import re
import time
from app.integrations.tron import diagnostics as diag

from sqlalchemy import and_, func, or_, select
from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.core.outbox_handover import OutboxHandover

from app.integrations.tron.finality import NETWORK, POLICY, SOURCE_ID, USDT_CONTRACT
from app.integrations.tron.funding_source import ReserveCut, FundingSourcePending
from app.integrations.tron.message_signature import canonical_address
from app.modules.ledger.manual_reserve import publish_manual_reserve
from app.modules.ledger.manual_reserve_models import ManualReserveEvaluation
from app.modules.ledger.reserve import RedeemabilityReserve, lock_budget
from app.modules.ledger.service import LedgerService
from app.modules.ledger.wallet_obligations import invalidate_wallet_reserve
from app.modules.wallet.funding_coverage_models import WalletFundingCoverageEvent as Coverage
from app.modules.wallet.funding_scan_models import WalletFundingScanItem, WalletFundingScanState
from app.modules.wallet.incidents import WalletIncidentService
from app.modules.wallet.manual_control import apply_manual_pause, owns_manual_pause
from app.modules.wallet.ledger_integrity import WalletLedgerIntegrityService
from app.modules.wallet.reporting import ReportDataError
from app.modules.wallet.manual_payout_models import ManualPayoutEvent, ManualPayoutOrder, ManualPayoutQuote
from app.modules.wallet.models import WalletControl, WalletSafetyState
from app.modules.wallet.monitor_lock import monitor_scan_lock
from app.modules.wallet.monitoring import WalletMonitorHeartbeat
from app.modules.wallet.receipt_models import DepositReceipt, DepositReceiptAnomaly
from app.modules.wallet.safety import usdt_liability

ACTOR = 'manual-reserve-monitor'
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


class _ReviewRejected(Exception):
    def __init__(self, error):
        self.error = error


class _HandoverProofRejected(Exception):
    def __init__(self, code):
        self.code = code


def _aware(value):
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise ValueError('aware monitor clock required')
    return value.astimezone(timezone.utc)


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def _valid_cut(cut, identity):
    if not isinstance(cut, ReserveCut) or cut.source_identity != identity:
        return False
    if any(not isinstance(value, str) or re.fullmatch('[0-9a-f]{64}', value) is None
           for value in (cut.source_identity, cut.digest)):
        return False
    for key in ('observation_id', 'max_rowid', 'checkpoint_ms', 'solid_block', 'heartbeat_ms', 'fresh_until_ms'):
        value = getattr(cut, key)
        if type(value) is not int or not (1 if key == 'observation_id' else 0) <= value < 2**63:
            return False
    if type(cut.balance_units) is not int or not 0 <= cut.balance_units < 2**256 or type(cut.healthy) is not bool:
        return False
    values = asdict(cut)
    values.pop('digest')
    return _digest(values) == cut.digest


class ManualReserveMonitor:
    reserve_policy = 'full_backing'
    publish_backing_advisory = True
    discovery_sync = None
    def __init__(self, factory, *, source, official_config, activation_baseline_time,
                 activation_baseline_height, clock, external_delivery_configured=False,
                 stale_resample_budget_seconds=0, resample_monotonic=None, resample_sleep=None):
        canonical_address(official_config.address)
        identity = hashlib.sha256(('tron-mainnet-usdt:'+official_config.address).encode()).hexdigest()
        if (source.source_identity != identity or not official_config.version or not callable(clock)
                or type(activation_baseline_height) is not int or activation_baseline_height < 0
                or type(external_delivery_configured) is not bool):
            raise ValueError('manual reserve monitor configuration required')
        if type(stale_resample_budget_seconds) is not int or not 0 <= stale_resample_budget_seconds <= 60:
            raise ValueError('bounded stale resample budget required')
        self.stale_resample_budget_seconds = stale_resample_budget_seconds
        self.resample_monotonic = resample_monotonic or time.monotonic
        self.resample_sleep = resample_sleep or time.sleep
        if not callable(self.resample_monotonic) or not callable(self.resample_sleep):
            raise ValueError('resample clock and sleep must be callable')
        self.factory, self.source, self.config, self.clock = factory, source, official_config, clock
        self.baseline = _aware(activation_baseline_time)
        self.baseline_height = activation_baseline_height
        self.external_delivery_configured = external_delivery_configured
        self.incidents = WalletIncidentService(factory, now_factory=clock)

    def _heartbeat(self, session, now, code=None):
        row = session.get(WalletMonitorHeartbeat, 'global', with_for_update=True)
        if row is None:
            row = WalletMonitorHeartbeat(id='global', last_attempt_at=now)
            session.add(row)
        row.last_attempt_at, row.last_error_code = now, code
        row.external_delivery_configured = self.external_delivery_configured
        if code is None:
            row.last_success_at = now

    def _block(self, session, code, now):
        diag.emit('ERROR', 'monitor_block_requested', component='manual_monitor', reason_code=code)
        apply_manual_pause(session, ledger=LedgerService(self.factory), actor_id=ACTOR,
            reason_code=code, now=now)
        self.incidents.observe_in_session(session, [dict(fingerprint='manual-reserve:'+code,
            code=code, severity='P0', subject_id='global')], actor_id=ACTOR, complete=False)
        self._heartbeat(session, now, code)
        return dict(complete=False, status='BLOCKED', codes=[code])

    def _failed_source(self, code):
        with self.factory.begin() as session:
            return self._block(session, code, _aware(self.clock()))

    def _pending_source(self, pending):
        with self.factory.begin() as session:
            lock_budget(session)
            now = _aware(self.clock())
            now_ms = int(now.timestamp()*1000)
            diag.emit('DEBUG', 'source_pending_checked', component='manual_monitor',
                      pending_age_ms=now_ms-pending.since_ms if type(pending.since_ms) is int else None,
                      fresh_until_ms=pending.fresh_until_ms)
            if (type(pending.since_ms) is not int or type(pending.fresh_until_ms) is not int
                    or not 0 <= pending.since_ms <= now_ms <= pending.fresh_until_ms <= now_ms+120000):
                return self._block(session, 'MANUAL_SOURCE_UNHEALTHY', now)
            if now_ms-pending.since_ms >= 300000:
                return self._block(session, 'MANUAL_SOURCE_UNHEALTHY', now)
            # No source balance is accepted and no existing pause is removed.
            invalidate_wallet_reserve(session)
            self._heartbeat(session, now, 'MANUAL_SOURCE_PENDING')
            return dict(complete=False, status='WAITING', codes=['MANUAL_SOURCE_PENDING'])

    def _wait_for_coverage(self, session, now, *, discovery_since=None):
        ages = [discovery_since,
            session.scalar(select(func.min(WalletFundingScanItem.created_at)).where(WalletFundingScanItem.state != 'PROCESSED')),
            session.scalar(select(func.min(Coverage.created_at)).where(
                Coverage.source_identity == self.source.source_identity, Coverage.status == 'PENDING'))]
        for value in ages:
            if value is not None:
                value = value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value
                if now-value >= timedelta(minutes=5) or value > now:
                    return self._block(session, 'MANUAL_COVERAGE_BACKLOG', now)
        invalidate_wallet_reserve(session)
        self._heartbeat(session, now, 'MANUAL_COVERAGE_PENDING')
        return dict(complete=False, status='WAITING', codes=['MANUAL_COVERAGE_PENDING'])

    def run_once(self):
        return self._scan(review_only=False)

    def review_once(self, *, on_review=None):
        """Recheck conditions while paused; never publish reserves or unpause."""
        return self._scan(review_only=True, on_review=on_review)

    def handover_review_once(self, *, on_review):
        """Full proof for the funds-disabled handover; failed proof cannot adopt ownership."""
        review = _HandoverReserveReview(self.factory, source=self.source, official_config=self.config,
            activation_baseline_time=self.baseline, activation_baseline_height=self.baseline_height,
            clock=self.clock, external_delivery_configured=self.external_delivery_configured)
        review.reserve_policy = self.reserve_policy
        review.publish_backing_advisory = False
        return review._scan(review_only=True, on_review=on_review, escalate=False)

    def preparation_once(self):
        """Funds-disabled handover heartbeat; no source success or incident mutation."""
        with monitor_scan_lock(self.factory) as acquired:
            if not acquired:
                return dict(complete=False, status='RETRY', codes=['MONITOR_SCAN_BUSY'])
            with self.factory.begin() as session:
                lock_budget(session)
                invalidate_wallet_reserve(session)
                self._heartbeat(session, _aware(self.clock()), 'PREPARING_HANDOVER')
                return dict(complete=False, status='PREPARING_HANDOVER', codes=['PREPARING_HANDOVER'])

    def activate_once(self, *, on_activate):
        """Separate guarded activation; ordinary review never receives publication."""
        if not callable(on_activate):
            raise ValueError('activation completion required')
        return self._scan(review_only=True, on_activate=on_activate)

    @diag.traced('manual_monitor')
    def _scan(self, *, review_only, on_review=None, on_activate=None, escalate=True):
        try:
            with monitor_scan_lock(self.factory) as acquired:
                if not acquired:
                    return dict(complete=False, status='RETRY', codes=['MONITOR_SCAN_BUSY'])
                # Escalation owns a separate incident transaction. Run even if
                # the observer is unavailable, before any reserve publication.
                if escalate:
                    self.incidents.escalate()
                attempts = 3 if self.discovery_sync is not None else 1
                wait_state = {}
                for attempt in range(attempts):
                    # Discovery commits before reserve/incident proof, never under
                    # its financial transaction and never credits a receipt.
                    if self.discovery_sync is not None:
                        self.discovery_sync()
                    result = self._run(review_only=review_only, on_review=on_review, on_activate=on_activate,
                                       wait_state=wait_state)
                    if (result.get('complete') or result.get('codes') not in
                            (['MANUAL_COVERAGE_PENDING'], ['MANUAL_SOURCE_CHANGED'])):
                        return result
                    if attempt + 1 < attempts:
                        time.sleep(0.2)
                return result
        except _HandoverProofRejected as exc:
            return dict(complete=False, status='BLOCKED', codes=[exc.code])
        except _ReviewRejected as exc:
            # The completion transaction rolled back. An authorization/version
            # rejection is not a provider outage and must not alter incidents.
            raise exc.error from None
        except Exception as exc:
            diag.emit('ERROR', 'monitor_failed', component='manual_monitor',
                      reason_code='MANUAL_MONITOR_UNAVAILABLE', **diag.exception_info(exc))
            # Never expose DB/provider details or publish after partial failure.
            try:
                return self._failed_source('MANUAL_MONITOR_UNAVAILABLE')
            except Exception:
                return dict(complete=False, status='UNAVAILABLE', codes=['MANUAL_MONITOR_UNAVAILABLE'])

    def _begin_source_wait(self, expected, cut):
        """Commit an unusable reserve before waiting; never clear control state."""
        with self.factory.begin() as session:
            reserve = lock_budget(session)
            now = _aware(self.clock())
            if (reserve.version if reserve is not None else None) != expected:
                return {'result': dict(complete=False, status='RETRY', codes=['MANUAL_RESERVE_CHANGED'])}
            control = session.get(WalletControl, 'global', with_for_update=True)
            if control is None:
                return {'result': self._block(session, 'MANUAL_CONTROL_MISSING', now)}
            if session.scalar(select(OutboxEvent.id).where(OutboxHandover.unhealthy_predicate(now)).limit(1)):
                return {'result': self._block(session, 'ALERT_DELIVERY_UNHEALTHY', now)}
            if session.scalar(select(Coverage.id).where(Coverage.source_identity == self.source.source_identity,
                                                       Coverage.status == 'CONFLICT').limit(1)):
                return {'result': self._block(session, 'MANUAL_COVERAGE_CONFLICT', now)}
            if reserve is None:
                return {'result': self._block(session, 'MANUAL_SOURCE_UNHEALTHY', now)}
            if (cut.checkpoint_ms < int(self.baseline.timestamp()*1000)
                    or cut.solid_block < self.baseline_height):
                return {'result': self._block(session, 'MANUAL_SOURCE_UNHEALTHY', now)}
            state = session.get(WalletFundingScanState, 'global', with_for_update=True)
            if (state is None or state.source_identity != cut.source_identity
                    or state.cursor_rowid > cut.max_rowid or state.source_max_rowid > cut.max_rowid
                    or state.checkpoint_ms > cut.checkpoint_ms):
                return {'result': self._block(session, 'MANUAL_COVERAGE_GAP', now)}
            # Only age may be deferred. Reuse the coverage proof so receipt
            # anomalies and mismatched payout evidence cannot hide in a wait.
            code = self._coverage(session, cut)
            if code and code != 'MANUAL_COVERAGE_PENDING':
                return {'result': self._block(session, code, now)}
            pending, oldest = session.execute(select(func.count(), func.min(ManualPayoutOrder.claimed_at))
                .where(ManualPayoutOrder.status.in_(('CLAIMED', 'UNKNOWN')))).one()
            if pending != reserve.pending_payouts:
                return {'result': self._block(session, 'MANUAL_PAYOUT_PENDING_MISMATCH', now)}
            if pending:
                oldest = oldest.replace(tzinfo=timezone.utc) if oldest.tzinfo is None else oldest
                if now-oldest >= timedelta(minutes=5) or oldest > now:
                    return {'result': self._block(session, 'MANUAL_PAYOUT_UNCERTAIN', now)}
            safety = session.get(WalletSafetyState, 'global')
            if control.withdrawals_paused or reserve.outgoing_restricted or safety is not None and safety.restricted:
                if not owns_manual_pause(session):
                    return {'result': self._block(session, 'MANUAL_WALLET_PAUSED', now)}
                invalidate_wallet_reserve(session)
                self._heartbeat(session, now, 'MANUAL_WALLET_PAUSED')
                return {'result': dict(complete=False, status='WAITING', codes=['MANUAL_WALLET_PAUSED'])}
            with localcontext() as context:
                context.prec = 100
                liability = usdt_liability(session)
                eligible = Decimal(cut.balance_units)/Decimal(1000000)
                required = liability + LedgerService(self.factory).redeemable_liability(session=session)
                if eligible < required and self.reserve_policy == 'full_backing':
                    return {'result': self._block(session, 'MANUAL_RESERVE_DEFICIT', now)}
                if any(value >= Decimal('1e24') for value in (liability, eligible)):
                    return {'result': self._block(session, 'MANUAL_RESERVE_OVERFLOW', now)}
            if (code == 'MANUAL_COVERAGE_PENDING' or state.cursor_rowid < cut.max_rowid
                    or state.source_max_rowid < cut.max_rowid or state.checkpoint_ms < cut.checkpoint_ms):
                return {'result': self._wait_for_coverage(session, now,
                    discovery_since=state.updated_at if state.cursor_rowid < cut.max_rowid else None)}
            invalidate_wallet_reserve(session)
            if pending:
                self._heartbeat(session, now, 'MANUAL_PAYOUT_PENDING')
                return {'result': dict(complete=False, status='WAITING', codes=['MANUAL_PAYOUT_PENDING'])}
            self._heartbeat(session, now, 'MANUAL_SOURCE_WAITING')
            # Capture only our invalidation's version before further external
            # reads. A concurrent financial write still fails the later CAS.
            return {'expected': reserve.version if reserve is not None else None}

    def _run(self, *, review_only=False, on_review=None, on_activate=None, wait_state=None):
        # Both external reads happen outside the financial transaction. A
        # concurrent claim/settlement is detected again under the budget lock.
        with self.factory() as session:
            reserve = session.get(RedeemabilityReserve, 'global')
            expected = reserve.version if reserve is not None else None
        try:
            integrity = WalletLedgerIntegrityService(self.factory).check(_aware(self.clock()))
            if not integrity['balanced'] or integrity['missing_transaction_metadata']:
                return self._failed_source('LEDGER_INTEGRITY')
            if self.stale_resample_budget_seconds and not review_only:
                from app.modules.wallet.manual_source_resample import read_fresh_cut
                sampled = read_fresh_cut(self, expected, wait_state if wait_state is not None else {}, _valid_cut)
                if 'result' in sampled:
                    return sampled['result']
                cut, expected = sampled['cut'], sampled['expected']
            else:
                cut = self.source.read_reserve_cut()
            if not _valid_cut(cut, self.source.source_identity):
                return self._failed_source('MANUAL_SOURCE_INVALID')
            sample_ms = int(_aware(self.clock()).timestamp()*1000)
            if (not self.stale_resample_budget_seconds or review_only) and (not cut.healthy or sample_ms > cut.fresh_until_ms):
                # A just-committing observer snapshot can replace the expired
                # sample. Resample once; never extend or accept its deadline.
                time.sleep(0.2)
                cut = self.source.read_reserve_cut()
                if not _valid_cut(cut, self.source.source_identity):
                    return self._failed_source('MANUAL_SOURCE_INVALID')
            second = (sampled['second'] if self.stale_resample_budget_seconds and not review_only
                      and 'second' in sampled else self.source.read_reserve_cut())
            if not _valid_cut(second, self.source.source_identity):
                return self._failed_source('MANUAL_SOURCE_INVALID')
            if second != cut:
                return dict(complete=False, status='RETRY', codes=['MANUAL_SOURCE_CHANGED'])
        except ReportDataError:
            return self._failed_source('LEDGER_INTEGRITY')
        except FundingSourcePending as pending:
            return self._pending_source(pending)
        except Exception as exc:
            diag.emit('ERROR', 'source_read_failed', component='manual_monitor',
                      reason_code='MANUAL_SOURCE_UNAVAILABLE', **diag.exception_info(exc))
            return self._failed_source('MANUAL_SOURCE_UNAVAILABLE')
        with self.factory.begin() as session:
            reserve = lock_budget(session)
            control = session.get(WalletControl, 'global', with_for_update=True)
            now = _aware(self.clock())
            if (reserve.version if reserve is not None else None) != expected:
                return dict(complete=False, status='RETRY', codes=['MANUAL_RESERVE_CHANGED'])
            if control is None:
                return self._block(session, 'MANUAL_CONTROL_MISSING', now)
            if session.scalar(select(OutboxEvent.id).where(OutboxHandover.unhealthy_predicate(now)).limit(1)):
                return self._block(session, 'ALERT_DELIVERY_UNHEALTHY', now)
            now_ms = int(now.timestamp()*1000)
            diag.emit('DEBUG', 'reserve_cut_checked', component='manual_monitor', observation_id=cut.observation_id,
                      checkpoint_ms=cut.checkpoint_ms, solid_block=cut.solid_block,
                      fresh_until_ms=cut.fresh_until_ms, heartbeat_age_ms=now_ms-cut.heartbeat_ms)
            if (not cut.healthy or not cut.heartbeat_ms <= now_ms <= cut.fresh_until_ms
                    or cut.checkpoint_ms < int(self.baseline.timestamp()*1000)
                    or cut.solid_block < self.baseline_height):
                diag.emit('WARNING', 'reserve_cut_rejected', component='manual_monitor',
                          reason_code='SOURCE_UNHEALTHY' if not cut.healthy else 'CUT_EXPIRED'
                          if not cut.heartbeat_ms <= now_ms <= cut.fresh_until_ms else 'BASELINE_NOT_REACHED',
                          observation_id=cut.observation_id, fresh_until_ms=cut.fresh_until_ms,
                          checkpoint_ms=cut.checkpoint_ms, solid_block=cut.solid_block)
                return self._block(session, 'MANUAL_SOURCE_UNHEALTHY', now)
            state = session.get(WalletFundingScanState, 'global', with_for_update=True)
            if (state is None or state.source_identity != cut.source_identity
                    or state.cursor_rowid > cut.max_rowid or state.source_max_rowid > cut.max_rowid
                    or state.checkpoint_ms > cut.checkpoint_ms):
                return self._block(session, 'MANUAL_COVERAGE_GAP', now)
            if session.scalar(select(Coverage.id).where(Coverage.source_identity == cut.source_identity,
                                                       Coverage.status == 'CONFLICT').limit(1)):
                return self._block(session, 'MANUAL_COVERAGE_CONFLICT', now)
            if (state.cursor_rowid < cut.max_rowid or state.source_max_rowid < cut.max_rowid
                    or state.checkpoint_ms < cut.checkpoint_ms):
                return self._wait_for_coverage(session, now,
                    discovery_since=state.updated_at if state.cursor_rowid < cut.max_rowid else None)
            code = self._coverage(session, cut)
            if code == 'MANUAL_COVERAGE_PENDING':
                return self._wait_for_coverage(session, now)
            if code:
                return self._block(session, code, now)
            pending, oldest = session.execute(select(func.count(), func.min(ManualPayoutOrder.claimed_at))
                .where(ManualPayoutOrder.status.in_(('CLAIMED', 'UNKNOWN')))).one()
            if pending != (reserve.pending_payouts if reserve is not None else 0):
                return self._block(session, 'MANUAL_PAYOUT_PENDING_MISMATCH', now)
            if pending:
                oldest = oldest.replace(tzinfo=timezone.utc) if oldest.tzinfo is None else oldest
                if now-oldest >= timedelta(minutes=5) or oldest > now:
                    return self._block(session, 'MANUAL_PAYOUT_UNCERTAIN', now)
                invalidate_wallet_reserve(session)
                self._heartbeat(session, now, 'MANUAL_PAYOUT_PENDING')
                return dict(complete=False, status='WAITING', codes=['MANUAL_PAYOUT_PENDING'])
            safety = session.get(WalletSafetyState, 'global')
            if not review_only and (control.withdrawals_paused or reserve is not None and reserve.outgoing_restricted or safety is not None and safety.restricted):
                if not owns_manual_pause(session):
                    return self._block(session, 'MANUAL_WALLET_PAUSED', now)
                invalidate_wallet_reserve(session)
                self._heartbeat(session, now, 'MANUAL_WALLET_PAUSED')
                return dict(complete=False, status='WAITING', codes=['MANUAL_WALLET_PAUSED'])
            with localcontext() as context:
                context.prec = 100
                liability = usdt_liability(session)
                eligible = Decimal(cut.balance_units)/Decimal(1000000)
                required = liability + LedgerService(self.factory).redeemable_liability(session=session)
                if eligible < required and self.reserve_policy == 'full_backing':
                    return self._block(session, 'MANUAL_RESERVE_DEFICIT', now)
                if self.reserve_policy == 'manual_liquidity' and self.publish_backing_advisory:
                    deficits = [dict(fingerprint='manual-liquidity:backing-deficit', code='MANUAL_BACKING_DEFICIT',
                        severity='P1', subject_id='global')] if eligible < required else []
                    self.incidents.observe_in_session(session, deficits, actor_id=ACTOR,
                        complete=True, clear_prefix='manual-liquidity:')
                if any(value >= Decimal('1e24') for value in (liability, eligible)):
                    return self._block(session, 'MANUAL_RESERVE_OVERFLOW', now)
            if review_only:
                if on_activate is not None:
                    if not self.external_delivery_configured:
                        raise _ReviewRejected(AppError(code='MANUAL_CONTROL_ALERTS_NOT_CONFIGURED',
                            message='外部告警尚未配置', status_code=503))
                    def publish(*, actor_id, idempotency_key):
                        self._require_commit_freshness(cut)
                        evidence = asdict(cut)
                        for key in ('source_identity', 'observation_id', 'digest'):
                            evidence.pop(key)
                        current = lock_budget(session)
                        row = publish_manual_reserve(session, expected_version=current.version if current is not None else None,
                            eligible_usdt=eligible, usdt_liability=usdt_liability(session), pending_payouts=0,
                            observed_at=EPOCH+timedelta(milliseconds=cut.fresh_until_ms-120000), now=_aware(self.clock()),
                            source_identity=cut.source_identity, observation_id=cut.observation_id, cut_digest=cut.digest,
                            evidence=evidence, actor_id=actor_id, idempotency_key=idempotency_key, policy=self.reserve_policy)
                        self._heartbeat(session, _aware(self.clock()))
                        return row
                    try:
                        result = on_activate(session, publish)
                        self._require_commit_freshness(cut)
                    except AppError as exc:
                        raise _ReviewRejected(exc) from None
                    return dict(complete=True, status='ACTIVATED', codes=[], result=result)
                if on_review is not None:
                    try:
                        result = on_review(session)
                        self._require_commit_freshness(cut)
                    except AppError as exc:
                        raise _ReviewRejected(exc) from None
                    return dict(complete=True, status='REVIEWED', codes=[], result=result)
                self.incidents.observe_in_session(session, [], actor_id=ACTOR,
                    complete=True, clear_prefix='manual-reserve:')
                try:
                    self._require_commit_freshness(cut)
                except AppError as exc:
                    raise _ReviewRejected(exc) from None
                return dict(complete=True, status='REVIEWED', codes=[])
            last = session.scalar(select(ManualReserveEvaluation).where(
                ManualReserveEvaluation.source_identity == cut.source_identity)
                .order_by(ManualReserveEvaluation.result_version.desc()).limit(1))
            now = _aware(self.clock())
            if not cut.heartbeat_ms <= int(now.timestamp()*1000) <= cut.fresh_until_ms:
                return self._block(session, 'MANUAL_SOURCE_UNHEALTHY', now)
            if (last is not None and last.cut_digest == cut.digest and reserve is not None
                    and last.result_version == reserve.version and reserve.usdt_liability == liability):
                self._heartbeat(session, now)
                self._require_commit_freshness(cut)
                return dict(complete=True, status='UNCHANGED', codes=[], evaluation_id=last.id)
            evidence = asdict(cut)
            for key in ('source_identity', 'observation_id', 'digest'):
                evidence.pop(key)
            row = publish_manual_reserve(session, expected_version=expected, eligible_usdt=eligible,
                usdt_liability=liability, pending_payouts=pending,
                observed_at=EPOCH+timedelta(milliseconds=cut.fresh_until_ms-120000), now=now,
                source_identity=cut.source_identity, observation_id=cut.observation_id, cut_digest=cut.digest,
                evidence=evidence, actor_id=ACTOR, policy=self.reserve_policy, idempotency_key='manual-reserve:'+_digest(dict(
                    cut=cut.digest, version=expected, liability=str(liability))))
            self._heartbeat(session, now)
            # Publication and heartbeat may themselves wait on database locks.
            # Expiry here rolls the entire transaction back before fail-closed.
            self._require_commit_freshness(cut)
            return dict(complete=True, status='PUBLISHED', codes=[], evaluation_id=row.id)

    def _require_commit_freshness(self, cut):
        now_ms = int(_aware(self.clock()).timestamp()*1000)
        if not cut.heartbeat_ms <= now_ms <= cut.fresh_until_ms:
            raise AppError(code='WALLET_MONITOR_EVIDENCE_EXPIRED',
                message='链上核验证据已过期，请重新复核', status_code=503)

    def _coverage(self, session, cut):
        rows = session.execute(select(Coverage, DepositReceipt,
                select(DepositReceiptAnomaly.id).where(DepositReceiptAnomaly.receipt_id == DepositReceipt.id).exists(),
                ManualPayoutEvent, ManualPayoutOrder, ManualPayoutQuote)
            .outerjoin(DepositReceipt, and_(DepositReceipt.network == NETWORK, DepositReceipt.contract == USDT_CONTRACT,
                DepositReceipt.txid == Coverage.txid, DepositReceipt.log_index == Coverage.log_index))
            .outerjoin(ManualPayoutEvent, and_(ManualPayoutEvent.network == NETWORK, ManualPayoutEvent.contract == USDT_CONTRACT,
                ManualPayoutEvent.txid == Coverage.txid, ManualPayoutEvent.log_index == Coverage.log_index))
            .outerjoin(ManualPayoutOrder, ManualPayoutOrder.id == ManualPayoutEvent.order_id)
            .outerjoin(ManualPayoutQuote, ManualPayoutQuote.id == ManualPayoutOrder.quote_id)
            .where(Coverage.source_identity == cut.source_identity)
            .order_by(Coverage.txid, Coverage.log_index).execution_options(yield_per=250))
        try:
            for txid, group in groupby(rows, key=lambda row: row[0].txid):
                facts, proofs = [], []
                for coverage, receipt, anomaly, event, order, quote in group:
                    if (coverage.source_rowid > cut.max_rowid or coverage.block_number > cut.solid_block
                            or coverage.timestamp_ms > cut.checkpoint_ms
                            or coverage.block_number <= self.baseline_height
                            or coverage.timestamp_ms < int(self.baseline.timestamp()*1000)):
                        return 'MANUAL_COVERAGE_GAP'
                    proof = coverage.proof
                    if coverage.status == 'PENDING':
                        return 'MANUAL_COVERAGE_PENDING'
                    if (coverage.status != 'VERIFIED' or not isinstance(proof, dict)
                            or any(proof.get(key) != value for key, value in dict(network=NETWORK,
                                contract=USDT_CONTRACT, policy=POLICY, source_id=SOURCE_ID).items())
                            or not proof.get('transaction_facts_digest')):
                        return 'MANUAL_COVERAGE_CONFLICT'
                    fact = {key: getattr(coverage, key) for key in ('txid', 'log_index', 'amount_units',
                        'from_address', 'to_address', 'block_number', 'timestamp_ms')}
                    facts.append(fact)
                    proofs.append(proof)
                    # Same per-transaction log cap as the finality adapter;
                    # there is no cap on the lifetime stream of transactions.
                    if len(facts) > 10000:
                        return 'MANUAL_TRANSACTION_TOO_LARGE'
                    if self.config.address not in (coverage.from_address, coverage.to_address):
                        return 'MANUAL_COVERAGE_CONFLICT'
                    if coverage.from_address == coverage.to_address:
                        continue
                    if coverage.to_address == self.config.address:
                        if (receipt is None or anomaly or receipt.amount is None
                                or receipt.official_config_version != self.config.version
                                or receipt.amount_units != coverage.amount_units
                                or not self._receipt_amount_matches(receipt, coverage)
                                or receipt.source_address != coverage.from_address
                                or receipt.official_address != coverage.to_address
                                or receipt.block_number != coverage.block_number
                                or receipt.block_id != proof.get('block_id')
                                or not (receipt.status == 'CREDITED' or receipt.status == 'REVIEW' and receipt.pending_obligation)):
                            return 'MANUAL_RECEIPT_OBLIGATION_MISSING'
                    elif (event is None or order is None or quote is None or order.status != 'SETTLED'
                            or quote.snapshot.get('official_address') != coverage.from_address
                            or quote.snapshot.get('target_address') != coverage.to_address
                            or quote.snapshot.get('official_config_version') != self.config.version
                            or event.evidence.get('policy') != POLICY
                            or event.evidence.get('source_id') != SOURCE_ID
                            or order.amount != quote.amount
                            or not self._payout_amount_matches(coverage, order, quote)
                            or event.evidence.get('block_id') != proof.get('block_id')
                            or event.evidence.get('block_number') != coverage.block_number
                            or event.evidence.get('timestamp_ms') != coverage.timestamp_ms
                            or str(event.evidence.get('amount_units')) != coverage.amount_units):
                        return 'MANUAL_UNALLOCATED_OUTFLOW'
                digest = hashlib.sha256(json.dumps(facts, sort_keys=True).encode()).hexdigest()
                if any(proof['transaction_facts_digest'] != digest for proof in proofs):
                    return 'MANUAL_COVERAGE_CONFLICT'
                item = session.get(WalletFundingScanItem, txid)
                if item is None:
                    return 'MANUAL_COVERAGE_GAP'
                if item.state != 'PROCESSED':
                    return 'MANUAL_COVERAGE_PENDING'
        finally:
            rows.close()
        missing = session.scalar(select(WalletFundingScanItem).where(~select(Coverage.id).where(
                Coverage.source_identity == cut.source_identity, Coverage.txid == WalletFundingScanItem.txid).exists()).limit(1))
        if missing:
            return 'MANUAL_COVERAGE_GAP' if missing.state == 'PROCESSED' else 'MANUAL_COVERAGE_PENDING'
        # A settlement ahead of this observer cut already reduced the ledger
        # liability. Its older, larger chain balance must not be published.
        if session.scalar(select(ManualPayoutEvent.id).join(ManualPayoutOrder,
                ManualPayoutOrder.id == ManualPayoutEvent.order_id)
            .join(ManualPayoutQuote, ManualPayoutQuote.id == ManualPayoutOrder.quote_id)
            .outerjoin(Coverage, and_(Coverage.source_identity == cut.source_identity,
                Coverage.txid == ManualPayoutEvent.txid, Coverage.log_index == ManualPayoutEvent.log_index))
            .where(ManualPayoutQuote.snapshot['official_address'].as_string() == self.config.address,
                or_(Coverage.id.is_(None), Coverage.source_rowid > cut.max_rowid, Coverage.status != 'VERIFIED')).limit(1)):
            return 'MANUAL_SETTLEMENT_AHEAD_OF_CUT'
        return None

    @staticmethod
    def _receipt_amount_matches(receipt, coverage):
        try:
            with localcontext() as context:
                context.prec = 100
                return receipt.amount == Decimal(coverage.amount_units)/Decimal(1000000)
        except (ValueError, TypeError, ArithmeticError):
            return False

    @staticmethod
    def _payout_amount_matches(coverage, order, quote):
        try:
            with localcontext() as context:
                context.prec = 100
                amount = Decimal(coverage.amount_units)/Decimal(1000000)
                return amount == order.amount and all(Decimal(quote.snapshot[key]) == amount
                    for key in ('amount', 'receive', 'hold')) and Decimal(quote.snapshot['fee']) == 0
        except (ValueError, TypeError, KeyError, ArithmeticError):
            return False


class _HandoverReserveReview(ManualReserveMonitor):
    """Isolated proof policy: preserve the existing legacy pause on rejection.

    Transactional failures raise so any proof-side writes roll back. This object
    is created per handover call; ordinary monitor instances retain escalation.
    """

    def _block(self, session, code, now):
        raise _HandoverProofRejected(code)

    def _heartbeat(self, session, now, code=None):
        if code is not None:
            raise _HandoverProofRejected(code)
        return super()._heartbeat(session, now, code)

    def _failed_source(self, code):
        return dict(complete=False, status='BLOCKED', codes=[code])

    def _pending_source(self, pending):
        return dict(complete=False, status='WAITING', codes=['MANUAL_SOURCE_PENDING'])

    def _wait_for_coverage(self, session, now, *, discovery_since=None):
        raise _HandoverProofRejected('MANUAL_COVERAGE_PENDING')
