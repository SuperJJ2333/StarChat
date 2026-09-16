"""Owner transfer declarations: the only compliant record for owner-initiated outflows.

ADR-0071. An unexplained on-chain outflow must keep blocking the manual wallet;
a declaration turns an already-executed owner payment into a covered, immutable
business fact so review and recovery can proceed.
"""
import hashlib
import json
from decimal import Decimal

import pytest
from sqlalchemy import select, func

from app.core.errors import AppError
from app.modules.identity.models import User, UserRole, AccountStatus
from app.modules.identity.enums import RoleCode
from app.modules.wallet import manual_deposit_cases  # noqa: F401  (FK target tables must register first)
from app.modules.wallet.funding_scan_models import WalletFundingScanItem, WalletFundingScanState
from app.modules.wallet.safety import usdt_liability
from test_deposit_receipts import core, intent  # noqa: F401
from test_funding_coverage import coverage, register, verify  # noqa: F401
from test_manual_reserve_monitor import monitor, digest_cut  # noqa: F401

TX = '9' * 64
TARGET = 'T' + 'Y' * 33


def ok(session):
    return lambda: None


def owner_outflow(core, coverage, monitor, *, txid=TX, amount_units=2_000000, to_address=TARGET):
    from app.integrations.tron.finality import NETWORK, USDT_CONTRACT, POLICY, SOURCE_ID
    source = monitor[1]
    facts = dict(txid=txid, log_index=0, amount_units=str(amount_units),
        from_address=monitor[0].config.address, to_address=to_address,
        block_number=102, timestamp_ms=core[2].value.timestamp_ms)
    rowid = source.value.max_rowid + 1
    with core[1].begin() as s:
        s.add(coverage[2](id=txid[:36], source_identity=source.source_identity, source_rowid=rowid,
            **facts, facts_digest='a' * 64, status='VERIFIED', created_at=monitor[2][0], verified_at=monitor[2][0],
            proof=dict(network=NETWORK, contract=USDT_CONTRACT, policy=POLICY, source_id=SOURCE_ID,
                block_id='c' * 64,
                transaction_facts_digest=hashlib.sha256(json.dumps([facts], sort_keys=True).encode()).hexdigest())))
        s.add(WalletFundingScanItem(txid=txid, state='PROCESSED', discovered_rowid=rowid,
            attempts=1, created_at=monitor[2][0], updated_at=monitor[2][0]))
        state = s.get(WalletFundingScanState, 'global')
        state.cursor_rowid = state.source_max_rowid = rowid
    source.value = digest_cut(source.value, max_rowid=rowid)


def owner_adapter(core, monitor, *, txid=TX, amount_units=2_000000, to_address=TARGET):
    from app.integrations.tron.finality import TransactionEvidence, TransferEvidence, SolidHead
    now = monitor[2][0]
    ms = int(now.timestamp() * 1000)
    transfer = TransferEvidence(txid, 0, 102, 'c' * 64, core[2].value.timestamp_ms,
        monitor[0].config.address, to_address, amount_units)
    evidence = TransactionEvidence(txid, 102, 'c' * 64, core[2].value.timestamp_ms,
        SolidHead(104, 'd' * 64, ms, now), (transfer,), now)

    class Adapter:
        def transaction_evidence(self, value):
            assert value == txid
            return evidence
    return Adapter()


@pytest.fixture
def owner(core):
    with core[1].begin() as s:
        s.add(User(id='owner', username='owner', username_normalized='owner', email='owner@example.test',
            email_normalized='owner@example.test', password_hash='fixture', status=AccountStatus.ACTIVE,
            created_at=core[5], updated_at=core[5]))
        s.add(UserRole(id='owner-role', user_id='owner', role_code=RoleCode.SUPER_ADMIN,
            assigned_by='fixture', assigned_at=core[5]))


@pytest.fixture
def service(core, coverage, monitor, owner):
    from app.modules.wallet.owner_transfers import OwnerTransferService
    return OwnerTransferService(core[1], ledger=core[0].wallet_ledger, finality_adapter=owner_adapter(core, monitor),
        official_config=coverage[0].config, owner_admin_id='owner', clock_trusted=lambda: True,
        clock=lambda: monitor[2][0])


def preview(service, **changes):
    payload = dict(actor_id='owner', txid=TX, log_index=0, reason_code='OWNER_TEST_DRAW',
        reason_detail='fixture owner draw', ownership_attested=True, authorize=ok)
    payload.update(changes)
    return service.preview(**payload)


def execute(service, **changes):
    payload = dict(actor_id='owner', txid=TX, log_index=0, reason_code='OWNER_TEST_DRAW',
        reason_detail='fixture owner draw', ownership_attested=True, authorize=ok, idempotency_key='ot-1')
    payload.update(changes)
    return service.execute(**payload)


def test_declared_owner_transfer_releases_review_and_blocks_before_declaration(core, coverage, monitor, service):
    owner_outflow(core, coverage, monitor)
    assert monitor[0].run_once()['codes'] == ['MANUAL_UNALLOCATED_OUTFLOW']
    result = monitor[0]._scan(review_only=True, on_review=lambda s: None)
    assert result['codes'] == ['MANUAL_UNALLOCATED_OUTFLOW']

    snapshot = preview(service)
    assert snapshot['blockers'] == []
    assert snapshot['to_address'] == TARGET
    assert snapshot['amount_units'] == '2000000'
    record = execute(service)
    assert record['status'] == 'DECLARED'
    assert execute(service)['id'] == record['id']

    assert monitor[0].run_once()['codes'] == ['MANUAL_WALLET_PAUSED']
    assert monitor[0].review_once(on_review=lambda s: None)['status'] == 'REVIEWED'
    with core[1]() as s:
        from app.modules.wallet.owner_transfer_models import WalletManualOwnerTransfer
        assert s.scalar(select(func.count()).select_from(WalletManualOwnerTransfer)) == 1


def test_declaration_posts_balanced_ledger_without_touching_liability(core, coverage, monitor, service):
    owner_outflow(core, coverage, monitor)
    with core[1]() as s:
        before = usdt_liability(s)
    execute(service)
    assert core[0].wallet_ledger.balance('PLATFORM_OWNER_DRAWING') == Decimal('-2.000000')
    assert core[0].wallet_ledger.balance('PLATFORM_CUSTODY') == Decimal('2.000000')
    with core[1]() as s:
        assert usdt_liability(s) == before


def test_undeclared_outflow_still_blocks(core, coverage, monitor):
    owner_outflow(core, coverage, monitor, txid='8' * 64)
    assert monitor[0].run_once()['codes'] == ['MANUAL_UNALLOCATED_OUTFLOW']


def test_replay_with_different_payload_is_conflict(core, coverage, monitor, service):
    owner_outflow(core, coverage, monitor)
    execute(service)
    with pytest.raises(AppError) as exc:
        execute(service, reason_detail='changed')
    assert exc.value.code == 'IDEMPOTENCY_CONFLICT'


def test_non_owner_cannot_declare(core, coverage, monitor, service):
    owner_outflow(core, coverage, monitor)
    with pytest.raises(AppError) as exc:
        preview(service, actor_id='alice')
    assert exc.value.code == 'PERMISSION_DENIED'


def test_missing_ownership_attestation_is_rejected(core, coverage, monitor, service):
    owner_outflow(core, coverage, monitor)
    with pytest.raises(AppError) as exc:
        preview(service, ownership_attested=False)
    assert exc.value.code == 'OWNERSHIP_ATTESTATION_REQUIRED'


def test_untrusted_clock_is_rejected(core, coverage, monitor, owner):
    from app.modules.wallet.owner_transfers import OwnerTransferService
    guarded = OwnerTransferService(core[1], ledger=core[0].wallet_ledger, finality_adapter=owner_adapter(core, monitor),
        official_config=coverage[0].config, owner_admin_id='owner', clock_trusted=lambda: False,
        clock=lambda: monitor[2][0])
    owner_outflow(core, coverage, monitor)
    with pytest.raises(AppError) as exc:
        preview(guarded)
    assert exc.value.code == 'CLOCK_UNTRUSTED'


def test_unknown_log_index_is_reported_as_blocker(core, coverage, monitor, service):
    owner_outflow(core, coverage, monitor)
    assert 'TRANSFER_NOT_FOUND' in preview(service, log_index=1)['blockers']


def test_already_allocated_payout_blocks_declaration(core, coverage, monitor, service):
    from datetime import timedelta
    from app.modules.wallet.manual_payout_models import ManualPayoutEvent
    from app.integrations.tron.finality import NETWORK, USDT_CONTRACT, POLICY, SOURCE_ID
    owner_outflow(core, coverage, monitor)
    now = monitor[2][0]
    with core[1].begin() as s:
        s.add(ManualPayoutEvent(id='fixture-evt', order_id='none', network=NETWORK, contract=USDT_CONTRACT,
            txid=TX, log_index=0, created_at=now,
            evidence=dict(policy=POLICY, source_id=SOURCE_ID, block_id='c' * 64, block_number=102,
                timestamp_ms=core[2].value.timestamp_ms, amount_units=2_000000)))
    assert 'EVENT_ALREADY_ALLOCATED' in preview(service)['blockers']
    with pytest.raises(AppError) as exc:
        execute(service)
    assert exc.value.code == 'EVENT_ALREADY_ALLOCATED'


def test_missing_coverage_fact_blocks_declaration(core, coverage, monitor, service):
    snapshot = preview(service)
    assert 'COVERAGE_FACT_MISSING' in snapshot['blockers']
    with pytest.raises(AppError) as exc:
        execute(service)
    assert exc.value.code == 'COVERAGE_FACT_MISSING'


def test_liability_formula_excludes_owner_drawing_account(core):
    from app.modules.wallet.service import WalletLedger
    assert 'PLATFORM_OWNER_DRAWING' in _excluded_accounts()


def _excluded_accounts():
    import inspect
    from app.modules.wallet import service as wallet_service
    from app.modules.wallet import safety as wallet_safety
    sources = inspect.getsource(wallet_service.WalletLedger._post) + inspect.getsource(wallet_safety.usdt_liability)
    assert sources.count("'PLATFORM_OWNER_DRAWING'") >= 2, 'owner drawing account must be excluded from liability'
    return {'PLATFORM_CUSTODY', 'PLATFORM_CONVERSION', 'PLATFORM_OWNER_DRAWING'}
