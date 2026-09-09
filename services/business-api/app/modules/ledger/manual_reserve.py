"""Trusted wallet monitor gateway; caller owns the transaction and source cut.

The wallet monitor recomputes wallet liabilities under the same budget lock.
This gateway verifies coverage and publishes only successful observations.
"""
from collections.abc import Mapping
from datetime import datetime, timedelta, timezone
from decimal import Decimal, localcontext
import hashlib
import json
import re
from uuid import uuid4

from sqlalchemy import select

from app.core.outbox import OutboxPublisher
from app.modules.audit.models import AuditEvent
from app.modules.ledger.manual_reserve_models import ManualReserveEvaluation
from app.modules.ledger.reserve import RedeemabilityReserve, caibi_liability, lock_budget

_MAX_INT = 2**63 - 1
_EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


def _integer(value, *, minimum=0, maximum=_MAX_INT):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError('invalid reserve integer')
    return value


def _amount(value):
    if not isinstance(value, Decimal) or not value.is_finite() or value < 0 or value >= Decimal('1e24'):
        raise ValueError('invalid reserve decimal')
    with localcontext() as ctx:
        ctx.prec = 50
        if value != value.quantize(Decimal('0.000001')):
            raise ValueError('invalid reserve decimal precision')
        return value.quantize(Decimal('0.000001'))


def _aware(value):
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise ValueError('aware reserve timestamp required')
    return value.astimezone(timezone.utc)


def _stored_aware(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def _source_evidence(value, observed):
    allowed = {'max_rowid', 'checkpoint_ms', 'solid_block', 'heartbeat_ms', 'fresh_until_ms', 'balance_units', 'healthy'}
    if not isinstance(value, Mapping) or set(value) != allowed:
        raise ValueError('invalid reserve evidence')
    if not {'heartbeat_ms', 'fresh_until_ms', 'healthy'}.issubset(value) or value['healthy'] is not True:
        raise ValueError('invalid reserve evidence health')
    result = dict(value)
    for key, item in result.items():
        if key == 'healthy':
            continue
        if key == 'balance_units':
            if isinstance(item, str) and re.fullmatch('[0-9]{1,78}', item):
                item = int(item)
            _integer(item, maximum=2**256-1)
            result[key] = str(item)
        else:
            _integer(item)
    source_ms = result['fresh_until_ms'] - 120000
    delta = observed - _EPOCH
    observed_us = (delta.days * 86400 + delta.seconds) * 1000000 + delta.microseconds
    if observed_us != source_ms * 1000 or source_ms > result['heartbeat_ms']:
        raise ValueError('reserve observation differs from source freshness')
    return result


def publish_manual_reserve(session, *, expected_version, eligible_usdt, usdt_liability,
                           pending_payouts, observed_at, now, source_identity, observation_id,
                           cut_digest, evidence, actor_id, idempotency_key, policy='full_backing'):
    """Publish atomically; exact replay excludes retry clock and never refreshes.

    The caller must roll back its transaction on any error. Staged caller facts
    are flushed only after taking the budget lock, before checking liabilities.
    """
    if policy not in {'full_backing', 'manual_liquidity'}:
        raise ValueError('invalid reserve policy')
    reserve = lock_budget(session)
    session.flush()
    if reserve is not None:
        session.refresh(reserve, with_for_update=True)
    if expected_version is not None:
        _integer(expected_version, minimum=1, maximum=_MAX_INT-1)
    _integer(pending_payouts)
    _integer(observation_id, minimum=1)
    for digest in (source_identity, cut_digest):
        if not isinstance(digest, str) or re.fullmatch('[0-9a-f]{64}', digest) is None:
            raise ValueError('invalid reserve source digest')
    if not isinstance(actor_id, str) or re.fullmatch('[A-Za-z0-9][A-Za-z0-9_.:-]{0,35}', actor_id) is None:
        raise ValueError('invalid reserve actor')
    if not isinstance(idempotency_key, str) or not 1 <= len(idempotency_key) <= 128:
        raise ValueError('invalid reserve idempotency key')
    eligible, liability = _amount(eligible_usdt), _amount(usdt_liability)
    observed, clock = _aware(observed_at), _aware(now)
    source_cut = _source_evidence(evidence, observed)
    canonical_cut = dict(source_cut, source_identity=source_identity, observation_id=observation_id)
    canonical_cut['balance_units'] = int(canonical_cut['balance_units'])
    actual_cut_digest = hashlib.sha256(json.dumps(canonical_cut, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    if actual_cut_digest != cut_digest:
        raise ValueError('reserve source cut digest mismatch')
    with localcontext() as ctx:
        ctx.prec = 80
        if eligible != Decimal(canonical_cut['balance_units']) / Decimal(1000000):
            raise ValueError('reserve source balance mismatch')
    payload = dict(expected_version=expected_version, eligible_usdt=format(eligible, 'f'),
        usdt_liability=format(liability, 'f'), pending_payouts=pending_payouts,
        observed_at=observed.isoformat(), source_identity=source_identity,
        observation_id=observation_id, cut_digest=cut_digest, source_cut=source_cut, actor_id=actor_id)
    if policy == 'manual_liquidity':
        payload['reserve_policy'] = policy
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    previous = session.scalar(select(ManualReserveEvaluation).where(
        ManualReserveEvaluation.idempotency_key == idempotency_key))
    if previous is not None:
        if previous.payload_digest != digest:
            raise ValueError('reserve idempotency conflict')
        return previous
    if not timedelta(0) <= clock - observed <= timedelta(seconds=120):
        raise ValueError('reserve evidence stale or future')
    if (None if reserve is None else reserve.version) != expected_version:
        raise ValueError('reserve version changed')
    if pending_payouts != (0 if reserve is None else reserve.pending_payouts) or pending_payouts:
        raise ValueError('reserve pending payout mismatch or unresolved')
    if reserve is not None and observed < _stored_aware(reserve.observed_at):
        raise ValueError('reserve observation regressed')
    item = session.scalar(select(ManualReserveEvaluation).where(
        ManualReserveEvaluation.source_identity == source_identity)
        .order_by(ManualReserveEvaluation.result_version.desc()).limit(1))
    if item is not None:
        if observation_id < item.observation_id or observed < _aware(datetime.fromisoformat(item.evidence['observed_at'])):
            raise ValueError('reserve source observation regressed')
        if any(source_cut[key] < item.evidence['source_cut'][key]
               for key in ('max_rowid', 'checkpoint_ms', 'solid_block')):
            raise ValueError('reserve source progress regressed')
    with localcontext() as ctx:
        ctx.prec = 80
        caibi = caibi_liability(session)
        if policy == 'full_backing' and eligible < liability + caibi:
            raise ValueError('insufficient reserve coverage')
        payload['caibi_liability'] = format(caibi, 'f')
        if policy == 'manual_liquidity':
            payload['backing_deficit'] = format(max(Decimal('0'), liability + caibi - eligible), 'f')
    version = 1 if reserve is None else reserve.version + 1
    evaluation = ManualReserveEvaluation(id=str(uuid4()), idempotency_key=idempotency_key,
        payload_digest=digest, source_identity=source_identity, observation_id=observation_id,
        cut_digest=cut_digest, expected_version=expected_version, result_version=version,
        evidence=payload, created_at=clock)
    if reserve is None:
        reserve = RedeemabilityReserve(id='global', pending_payouts=0, outgoing_restricted=False)
        session.add(reserve)
    reserve.eligible_usdt, reserve.usdt_liability = eligible, liability
    reserve.observed_at, reserve.version = observed, version
    session.add(evaluation)
    event_payload = dict(evaluation_id=evaluation.id, version=version, source_identity=source_identity,
                         observation_id=observation_id, cut_digest=cut_digest)
    session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type='manual_reserve',
        subject_id='global', action='manual_reserve.publish', result='SUCCESS',
        reason_code='MANUAL_RESERVE_PUBLISHED', trace_id=hashlib.sha256(idempotency_key.encode()).hexdigest(),
        before_data={'version': expected_version}, after_data=event_payload, created_at=clock))
    OutboxPublisher.enqueue(session, topic='ledger', event_type='manual_reserve.published',
        aggregate_type='manual_reserve', aggregate_id='global', payload=event_payload, now=clock)
    session.flush()
    return evaluation
