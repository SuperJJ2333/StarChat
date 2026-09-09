"""Owner controls; activation requires a complete monitor transaction, never a review."""
from datetime import timedelta, timezone
import hashlib
import json
import re
import time
from app.integrations.tron import diagnostics as diag
from uuid import uuid4
from sqlalchemy import select
from app.core.errors import AppError, FieldError
from app.core.outbox import OutboxPublisher
from app.modules.audit.models import AuditEvent
from app.modules.ledger.reserve import lock_budget
from app.modules.ledger.service import LedgerService
from app.modules.ledger.wallet_obligations import invalidate_wallet_reserve
from app.modules.wallet.incidents import WalletIncidentService
from app.modules.wallet.manual_control_models import WalletManualControlState, WalletManualControlCommand
from app.modules.wallet.models import WalletControl, WalletSafetyState, Withdrawal
from app.modules.wallet.manual_payout_models import ManualPayoutOrder


def _error(code, status=409):
    raise AppError(code=code, message=code, status_code=status)


_TRANSIENT_ACTIVATION = frozenset({('WAITING','MANUAL_SOURCE_PENDING'),
    ('WAITING','MANUAL_COVERAGE_PENDING'),('RETRY','MONITOR_SCAN_BUSY'),
    ('RETRY','MANUAL_SOURCE_CHANGED'),('RETRY','MANUAL_RESERVE_CHANGED')})

def _evidence_unavailable(reason):
    safe = reason if reason in {code for _,code in _TRANSIENT_ACTIVATION} | {'MANUAL_CONTROL_PROOF_DEADLINE'} else 'MANUAL_CONTROL_PROOF_REJECTED'
    raise AppError(code='MANUAL_CONTROL_EVIDENCE_UNAVAILABLE',message='资金恢复证据尚未通过核验',status_code=503,
        fields=[FieldError(loc=['evidence'],msg=safe,type='wallet.control.evidence')])


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def apply_manual_pause(session, *, ledger, actor_id, reason_code, now):
    """Record only pause/safety flags actually introduced by this manual writer."""
    lock_budget(session)
    control = session.get(WalletControl, 'global', with_for_update=True)
    state = session.get(WalletManualControlState, 'global', with_for_update=True)
    if state is None:
        state = WalletManualControlState(id='global', epoch=1, owns_pause=False,
            owns_safety=False, updated_at=now)
        session.add(state)
    else:
        state.epoch += 1
        state.updated_at = now
    if control is None:
        control = WalletControl(id='global', withdrawals_paused=True, pause_reason=reason_code)
        session.add(control)
        state.owns_pause, state.pause_reason = True, reason_code
    elif not control.withdrawals_paused:
        control.withdrawals_paused, control.pause_reason = True, reason_code
        state.owns_pause, state.pause_reason = True, reason_code
    # Existing flags keep their exact provenance. Do not overwrite a risk
    # reason, or infer ownership merely because its spelling looks manual.
    safety = session.get(WalletSafetyState, 'global', with_for_update=True)
    if safety is None:
        safety = WalletSafetyState(id='global', restricted=True, epoch=1, reason=reason_code)
        session.add(safety)
        state.owns_safety, state.safety_epoch, state.safety_reason = True, 1, reason_code
    elif not safety.restricted:
        safety.restricted, safety.reason, safety.epoch = True, reason_code, safety.epoch+1
        state.owns_safety, state.safety_epoch, state.safety_reason = True, safety.epoch, reason_code
    ledger.restrict_redeemable_outgoing(session=session, actor_id=actor_id,
        reason_code=reason_code, scope='manual_tron')
    invalidate_wallet_reserve(session)
    payload = dict(epoch=state.epoch, withdrawals_paused=True)
    session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type='wallet_control',
        subject_id='global', action='wallet.manual_control.paused', result='SUCCESS',
        reason_code=reason_code, trace_id=uuid4().hex, after_data=payload, created_at=now))
    OutboxPublisher.enqueue(session, topic='wallet', event_type='wallet.manual_control.paused',
        aggregate_type='wallet_control', aggregate_id='global', payload=payload, now=now)
    session.flush()
    return state


def owns_manual_pause(session):
    """A healthy manual pause is waiting, while an unknown pause still alarms."""
    state = session.get(WalletManualControlState, 'global')
    control = session.get(WalletControl, 'global')
    safety = session.get(WalletSafetyState, 'global')
    return bool(state and control and (not control.withdrawals_paused or state.owns_pause
        and control.pause_reason == state.pause_reason) and (safety is None or not safety.restricted
        or state.owns_safety and safety.reason == state.safety_reason and safety.epoch == state.safety_epoch))


class ManualWalletControl:
    reserve_policy = 'full_backing'
    def __init__(self, factory, *, clock, configuration_id):
        if not callable(clock) or not configuration_id:
            raise ValueError('manual control trusted configuration required')
        self.factory, self.clock, self.configuration_id = factory, clock, configuration_id
        self.ledger, self.incidents = LedgerService(factory), WalletIncidentService(factory)

    def _snapshot(self, session):
        reserve = lock_budget(session)
        control = session.get(WalletControl, 'global', with_for_update=True)
        state = session.get(WalletManualControlState, 'global', with_for_update=True)
        safety = session.get(WalletSafetyState, 'global', with_for_update=True)
        restrictions = self.ledger.restriction_snapshot(session=session)
        incidents = self.incidents.control_snapshot_in_session(session)
        others = [dict(id=row.id, epoch=row.epoch, reason=row.reason) for row in session.scalars(
            select(WalletSafetyState).where(WalletSafetyState.id != 'global',
                WalletSafetyState.restricted.is_(True)).order_by(WalletSafetyState.id)).all()]
        allowed = self.incidents.nonblocking_backing_advisories_in_session(session) if self.reserve_policy == 'manual_liquidity' else set()
        unresolved = sum((row['status'] != 'RESOLVED' or row['active']) and row['id'] not in allowed for row in incidents)
        paused = control is None or control.withdrawals_paused
        global_restricted = bool(safety and safety.restricted)
        outgoing_restricted = bool(reserve and reserve.outgoing_restricted)
        snapshot = dict(configuration=self.configuration_id, epoch=state.epoch if state else 0,
            control=None if control is None else [control.withdrawals_paused, control.pause_reason],
            ownership=None if state is None else [state.owns_pause, state.pause_reason,
                state.owns_safety, state.safety_epoch, state.safety_reason],
            safety=None if safety is None else [safety.restricted, safety.epoch, safety.reason],
            reserve=None if reserve is None else [reserve.version, reserve.outgoing_restricted, reserve.pending_payouts],
            restrictions=restrictions, incidents=incidents, user_restrictions=others)
        observed = None if reserve is None else reserve.observed_at
        if observed is not None and observed.tzinfo is None:
            observed = observed.replace(tzinfo=timezone.utc)
        fresh = observed is not None and timedelta(0) <= self.clock()-observed <= timedelta(seconds=120)
        return dict(epoch=snapshot['epoch'], snapshot_digest=_digest(snapshot),
            reserve_version=reserve.version if reserve else None, withdrawals_paused=paused,
            global_restricted=global_restricted, outgoing_restricted=outgoing_restricted,
            restriction_scopes=sorted(row['scope'] for row in restrictions if row['active']),
            unresolved_incidents=unresolved, status='PAUSED' if paused or global_restricted or outgoing_restricted
            or any(row['active'] for row in restrictions)
            or others or unresolved else 'RUNNING' if fresh else 'AWAITING_EVIDENCE')

    def status(self, *, authorize=None):
        with self.factory.begin() as session:
            lock_budget(session)
            session.get(WalletControl, 'global', with_for_update=True)
            fresh = authorize(session) if authorize is not None else None
            result = self._snapshot(session)
            if fresh is not None:
                fresh()
            return result

    def _payload(self, operation, actor_id, reason_code, idempotency_key, expected_epoch, snapshot_digest):
        if (not isinstance(actor_id, str) or re.fullmatch('[A-Za-z0-9][A-Za-z0-9_.:-]{0,35}', actor_id) is None
                or not isinstance(reason_code, str) or re.fullmatch('[A-Z][A-Z0-9_]{2,99}', reason_code) is None
                or not isinstance(idempotency_key, str) or not idempotency_key.strip() or len(idempotency_key) > 128
                or type(expected_epoch) is not int or expected_epoch < 0
                or not isinstance(snapshot_digest, str) or re.fullmatch('[a-f0-9]{64}', snapshot_digest) is None):
            _error('MANUAL_CONTROL_COMMAND_INVALID', 422)
        return _digest(dict(operation=operation, actor_id=actor_id, reason_code=reason_code,
            expected_epoch=expected_epoch, snapshot_digest=snapshot_digest, configuration=self.configuration_id))

    def _replay(self, session, key, digest):
        row = session.get(WalletManualControlCommand, key)
        if row is not None:
            if row.payload_digest != digest:
                _error('MANUAL_CONTROL_IDEMPOTENCY_CONFLICT')
            return row.result

    def _expect(self, session, epoch, digest):
        current = self._snapshot(session)
        if current['epoch'] != epoch or current['snapshot_digest'] != digest:
            _error('MANUAL_CONTROL_SNAPSHOT_CONFLICT')

    def _record(self, session, *, key, digest, actor_id, reason_code, operation):
        result = self._snapshot(session)
        now = self.clock()
        session.add(WalletManualControlCommand(idempotency_key=key, payload_digest=digest,
            result=result, created_at=now))
        payload = dict(epoch=result['epoch'], reserve_version=result['reserve_version'], operation=operation)
        session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type='wallet_control', subject_id='global',
            action='wallet.manual_control.'+operation, result='SUCCESS', reason_code=reason_code,
            trace_id=_digest(key), after_data=payload, created_at=now))
        OutboxPublisher.enqueue(session, topic='wallet', event_type='wallet.manual_control.'+operation,
            aggregate_type='wallet_control', aggregate_id='global', payload=payload, now=now)
        diag.after_commit(session, 'control_committed', component='manual_control',
                          status=result['status'], reason_code='CONTROL_'+operation.upper())
        session.flush()
        return result

    def pause(self, *, actor_id, reason_code, idempotency_key, expected_epoch, snapshot_digest, authorize):
        digest = self._payload('pause', actor_id, reason_code, idempotency_key, expected_epoch, snapshot_digest)
        with self.factory.begin() as session:
            lock_budget(session)
            session.get(WalletControl, 'global', with_for_update=True)
            fresh = authorize(session)
            replay = self._replay(session, idempotency_key, digest)
            if replay is not None:
                fresh()
                return replay
            self._expect(session, expected_epoch, snapshot_digest)
            fresh()
            apply_manual_pause(session, ledger=self.ledger, actor_id=actor_id, reason_code=reason_code, now=self.clock())
            result = self._record(session, key=idempotency_key, digest=digest, actor_id=actor_id,
                reason_code=reason_code, operation='pause')
            fresh()
            return result

    def resume(self, *, monitor, actor_id, reason_code, idempotency_key, expected_epoch, snapshot_digest, authorize):
        deadline=time.monotonic()+20
        digest = self._payload('resume', actor_id, reason_code, idempotency_key, expected_epoch, snapshot_digest)
        with self.factory.begin() as session:
            lock_budget(session)
            session.get(WalletControl, 'global', with_for_update=True)
            fresh = authorize(session)
            replay = self._replay(session, idempotency_key, digest)
            fresh()
            if replay is not None:
                return replay
        def activate(session, publish):
            fresh = authorize(session)
            replay = self._replay(session, idempotency_key, digest)
            if replay is not None:
                fresh()
                return replay
            if time.monotonic()>=deadline:
                _evidence_unavailable('MANUAL_CONTROL_PROOF_DEADLINE')
            self._expect(session, expected_epoch, snapshot_digest)
            self.incidents.require_resolved_in_session(session, allow_backing_advisory=self.reserve_policy == 'manual_liquidity')
            control = session.get(WalletControl, 'global')
            safety = session.get(WalletSafetyState, 'global')
            state = session.get(WalletManualControlState, 'global')
            if session.scalar(select(WalletSafetyState.id).where(WalletSafetyState.id != 'global',
                    WalletSafetyState.restricted.is_(True)).limit(1)):
                _error('MANUAL_CONTROL_OTHER_SAFETY_RESTRICTION')
            if control is None or control.withdrawals_paused and (state is None or not state.owns_pause
                    or control.pause_reason != state.pause_reason):
                _error('MANUAL_CONTROL_PAUSE_SOURCE_UNKNOWN')
            if safety is not None and safety.restricted and (state is None or not state.owns_safety
                    or safety.epoch != state.safety_epoch or safety.reason != state.safety_reason):
                _error('MANUAL_CONTROL_SAFETY_SOURCE_UNKNOWN')
            if (session.scalar(select(ManualPayoutOrder.id).where(ManualPayoutOrder.status.in_(('CLAIMED', 'UNKNOWN'))).limit(1))
                    or session.scalar(select(Withdrawal.id).where(Withdrawal.status.in_(('SUBMITTING', 'PROVIDER_SUBMITTED', 'UNKNOWN'))).limit(1))):
                _error('MANUAL_CONTROL_UNRESOLVED_PAYOUT')
            restrictions = self.ledger.restriction_snapshot(session=session)
            epoch = next((row['epoch'] for row in restrictions if row['scope'] == 'manual_tron' and row['active']), None)
            fresh()
            self.ledger.release_manual_restriction(session=session, actor_id=actor_id, reason_code=reason_code,
                expected_epoch=epoch)
            control.withdrawals_paused, control.pause_reason = False, None
            if safety is not None and safety.restricted:
                safety.restricted, safety.epoch = False, safety.epoch+1
            if state is None:
                state = WalletManualControlState(id='global', epoch=1, owns_pause=False, owns_safety=False, updated_at=self.clock())
                session.add(state)
            else:
                state.epoch += 1
                state.owns_pause, state.owns_safety, state.updated_at = False, False, self.clock()
            publish(actor_id=actor_id, idempotency_key='manual-control:'+_digest(idempotency_key))
            result = self._record(session, key=idempotency_key, digest=digest, actor_id=actor_id,
                reason_code=reason_code, operation='resume')
            fresh()
            if time.monotonic()>=deadline:
                _evidence_unavailable('MANUAL_CONTROL_PROOF_DEADLINE')
            return result
        reason='MANUAL_CONTROL_PROOF_DEADLINE'
        for attempt in range(21):
            if time.monotonic()>=deadline:
                break
            result = monitor.activate_once(on_activate=activate)
            if result.get('complete'):
                return result['result']
            codes=result.get('codes')
            reason=codes[0] if isinstance(codes,list) and len(codes)==1 and isinstance(codes[0],str) else 'MANUAL_CONTROL_PROOF_REJECTED'
            if (result.get('status'),reason) not in _TRANSIENT_ACTIVATION:
                break
            if attempt==20 or deadline-time.monotonic()<1:
                break
            time.sleep(1)
        _evidence_unavailable(reason)
