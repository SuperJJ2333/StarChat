from dataclasses import replace
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from importlib.util import find_spec

import pytest
from coincurve import PrivateKey
from sqlalchemy import create_engine, select, func

from app.core.database import Base, create_session_factory
from app.integrations.tron.finality import SolidHead, TransferEvidence, TransactionEvidence
from app.integrations.tron.message_signature import address_from_public_key
from app.modules.wallet.binding_models import WalletAddressOwner, WalletBinding, WalletBindingState
from app.modules.wallet.funding import DepositIntentService, OfficialFundingConfig
from app.modules.wallet.funding_models import DepositIntent
from app.modules.wallet.models import WalletControl, Deposit, WalletLedgerTransaction
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.wallet.safety import usdt_liability
from app.modules.identity.models import User, AccountStatus


def test_receipt_service_exists():
    assert find_spec('app.modules.wallet.receipts') is not None, 'trusted receipt ingestion missing'


@pytest.fixture
def core():
    from app.modules.wallet.receipts import DepositReceiptService
    from app.modules.wallet.receipt_models import DepositReceipt
    engine = create_engine('sqlite://')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    source, official = [address_from_public_key(PrivateKey().public_key.format(compressed=False)) for _ in range(2)]
    with factory.begin() as s:
        s.add(WalletControl(id='global', withdrawals_paused=True))
        s.add(User(id='alice', username='alice', username_normalized='alice', email='a@example.test',
            email_normalized='a@example.test', password_hash='fixture-only', status=AccountStatus.ACTIVE,
            created_at=now, updated_at=now))
        s.add(WalletAddressOwner(address=source, user_id='alice', created_at=now))
        s.flush()
        s.add(WalletBinding(id='binding', user_id='alice', address=source, version=1, status='ACTIVE',
            created_at=now, activated_at=now, effective_from_block=101, barrier_height=100,
            barrier_block_id='a'*64, barrier_source_ids=['fixture'], barrier_observed_at=now))
        s.add(WalletBindingState(user_id='alice', version=1, active_binding_id='binding'))
        s.add(RedeemabilityReserve(id='global', eligible_usdt=1000, usdt_liability=0, version=1,
            pending_payouts=0, outgoing_restricted=False, observed_at=now))
    config = OfficialFundingConfig(official, 'fixture-v1')
    intents = DepositIntentService(factory, official_config=config, intent_ttl=timedelta(minutes=20), clock=lambda: now)
    ms = int((now + timedelta(seconds=1)).timestamp()*1000)
    transfer = TransferEvidence('b'*64, 0, 102, 'c'*64, ms, source, official, 10_000_000)
    evidence = TransactionEvidence('b'*64, 102, 'c'*64, ms, SolidHead(103, 'd'*64, ms+1000, now), (transfer,), now)
    class Adapter:
        value = evidence
        def transaction_evidence(self, txid):
            assert txid == self.value.txid
            return self.value
    adapter = Adapter()
    service = DepositReceiptService(factory, finality_adapter=adapter, official_config=config,
        activation_baseline_time=now-timedelta(seconds=1), activation_baseline_height=100, clock=lambda: now+timedelta(seconds=3))
    yield service, factory, adapter, intents, DepositReceipt, now
    engine.dispose()


def intent(c, amount='10.000000'):
    return c[3].create(user_id='alice', expected_amount=amount, expected_binding_version=1, idempotency_key='fixture')


def ingest(c):
    return c[0].ingest(c[2].value.txid, actor_id='receipt-worker')


def test_verified_receipt_credits_once_under_explicit_manual_liquidity_policy(core):
    core[0].reserve_policy = core[0].wallet_ledger.reserve_policy = 'manual_liquidity'
    with core[1].begin() as s:
        s.get(RedeemabilityReserve, 'global').eligible_usdt = Decimal('1')
    intent(core)
    first = ingest(core)
    assert first[0]['status'] == 'CREDITED'
    assert ingest(core)[0]['id'] == first[0]['id']
    assert core[0].wallet_ledger.balance('alice') == Decimal('10')
    with core[1]() as s:
        assert usdt_liability(s) == Decimal('10')
        assert s.get(RedeemabilityReserve, 'global').eligible_usdt == Decimal('1')


@pytest.mark.parametrize('amount,status', [('9.999999','REVIEW'), ('10.000000','CREDITED'), ('10.000001','CREDITED')])
def test_exact_amount_and_liability(core, amount, status):
    if Decimal(amount) >= 10:
        intent(core, amount)
    core[2].value = replace(core[2].value, transfers=(replace(core[2].value.transfers[0], amount_units=int(Decimal(amount)*1000000)),))
    assert ingest(core)[0]['status'] == status
    assert ingest(core)[0]['status'] == status
    with core[1]() as s:
        assert usdt_liability(s) == Decimal(amount)
        assert s.get(RedeemabilityReserve, 'global').usdt_liability == Decimal(amount)
        assert s.scalar(select(func.count()).select_from(core[4])) == 1
        assert s.scalar(select(func.count()).select_from(WalletLedgerTransaction)) == (status == 'CREDITED')


@pytest.mark.parametrize('change', ['amount','block'])
def test_changed_evidence_quarantined(core, change):
    intent(core)
    ingest(core)
    t = core[2].value.transfers[0]
    core[2].value = replace(core[2].value, transfers=(replace(t, **({'amount_units':11_000_000} if change=='amount' else {'block_id':'e'*64})),))
    assert ingest(core)[0]['status'] == 'QUARANTINED'
    with core[1]() as s:
        assert s.scalar(select(core[4])).amount == Decimal('10')
        assert s.scalar(select(func.count()).select_from(WalletLedgerTransaction)) == 1


@pytest.mark.parametrize('second,credited', [(10_000_000,0),(11_000_000,1)])
def test_batch_same_intent_never_arbitrarily_credits(core, second, credited):
    intent(core)
    t = core[2].value.transfers[0]
    core[2].value = replace(core[2].value, transfers=(t, replace(t, log_index=1, amount_units=second)))
    rows=ingest(core)
    assert sum(r['status']=='CREDITED' for r in rows) == credited
    with core[1]() as s:
        assert usdt_liability(s) == Decimal(10) + Decimal(second)/1000000


@pytest.mark.parametrize('gate', ['missing','stale','coverage','expired','rebind','historical','source','self','contract','network','unknown_user','legacy'])
def test_fail_closed_retains_review(core, gate):
    first=intent(core)
    t=core[2].value.transfers[0]
    with core[1].begin() as s:
        if gate=='missing': s.delete(s.get(RedeemabilityReserve,'global'))
        if gate=='stale': s.get(RedeemabilityReserve,'global').observed_at=core[5]-timedelta(minutes=5)
        if gate=='coverage': s.get(RedeemabilityReserve,'global').eligible_usdt=0
        if gate=='expired':
            row=s.get(DepositIntent,first['id']); row.status='EXPIRED'; row.closed_at=core[5]
        if gate=='rebind': core[3].close_by_rebind(s,user_id='alice',binding_id='binding',binding_version=1,actor_id='alice')
        if gate=='unknown_user': s.delete(s.get(User,'alice'))
        if gate=='legacy': s.add(Deposit(id='legacy',event_id='legacy',txid=t.txid,user_id='alice',amount=10,confirmations=20,status='CREDITED',created_at=core[5]))
    if gate=='historical': core[0].activation_baseline_height=200
    if gate=='source': t=replace(t,from_address=address_from_public_key(PrivateKey().public_key.format(compressed=False)))
    if gate=='self': t=replace(t,from_address=t.to_address)
    if gate=='contract': t=replace(t,contract='wrong-contract')
    core[2].value=replace(core[2].value,transfers=(t,), **({'network':'wrong-network'} if gate=='network' else {}))
    rows=ingest(core)
    assert not any(r['status']=='CREDITED' for r in rows)
    with core[1]() as s:
        assert s.scalar(select(func.count()).select_from(WalletLedgerTransaction)) == 0
        assert usdt_liability(s) == (0 if gate in {'self','contract','network'} else 10)


def test_audit_failure_rolls_back_everything(core, monkeypatch):
    from app.modules.wallet import receipts
    intent(core)
    def fail(*args): raise RuntimeError('audit unavailable')
    monkeypatch.setattr(receipts,'audit_write',fail)
    with pytest.raises(RuntimeError,match='audit unavailable'): ingest(core)
    with core[1]() as s:
        assert s.scalar(select(core[4])) is None
        assert s.scalar(select(WalletLedgerTransaction)) is None
        assert s.scalar(select(DepositIntent)).status=='OPEN'
        assert s.get(RedeemabilityReserve,'global').usdt_liability==0


def test_quarantine_persists_on_original_evidence_replay(core):
    intent(core)
    original=core[2].value
    ingest(core)
    core[2].value=replace(original,transfers=(replace(original.transfers[0],amount_units=11_000_000),))
    ingest(core)
    core[2].value=original
    assert ingest(core)[0]['status']=='QUARANTINED'


def test_fulfilled_snapshot_cannot_be_reopened(core):
    first=intent(core)
    ingest(core)
    with pytest.raises(ValueError,match='immutable deposit intent'):
        with core[1].begin() as s:
            row=s.get(DepositIntent,first['id']); row.status='OPEN'; row.closed_at=None


@pytest.mark.parametrize('units', [10**30, -1, 10.1])
def test_unrepresentable_amount_preserves_facts_and_blocks_reserve(core, units):
    core[2].value=replace(core[2].value,transfers=(replace(core[2].value.transfers[0],amount_units=units),))
    assert ingest(core)[0]['reason_code']=='AMOUNT_UNREPRESENTABLE'
    with core[1]() as s:
        row=s.scalar(select(core[4]))
        assert row.amount_units==str(units)
        assert row.amount is None
        assert s.get(RedeemabilityReserve,'global').observed_at.year==1970


def test_reserve_failure_after_post_rolls_back_credit_savepoint(core):
    from app.modules.wallet.service import WalletLedger
    intent(core)
    class RejectAfterPosting(WalletLedger):
        def post(self, **kwargs):
            super().post(**kwargs)
            raise ValueError('insufficient reserve coverage')
    core[0].wallet_ledger=RejectAfterPosting(core[1])
    assert ingest(core)[0]['status']=='REVIEW'
    with core[1]() as s:
        assert s.scalar(select(WalletLedgerTransaction)) is None
        assert s.scalar(select(DepositIntent)).status=='OPEN'
        assert usdt_liability(s)==10
        assert s.get(RedeemabilityReserve,'global').usdt_liability==10


def test_missing_binding_state_is_review(core):
    intent(core)
    with core[1].begin() as s:
        s.delete(s.get(WalletBindingState,'alice'))
    assert ingest(core)[0]['status']=='REVIEW'


def test_legacy_overlap_never_hides_additional_log_obligation(core):
    from app.modules.wallet.service import WalletLedger
    WalletLedger(core[1]).post(entries={'alice':Decimal(10),'PLATFORM_CUSTODY':Decimal(-10)},
        actor_id='fixture',reason_code='LEGACY_FIXTURE',idempotency_key='legacy',scope='fixture')
    t=core[2].value.transfers[0]
    with core[1].begin() as s:
        s.add(Deposit(id='legacy',event_id='legacy',txid=t.txid,user_id='alice',amount=10,
            confirmations=20,status='CREDITED',created_at=core[5]))
    core[2].value=replace(core[2].value,transfers=(t,replace(t,log_index=1,amount_units=20_000_000)))
    assert all(row['status']=='REVIEW' for row in ingest(core))
    with core[1]() as s:
        assert usdt_liability(s)==40
        assert s.get(RedeemabilityReserve,'global').usdt_liability==40


@pytest.mark.parametrize('change', ['destination', 'missing_log'])
def test_recorded_event_cannot_disappear_from_official_filter(core, change):
    from app.modules.wallet.receipt_models import DepositReceiptAnomaly
    intent(core)
    original=core[2].value
    assert ingest(core)[0]['status']=='CREDITED'
    if change=='destination':
        other=address_from_public_key(PrivateKey().public_key.format(compressed=False))
        core[2].value=replace(original,transfers=(replace(original.transfers[0],to_address=other),))
    else:
        core[2].value=replace(original,transfers=())
    assert ingest(core)[0]['status']=='QUARANTINED'
    assert ingest(core)[0]['status']=='QUARANTINED'
    with core[1]() as s:
        row=s.scalar(select(core[4]))
        assert row.official_address==original.transfers[0].to_address
        assert row.status=='CREDITED'
        assert s.scalar(select(func.count()).select_from(DepositReceiptAnomaly))==1
        assert s.scalar(select(func.count()).select_from(WalletLedgerTransaction))==1
        assert s.get(RedeemabilityReserve,'global').observed_at.year==1970
        assert usdt_liability(s)==10
    core[2].value=original
    assert ingest(core)[0]['status']=='QUARANTINED'


def test_new_nonofficial_transfer_still_ignored(core):
    t=core[2].value.transfers[0]
    other=address_from_public_key(PrivateKey().public_key.format(compressed=False))
    core[2].value=replace(core[2].value,transfers=(replace(t,to_address=other),))
    assert ingest(core)==[]
    with core[1]() as s:
        assert s.scalar(select(core[4])) is None
        assert usdt_liability(s)==0


def test_liability_sum_retains_all_numeric30_digits():
    from app.modules.wallet.safety import exact_wallet_liability
    largest=Decimal('999999999999999999999999.999999')
    assert exact_wallet_liability([('alice', largest)], Decimal('0.000001'), Decimal('0.000001')) == Decimal('1000000000000000000000000.000001')


def test_reserve_liability_overflow_invalidates_without_writing_overflow(core):
    from app.modules.ledger.wallet_obligations import synchronize_wallet_liability
    with core[1].begin() as s:
        synchronize_wallet_liability(s,total=Decimal('1000000000000000000000000.000000'))
    with core[1]() as s:
        reserve=s.get(RedeemabilityReserve,'global')
        assert reserve.usdt_liability==0
        assert reserve.observed_at.year==1970


def test_ledger_decimal_exception_keeps_observation_and_blocks_issuance(core):
    from decimal import InvalidOperation
    from app.modules.wallet.service import WalletLedger
    intent(core)
    class UnsupportedPrecision(WalletLedger):
        def post(self, **kwargs):
            super().post(**kwargs)
            raise InvalidOperation('fixture unsupported precision')
    core[0].wallet_ledger=UnsupportedPrecision(core[1])
    result=ingest(core)[0]
    assert result['status']=='REVIEW'
    assert result['reason_code']=='LEDGER_PRECISION_UNSUPPORTED'
    with core[1]() as s:
        assert s.scalar(select(core[4])).amount==10
        assert s.scalar(select(DepositIntent)).status=='OPEN'
        assert s.scalar(select(WalletLedgerTransaction)) is None
        assert usdt_liability(s)==10
        assert s.get(RedeemabilityReserve,'global').observed_at.year==1970


def test_public_pending_transfer_preserves_large_decimal_fraction(monkeypatch):
    from types import SimpleNamespace
    from app.modules.ledger import wallet_obligations
    now=datetime.now(timezone.utc)
    reserve=SimpleNamespace(usdt_liability=Decimal('99999999999999999999999.123456'),observed_at=now,version=1)
    monkeypatch.setattr(wallet_obligations,'lock_budget',lambda session: reserve)
    monkeypatch.setattr(wallet_obligations,'require_coverage',lambda *args, **kwargs: None)
    wallet_obligations.transfer_pending_to_credit(None,amount=Decimal(10),now=now)
    assert reserve.usdt_liability==Decimal('99999999999999999999989.123456')


def test_financial_savepoint_preserves_large_liability_roundtrip(core):
    from app.modules.wallet.service import WalletLedger
    intent(core)
    observed=[]
    class LargeLiabilityProbe(WalletLedger):
        def post(self, **kwargs):
            liability=Decimal('99999999999999999999999.123456')
            observed.append((liability-Decimal(10))+Decimal(10))
            return super().post(**kwargs)
    core[0].wallet_ledger=LargeLiabilityProbe(core[1])
    assert ingest(core)[0]['status']=='CREDITED'
    assert observed==[Decimal('99999999999999999999999.123456')]


def financial_snapshot(core):
    from app.core.outbox import OutboxEvent
    from app.modules.audit.models import AuditEvent
    from app.modules.wallet.receipt_models import DepositReceiptAnomaly
    with core[1]() as s:
        reserve = s.get(RedeemabilityReserve, 'global')
        return (reserve.version, reserve.observed_at, reserve.usdt_liability,
                *(s.scalar(select(func.count()).select_from(model)) for model in
                  (core[4], WalletLedgerTransaction, DepositReceiptAnomaly, AuditEvent, OutboxEvent)))


@pytest.mark.parametrize('status', ['CREDITED', 'REVIEW'])
def test_duplicate_receipt_has_no_financial_write(core, status):
    if status == 'CREDITED':
        intent(core)
    assert ingest(core)[0]['status'] == status
    before = financial_snapshot(core)
    assert ingest(core)[0]['status'] == status
    assert financial_snapshot(core) == before


def test_ignored_transaction_has_no_financial_write(core):
    transfer = core[2].value.transfers[0]
    core[2].value = replace(core[2].value, transfers=(replace(transfer, to_address=transfer.from_address),))
    before = financial_snapshot(core)
    assert ingest(core) == []
    assert financial_snapshot(core) == before


@pytest.mark.parametrize('change', ['amount', 'destination', 'missing_log'])
def test_conflict_invalidates_once_with_audit_and_replay_has_no_write(core, change):
    intent(core)
    original = core[2].value
    assert ingest(core)[0]['status'] == 'CREDITED'
    before = financial_snapshot(core)
    transfer = original.transfers[0]
    changed = (() if change == 'missing_log' else
               (replace(transfer, **({'amount_units': 11_000_000} if change == 'amount'
                                     else {'to_address': transfer.from_address})),))
    core[2].value = replace(original, transfers=changed)
    assert ingest(core)[0]['status'] == 'QUARANTINED'
    after = financial_snapshot(core)
    assert after[0] == before[0] + 1
    assert after[1].year == 1970
    assert after[2:5] == before[2:5]
    assert after[5:] == tuple(count + 1 for count in before[5:])
    assert ingest(core)[0]['status'] == 'QUARANTINED'
    assert financial_snapshot(core) == after
    core[2].value = original
    assert ingest(core)[0]['status'] == 'QUARANTINED'
    assert financial_snapshot(core) == after


def test_new_receipt_updates_liability_and_audit(core):
    assert ingest(core)[0]['status'] == 'REVIEW'
    before = financial_snapshot(core)
    transfer = core[2].value.transfers[0]
    core[2].value = replace(core[2].value, transfers=(transfer, replace(transfer, log_index=1)))
    assert len(ingest(core)) == 2
    after = financial_snapshot(core)
    assert after[0] == before[0] + 1
    assert after[1] == before[1]
    assert after[2] == Decimal(20)
    assert after[3] == before[3] + 1
    assert after[4:6] == before[4:6]
    assert after[6:] == tuple(count + 1 for count in before[6:])


def test_same_liability_synchronization_has_no_write(core):
    from app.modules.ledger.wallet_obligations import synchronize_wallet_liability
    ingest(core)
    before = financial_snapshot(core)
    with core[1].begin() as s:
        synchronize_wallet_liability(s, total=Decimal(10))
    assert financial_snapshot(core) == before


def test_repeated_overflow_does_not_reinvalidate_reserve(core):
    from app.modules.ledger.wallet_obligations import synchronize_wallet_liability
    with core[1].begin() as s:
        synchronize_wallet_liability(s, total=Decimal('1000000000000000000000000'))
    before = financial_snapshot(core)
    with core[1].begin() as s:
        synchronize_wallet_liability(s, total=Decimal('1000000000000000000000000'))
    assert financial_snapshot(core) == before
