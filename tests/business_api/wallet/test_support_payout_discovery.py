"""Read-only support payout candidate discovery against immutable order terms."""
from datetime import timedelta
from decimal import Decimal
from types import SimpleNamespace

import pytest

from app.core.errors import AppError
from app.integrations.tron.finality import SolidHead, TransactionEvidence, TransferEvidence
from app.integrations.tron.reader import TronReadError, USDT_CONTRACT
from test_manual_payouts import core, request
from test_support_payout import scoped
from test_manual_payouts import quote
from sqlalchemy import select
from app.modules.wallet.manual_payout_models import ManualPayoutEvent


def test_empty_reconcile_does_not_mark_unknown(scoped):
    core, service, claims = scoped
    order, lease = started(scoped)
    result = service.reconcile(claims=claims['bob'], order_id=order['id'], claim_token=lease['claim_token'])
    assert result['status'] == 'CLAIMED' and result['review_reason'] is None


@pytest.mark.parametrize('path',['manual','correction','retry','selection'])
def test_final_receipt_rejects_unallocated_event_with_overlapping_order(scoped,path):
    core, service, claims = scoped
    first, lease = started(scoped)
    from app.modules.wallet.manual_payout_models import ManualPayoutOrder, ManualPayoutQuote
    with core[1].begin() as session:
        row = session.get(ManualPayoutOrder, first['id'])
        terms = session.get(ManualPayoutQuote, row.quote_id)
        session.add(ManualPayoutQuote(id='other-quote', user_id='bob', amount=row.amount,
            snapshot=dict(terms.snapshot), digest=terms.digest, created_at=row.created_at,
            expires_at=terms.expires_at))
        session.flush()
        session.add(ManualPayoutOrder(id='other-order', quote_id='other-quote', user_id='bob',
            amount=row.amount, digest=row.digest, status='CLAIMED', claimed_by='owner',
            claimed_at=row.claimed_at, created_at=row.created_at, updated_at=row.updated_at))
    core[6].evidence = receipt(core)
    if path=='selection':
        service.discovery_reader_factory=lambda:Reader(['a'*64])
        found=service.discover(claims=claims['bob'],order_id=first['id'],claim_token=lease['claim_token'])
        assert found['candidates'][0]['evidence_status']=='AMBIGUOUS'
        with pytest.raises(AppError,match='ATTRIBUTION_AMBIGUOUS'):
            service.select_discovered(claims=claims['bob'],order_id=first['id'],claim_token=lease['claim_token'],
                txid='a'*64,log_index=0,expected_claim_version=1,idempotency_key='ambiguous-select')
        assert core[0].status(user_id='alice',order_id=first['id'])['status']=='CLAIMED'
        assert core[5].balance('HOLD:alice')==Decimal('10')
        return
    service.submit_txid(claims=claims['bob'], order_id=first['id'], claim_token=lease['claim_token'],
        txid=('d' if path=='correction' else 'a')*64, idempotency_key='overlap-txid')
    if path=='correction':
        service.correct_candidate(claims=claims['bob'],order_id=first['id'],claim_token=lease['claim_token'],
            txid='a'*64,reason_code='PAYOUT_TXID_CORRECTION',idempotency_key='overlap-correction')
    result = service.reconcile(claims=claims['bob'], order_id=first['id'], claim_token=lease['claim_token'])
    if path=='retry':
        result = service.reconcile(claims=claims['bob'], order_id=first['id'], claim_token=lease['claim_token'])
    assert result['status'] == 'UNKNOWN' and result['review_reason'] == 'ORDER_ATTRIBUTION_AMBIGUOUS'
    assert core[5].balance('HOLD:alice') == Decimal('10')
    with core[1]() as session:
        assert session.scalar(select(ManualPayoutEvent.id)) is None


def test_selection_rechecks_discovery_version_then_uses_common_settlement(scoped, monkeypatch):
    core, service, claims = scoped
    order, lease = started(scoped)
    service.discovery_reader_factory = lambda: Reader(['a'*64])
    monkeypatch.setattr(core[6], 'transaction_evidence', lambda txid: receipt(core, txid=txid))
    result = service.select_discovered(claims=claims['bob'], order_id=order['id'],
        claim_token=lease['claim_token'], txid='a'*64, log_index=0,
        expected_claim_version=1, idempotency_key='select-one')
    assert result['status'] == 'SETTLED'
    assert core[5].balance('HOLD:alice') == Decimal('0')
    replay = service.select_discovered(claims=claims['bob'], order_id=order['id'],
        claim_token=lease['claim_token'], txid='a'*64, log_index=0,
        expected_claim_version=1, idempotency_key='select-one')
    assert replay == result


class Reader:
    def __init__(self, txids=(), error=None):
        self.txids, self.error = list(txids), error
        self.calls = []
        self.closed = False

    def discover_transaction_ids(self, address, start_ms, end_ms):
        self.calls.append((address, start_ms, end_ms))
        if self.error:
            raise self.error
        return self.txids

    def close(self):
        self.closed = True


def started(scoped):
    core, service, claims = scoped
    order = request(core)
    lease = service.claim(claims=claims['bob'], order_id=order['id'],
        idempotency_key='discover-lease')
    service.begin_payment(claims=claims['bob'], order_id=order['id'],
        claim_token=lease['claim_token'], expected_digest=order['digest'],
        idempotency_key='discover-begin')
    core[2][0] += timedelta(minutes=5)
    return order, lease


def receipt(core, *, txid='a'*64, target=None, amount_units=10000000,
            source=None, contract=USDT_CONTRACT, observed_at=None):
    now = observed_at or core[2][0]
    transfer_ms = int((now-timedelta(minutes=4)).timestamp()*1000)
    head_ms = int(now.timestamp()*1000)
    transfer = TransferEvidence(txid, 0, 200, 'b'*64, transfer_ms,
        source or core[4], target or core[3], amount_units, contract)
    return TransactionEvidence(txid, 200, 'b'*64, transfer_ms,
        SolidHead(201, 'c'*64, head_ms, now), (transfer,), now)


def test_discovery_empty_and_exact_receipt_keep_order_hold_unchanged(scoped, monkeypatch):
    core, service, claims = scoped
    order, lease = started(scoped)
    token = lease['claim_token']
    empty = Reader()
    service.discovery_reader_factory = lambda: empty
    result = service.discover(claims=claims['bob'], order_id=order['id'], claim_token=token)
    assert result['status'] == 'EMPTY' and result['candidates'] == []
    assert empty.closed and len(empty.calls) == 1
    assert empty.calls[0][0] == core[4]
    assert empty.calls[0][1] < empty.calls[0][2]
    valid = Reader(['a'*64])
    service.discovery_reader_factory = lambda: valid
    monkeypatch.setattr(core[6], 'transaction_evidence', lambda txid: receipt(core, txid=txid))
    found = service.discover(claims=claims['bob'], order_id=order['id'], claim_token=token)
    assert found['status'] == 'COMPLETE' and len(found['candidates']) == 1
    candidate = found['candidates'][0]
    assert candidate['txid'] == 'a'*64 and candidate['amount'] == '10.000000'
    assert candidate['masked_target_address'].startswith(core[3][:6])
    assert candidate['evidence_status'] == 'VERIFIED'
    assert core[3] not in str(found)
    assert valid.closed
    assert core[0].status(user_id='alice', order_id=order['id'])['status'] == 'CLAIMED'
    assert core[5].balance('HOLD:alice') == Decimal('10')


@pytest.mark.parametrize('change,expected', [
    ('wrong_target', 'EMPTY'), ('wrong_source', 'EMPTY'), ('wrong_amount', 'EMPTY'),
    ('wrong_contract', 'EMPTY'), ('stale', 'INCOMPLETE'), ('provider_error', 'INCOMPLETE'),
])
def test_discovery_rejects_mismatch_and_marks_missing_proof_incomplete(scoped, monkeypatch, change, expected):
    core, service, claims = scoped
    order, lease = started(scoped)
    reader = Reader(['a'*64], TronReadError('TRON history page cap exceeded')
        if change == 'provider_error' else None)
    service.discovery_reader_factory = lambda: reader
    changes = {
        'wrong_target': {'target': core[4]},
        'wrong_source': {'source': core[3]},
        'wrong_amount': {'amount_units': 1},
        'wrong_contract': {'contract': 'wrong'},
        'stale': {'observed_at': core[2][0]-timedelta(minutes=4)},
    }
    monkeypatch.setattr(core[6], 'transaction_evidence',
        lambda txid: receipt(core, txid=txid, **changes.get(change, {})))
    result = service.discover(claims=claims['bob'], order_id=order['id'],
        claim_token=lease['claim_token'])
    assert result['status'] == expected and result['candidates'] == []
    assert reader.closed and core[5].balance('HOLD:alice') == Decimal('10')
    assert core[0].status(user_id='alice', order_id=order['id'])['status'] == 'CLAIMED'


def test_discovery_denies_unstarted_or_invalid_evidence_access_before_provider(scoped):
    core, service, claims = scoped
    order = request(core)
    lease = service.claim(claims=claims['bob'], order_id=order['id'],
        idempotency_key='prebegin-discover-lease')
    calls = []
    service.discovery_reader_factory = lambda: calls.append('opened') or Reader()
    with pytest.raises(AppError):
        service.discover(claims=claims['bob'], order_id=order['id'],
            claim_token=lease['claim_token'])
    assert calls == []
    service.begin_payment(claims=claims['bob'], order_id=order['id'],
        claim_token=lease['claim_token'], expected_digest=order['digest'],
        idempotency_key='prebegin-discover-begin')
    core[2][0] += timedelta(minutes=5)
    with pytest.raises(AppError):
        service.discover(claims=claims['bob'], order_id=order['id'], claim_token='x'*43)
    assert calls == []
    assert service.discover(claims=claims['owner'], order_id=order['id'])['status'] == 'EMPTY'
    assert calls == ['opened']


def test_discovery_receipt_returning_after_total_deadline_is_incomplete(scoped,monkeypatch):
    import app.modules.wallet.support_payout as module
    core,service,claims=scoped
    order,lease=started(scoped)
    service.discovery_reader_factory=lambda:Reader(['a'*64])
    monkeypatch.setattr(core[6],'transaction_evidence',lambda txid:receipt(core,txid=txid))
    moments=iter([0,0,21])
    monkeypatch.setattr(module.time,'monotonic',lambda:next(moments))
    result=service.discover(claims=claims['bob'],order_id=order['id'],claim_token=lease['claim_token'])
    assert result['status']=='INCOMPLETE' and result['candidates']==[]


@pytest.mark.asyncio
async def test_discovery_http_uses_server_snapshot_and_no_store(scoped):
    from fastapi import FastAPI
    from httpx import ASGITransport, AsyncClient
    from app.api.support_payout import create_support_payout_router
    from app.core.config import Settings
    from app.core.errors import install_error_handlers
    from app.modules.identity.tokens import TokenService
    core, service, claims = scoped
    settings = Settings(_env_file=None, environment='test',
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes').model_copy(update=vars(service.settings))
    tokens = TokenService(core[1], jwt_secret=settings.jwt_secret,
        jwt_issuer=settings.jwt_issuer, now_factory=lambda: core[2][0])
    pair = tokens.issue_admin_pair(user_id='bob', display_name='Browser')
    current_claims = tokens.decode_access_token(pair.access_token)
    order = request(core)
    lease = service.claim(claims=current_claims, order_id=order['id'],
        idempotency_key='http-discover-lease')
    service.begin_payment(claims=current_claims, order_id=order['id'],
        claim_token=lease['claim_token'], expected_digest=order['digest'],
        idempotency_key='http-discover-begin')
    core[2][0] += timedelta(minutes=5)
    reader = Reader()
    runtime = SimpleNamespace(payouts=core[0], payout_execution_enabled=True,
        new_discovery_reader=lambda: reader)
    app = FastAPI(); install_error_handlers(app)
    app.include_router(create_support_payout_router(settings, core[1], runtime=runtime), prefix='/api/v1')
    path = '/api/v1/admin/support-orders/payouts/'+order['id']+'/discover'
    async with AsyncClient(transport=ASGITransport(app=app), base_url='https://test') as client:
        headers = {'Authorization': 'Bearer '+pair.access_token,
            'X-Support-Claim-Token': lease['claim_token']}
        result = await client.get(path+'?address='+core[3]+'&amount=999999', headers=headers)
        assert result.status_code == 200, result.text
        assert result.headers['Cache-Control'] == 'no-store'
        assert result.json()['status'] == 'EMPTY'
        assert reader.calls[0][0] == core[4]
        assert core[3] not in result.text
