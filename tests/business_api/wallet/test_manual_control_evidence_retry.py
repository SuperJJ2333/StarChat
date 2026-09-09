from types import SimpleNamespace
import pytest
from sqlalchemy import select,func
from app.core.errors import AppError
from app.modules.wallet.funding_scan_models import WalletFundingScanState
from app.modules.wallet.manual_control_models import WalletManualControlCommand
from app.modules.ledger.manual_reserve_models import ManualReserveEvaluation
from test_manual_control import core,monitor,coverage,control,args  # noqa: F401

def prepare(core,monitor,monkeypatch,catch_up=True):
    import app.modules.wallet.manual_control as module
    service=control(core,monitor)
    service.pause(**args(service,'pause'))
    command=args(service,'resume')
    elapsed=[0.0];sleeps=[]
    with core[1].begin() as session:
        session.get(WalletFundingScanState,'global').checkpoint_ms-=30000
    def sleep(seconds):
        from app.modules.wallet.monitor_lock import monitor_scan_lock
        with monitor_scan_lock(core[1]) as acquired:assert acquired
        assert service.status()['snapshot_digest']==command['snapshot_digest']
        elapsed[0]+=seconds;sleeps.append(seconds)
        if catch_up:
            with core[1].begin() as session:
                session.get(WalletFundingScanState,'global').checkpoint_ms=monitor[1].value.checkpoint_ms
    monkeypatch.setattr(module,'time',SimpleNamespace(monotonic=lambda:elapsed[0],sleep=sleep),raising=False)
    return service,command,elapsed,sleeps

def test_real_activation_retries_coverage_without_invalidating_owner_snapshot(core,monitor,monkeypatch):
    service,command,elapsed,sleeps=prepare(core,monitor,monkeypatch)
    result=service.resume(monitor=monitor[0],**command)
    assert result['status']=='RUNNING' and sleeps==[1]
    assert service.resume(monitor=monitor[0],**command)==result
    with core[1]() as session:
        assert session.scalar(select(func.count()).select_from(ManualReserveEvaluation))==1

def test_real_activation_persistent_lag_is_bounded_and_keeps_pause(core,monitor,monkeypatch):
    service,command,elapsed,sleeps=prepare(core,monitor,monkeypatch,False)
    with pytest.raises(AppError) as error:service.resume(monitor=monitor[0],**command)
    assert error.value.code=='MANUAL_CONTROL_EVIDENCE_UNAVAILABLE'
    assert len(sleeps)>1 and elapsed[0]<=20
    assert error.value.fields[0].msg=='MANUAL_COVERAGE_PENDING'
    assert service.status()['withdrawals_paused']
    with core[1]() as session:assert session.get(WalletManualControlCommand,'resume') is None

def test_activation_late_commit_rolls_back_publication_and_release(core,monitor,monkeypatch):
    service,command,elapsed,sleeps=prepare(core,monitor,monkeypatch)
    original=service._record
    def record(*a,**kw):
        result=original(*a,**kw);elapsed[0]=21;return result
    monkeypatch.setattr(service,'_record',record)
    with pytest.raises(AppError):service.resume(monitor=monitor[0],**command)
    assert service.status()['withdrawals_paused']
    with core[1]() as session:
        assert session.get(WalletManualControlCommand,'resume') is None
        assert session.scalar(select(func.count()).select_from(ManualReserveEvaluation))==0

def test_first_manual_liquidity_advisory_does_not_invalidate_its_own_resume(core,monitor):
    from test_independent_policy_controls import policy_control
    from app.modules.wallet.incident_models import WalletIncident
    service=policy_control(core,monitor)
    service.pause(**args(service,'pause'))
    result=service.resume(monitor=monitor[0],**args(service,'resume'))
    assert result['status']=='RUNNING'
    with core[1]() as session:
        warning=session.scalar(select(WalletIncident).where(WalletIncident.code=='MANUAL_BACKING_DEFICIT'))
        assert warning is not None and warning.condition_active

def test_wait_does_not_refresh_expired_authorization(core,monitor,monkeypatch):
    service,command,elapsed,sleeps=prepare(core,monitor,monkeypatch)
    def authorize(session):
        def fresh():
            if elapsed[0]>0:raise AppError(code='EXPIRED_AUTH',message='EXPIRED_AUTH',status_code=403)
        fresh();return fresh
    command['authorize']=authorize
    with pytest.raises(AppError,match='EXPIRED_AUTH'):service.resume(monitor=monitor[0],**command)
    assert service.status()['withdrawals_paused']

def test_wait_preserves_snapshot_conflict_from_new_owner_pause(core,monitor,monkeypatch):
    import app.modules.wallet.manual_control as module
    service,command,elapsed,sleeps=prepare(core,monitor,monkeypatch)
    old_sleep=module.time.sleep
    def sleep(seconds):
        old_sleep(seconds)
        service.pause(**args(service,'new-owner-pause'))
    monkeypatch.setattr(module.time,'sleep',sleep)
    with pytest.raises(AppError,match='SNAPSHOT_CONFLICT'):service.resume(monitor=monitor[0],**command)
    assert service.status()['withdrawals_paused']
