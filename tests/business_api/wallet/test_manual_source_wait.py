from datetime import timedelta
from sqlalchemy import select

from app.integrations.tron.funding_source import FundingSourcePending
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.wallet.models import WalletControl
from test_manual_reserve_monitor import core, coverage, monitor  # noqa: F401


def test_brief_unverified_sampling_waits_without_permanent_pause(core, monitor):
    service, source, clock = monitor
    started = int(clock[0].timestamp()*1000)
    def pending():
        raise FundingSourcePending(started, int(clock[0].timestamp()*1000)+120000)
    source.read_reserve_cut = pending
    assert service.run_once() == dict(complete=False, status='WAITING', codes=['MANUAL_SOURCE_PENDING'])
    with core[1]() as session:
        assert not session.get(WalletControl, 'global').withdrawals_paused
        assert session.get(RedeemabilityReserve, 'global').observed_at.year == 1970
    clock[0] += timedelta(minutes=5)
    assert service.run_once()['status'] == 'BLOCKED'
    with core[1]() as session:
        assert session.get(WalletControl, 'global').withdrawals_paused


def test_pending_source_cannot_clear_pause_or_call_review_completion(core, monitor):
    service, source, clock = monitor
    now = int(clock[0].timestamp()*1000)
    source.read_reserve_cut = lambda: (_ for _ in ()).throw(FundingSourcePending(now, now+120000))
    with core[1].begin() as session:
        session.get(WalletControl, 'global').withdrawals_paused = True
    calls = []
    assert not service.review_once(on_review=lambda session:calls.append(True))['complete']
    assert not calls
    with core[1]() as session:
        assert session.get(WalletControl, 'global').withdrawals_paused
