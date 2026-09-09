"""Transfer an exact proven legacy stop into tracked manual ownership, still paused."""
from sqlalchemy import select
from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.audit.writer import AuditWriter
from app.modules.ledger.handover import adopt_no_funds_legacy
from app.modules.wallet.manual_control_models import WalletManualControlState
from app.modules.wallet.models import WalletControl, WalletSafetyState


def adopt_legacy_stop(session, *, factory, actor_id, reason_code, manifest_digest, now):
    control = session.get(WalletControl, 'global', with_for_update=True)
    safety = session.get(WalletSafetyState, 'global', with_for_update=True)
    if (control is None or not control.withdrawals_paused or control.pause_reason != 'WALLET_MONITOR_SIGNAL'
            or safety is None or not safety.restricted or safety.epoch != 1 or safety.reason != 'WALLET_MONITOR_SIGNAL'
            or session.get(WalletManualControlState, 'global') is not None
            or session.scalar(select(WalletSafetyState.id).where(WalletSafetyState.id != 'global', WalletSafetyState.restricted.is_(True)).limit(1))):
        raise AppError(code='HANDOVER_RESTRICTION_CONFLICT', message='HANDOVER_RESTRICTION_CONFLICT', status_code=409)
    adopt_no_funds_legacy(session, factory=factory, actor_id=actor_id, reason_code=reason_code,
        manifest_digest=manifest_digest, now=now)
    control.pause_reason = 'LEGACY_MONITOR_HANDOVER'
    safety.reason, safety.epoch = 'LEGACY_MONITOR_HANDOVER', safety.epoch+1
    session.add(WalletManualControlState(id='global', epoch=1, owns_pause=True,
        pause_reason=control.pause_reason, owns_safety=True, safety_epoch=safety.epoch,
        safety_reason=safety.reason, updated_at=now))
    payload = dict(manifest_digest=manifest_digest, successor_scope='manual_tron', safety_epoch=safety.epoch,
        withdrawals_paused=True, global_restricted=True)
    AuditWriter(factory, now_factory=lambda: now).record_in_session(session, actor_id=actor_id,
        subject_type='wallet_control', subject_id='global', action='wallet.legacy_stop_adopted',
        result='SUCCESS', reason_code=reason_code, trace_id=manifest_digest, after=payload)
    OutboxPublisher.enqueue(session, topic='wallet', event_type='wallet.legacy_stop_adopted',
        aggregate_type='wallet_control', aggregate_id='global', payload=payload, now=now)
    return payload
