"""Confirmation waits only for transient observations, never stale authorization."""
from types import SimpleNamespace

import pytest
from sqlalchemy import func, select

from app.core.errors import AppError
from app.modules.wallet.handover_models import WalletHandoverCommand, WalletIncidentHandoverDisposition
from app.modules.wallet.models import WalletSafetyState
from test_legacy_handover import handover, common, notified  # noqa: F401


def setup(handover, monkeypatch, on_sleep=None):
    import app.modules.wallet.handover as module
    prepared = notified(handover)
    elapsed, sleeps = [0.0], []
    def sleep(seconds):
        from app.modules.wallet.monitor_lock import monitor_scan_lock
        with monitor_scan_lock(handover[1]) as acquired:
            assert acquired, 'monitor lock must be released before waiting'
        with handover[1]() as session:
            assert not session.connection().connection.driver_connection.in_transaction
        sleeps.append(seconds)
        elapsed[0] += seconds
        if on_sleep:
            on_sleep()
    monkeypatch.setattr(module, 'time', SimpleNamespace(monotonic=lambda: elapsed[0], sleep=sleep), raising=False)
    args = dict(preparation_id=prepared['id'], manifest_digest=prepared['manifest_digest'],
        no_unregistered_payments=True, notice_received=True, **common('confirm'))
    return elapsed, sleeps, args


@pytest.mark.parametrize('status,code', [('WAITING','MANUAL_SOURCE_PENDING'),
    ('WAITING','MANUAL_COVERAGE_PENDING'), ('RETRY','MONITOR_SCAN_BUSY'),
    ('RETRY','MANUAL_SOURCE_CHANGED'), ('RETRY','MANUAL_RESERVE_CHANGED')])
def test_transient_confirmation_retries_full_proof_and_commits_once(handover, monkeypatch, status, code):
    elapsed, sleeps, args = setup(handover, monkeypatch)
    service = handover[0]
    original = service.monitor.handover_review_once
    calls = []
    def review(*, on_review):
        calls.append(on_review)
        if len(calls) <= 2:
            return dict(complete=False, status=status, codes=[code])
        return original(on_review=on_review)
    monkeypatch.setattr(service.monitor, 'handover_review_once', review)
    result = service.confirm(**args)
    assert result['status'] == 'HANDOVER_COMPLETE_FUNDS_PAUSED'
    assert sleeps == [1, 1] and all(callback is calls[0] for callback in calls)
    assert service.confirm(**args) == result
    assert len(calls) == 3
    with handover[1]() as session:
        assert session.get(WalletHandoverCommand, 'confirm') is not None
        assert session.scalar(select(func.count()).select_from(WalletIncidentHandoverDisposition)) == 3


def test_pending_wait_has_total_deadline_and_safe_reason(handover, monkeypatch):
    elapsed, sleeps, args = setup(handover, monkeypatch)
    calls = []
    def review(**kwargs):
        calls.append(1)
        return dict(complete=False, status='WAITING', codes=['MANUAL_SOURCE_PENDING'])
    monkeypatch.setattr(handover[0].monitor, 'handover_review_once', review)
    with pytest.raises(AppError) as rejected:
        handover[0].confirm(**args)
    assert rejected.value.code == 'HANDOVER_EVIDENCE_UNAVAILABLE'
    assert 1 < len(calls) <= 21 and elapsed[0] <= 20
    assert all(value == 1 for value in sleeps)
    assert rejected.value.fields[0].msg == 'MANUAL_SOURCE_PENDING'


@pytest.mark.parametrize('status,codes', [('BLOCKED',['MANUAL_COVERAGE_CONFLICT']),
    ('WAITING',['PRIVATE_PROVIDER_SECRET']), ('WAITING',['MANUAL_SOURCE_PENDING','MANUAL_COVERAGE_CONFLICT'])])
def test_permanent_or_unknown_failure_never_retries_or_leaks_details(handover, monkeypatch, status, codes):
    elapsed, sleeps, args = setup(handover, monkeypatch)
    monkeypatch.setattr(handover[0].monitor, 'handover_review_once',
        lambda **kwargs: dict(complete=False, status=status, codes=codes))
    with pytest.raises(AppError) as rejected:
        handover[0].confirm(**args)
    assert rejected.value.code == 'HANDOVER_EVIDENCE_UNAVAILABLE'
    assert sleeps == []
    assert 'PRIVATE_PROVIDER_SECRET' not in str(rejected.value.fields)


@pytest.mark.parametrize('fault', ['authorization', 'manifest'])
def test_waiting_never_bypasses_changed_manifest_or_expired_authorization(handover, monkeypatch, fault):
    expired = [False]
    def changed():
        expired[0] = True
        if fault == 'manifest':
            with handover[1].begin() as session:
                session.get(WalletSafetyState, 'global').reason = 'CHANGED_RISK'
    elapsed, sleeps, args = setup(handover, monkeypatch, changed)
    if fault == 'authorization':
        def authorize(session):
            if expired[0]:
                raise AppError(code='AUTH_EXPIRED', message='AUTH_EXPIRED', status_code=403)
            return lambda: None
        args['authorize'] = authorize
    original = handover[0].monitor.handover_review_once
    calls = []
    def review(*, on_review):
        calls.append(1)
        if len(calls) == 1:
            return dict(complete=False, status='WAITING', codes=['MANUAL_SOURCE_PENDING'])
        return original(on_review=on_review)
    monkeypatch.setattr(handover[0].monitor, 'handover_review_once', review)
    with pytest.raises(AppError) as rejected:
        handover[0].confirm(**args)
    assert rejected.value.code == ('AUTH_EXPIRED' if fault == 'authorization' else 'HANDOVER_MANIFEST_CONFLICT')
    assert sleeps == [1]
    with handover[1]() as session:
        assert session.get(WalletHandoverCommand, 'confirm') is None
        assert session.scalar(select(func.count()).select_from(WalletIncidentHandoverDisposition)) == 0


def test_slow_full_proof_cannot_commit_after_shared_deadline(handover, monkeypatch):
    elapsed, sleeps, args = setup(handover, monkeypatch)
    original = handover[0].monitor.handover_review_once
    def review(*, on_review):
        elapsed[0] = 21
        return original(on_review=on_review)
    monkeypatch.setattr(handover[0].monitor, 'handover_review_once', review)
    with pytest.raises(AppError) as rejected:
        handover[0].confirm(**args)
    assert rejected.value.code == 'HANDOVER_EVIDENCE_UNAVAILABLE'
    with handover[1]() as session:
        assert session.get(WalletHandoverCommand, 'confirm') is None


def test_finite_attempt_cap_even_if_monotonic_clock_stalls(handover, monkeypatch):
    import app.modules.wallet.handover as module
    elapsed, sleeps, args = setup(handover, monkeypatch)
    monkeypatch.setattr(module.time, 'sleep', lambda seconds: sleeps.append(seconds))
    calls = []
    def review(**kwargs):
        calls.append(1)
        return dict(complete=False, status='RETRY', codes=['MONITOR_SCAN_BUSY'])
    monkeypatch.setattr(handover[0].monitor, 'handover_review_once', review)
    with pytest.raises(AppError) as rejected:
        handover[0].confirm(**args)
    assert rejected.value.code == 'HANDOVER_EVIDENCE_UNAVAILABLE'
    assert len(calls) == 21 and sleeps == [1] * 20


def test_deadline_crossed_by_command_write_rolls_back_all_ownership_changes(handover, monkeypatch):
    elapsed, sleeps, args = setup(handover, monkeypatch)
    original = handover[0]._command
    def command(session, row, **kwargs):
        result = original(session, row, **kwargs)
        elapsed[0] = 21
        return result
    monkeypatch.setattr(handover[0], '_command', command)
    with pytest.raises(AppError) as rejected:
        handover[0].confirm(**args)
    assert rejected.value.code == 'HANDOVER_EVIDENCE_UNAVAILABLE'
    assert rejected.value.fields[0].msg == 'HANDOVER_PROOF_DEADLINE'
    with handover[1]() as session:
        assert session.get(WalletHandoverCommand, 'confirm') is None
        assert session.get(WalletSafetyState, 'global').epoch == 1
        assert session.scalar(select(func.count()).select_from(WalletIncidentHandoverDisposition)) == 0


def test_real_monitor_coverage_lag_retries_until_worker_checkpoint_catches_up(handover, monkeypatch):
    from app.modules.wallet.funding_scan_models import WalletFundingScanState
    def catch_up():
        with handover[1].begin() as session:
            session.get(WalletFundingScanState, 'global').checkpoint_ms = handover[4].value.checkpoint_ms
    elapsed, sleeps, args = setup(handover, monkeypatch, catch_up)
    with handover[1].begin() as session:
        session.get(WalletFundingScanState, 'global').checkpoint_ms -= 30000
    # Exercise the actual handover monitor, including its rollback exception
    # mapping. A synthetic WAITING result missed this production contract.
    result = handover[0].confirm(**args)
    assert result['status'] == 'HANDOVER_COMPLETE_FUNDS_PAUSED'
    assert sleeps == [1]
    with handover[1]() as session:
        assert session.scalar(select(func.count()).select_from(WalletIncidentHandoverDisposition)) == 3


def test_real_monitor_persistent_coverage_lag_never_commits(handover, monkeypatch):
    from app.modules.wallet.funding_scan_models import WalletFundingScanState
    elapsed, sleeps, args = setup(handover, monkeypatch)
    with handover[1].begin() as session:
        session.get(WalletFundingScanState, 'global').checkpoint_ms -= 30000
    with pytest.raises(AppError) as rejected:
        handover[0].confirm(**args)
    assert rejected.value.code == 'HANDOVER_EVIDENCE_UNAVAILABLE'
    assert len(sleeps) > 1 and elapsed[0] <= 20
    with handover[1]() as session:
        assert session.scalar(select(func.count()).select_from(WalletIncidentHandoverDisposition)) == 0
        assert session.get(WalletSafetyState, 'global').epoch == 1
