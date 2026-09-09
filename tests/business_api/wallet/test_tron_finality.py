"""Single-provider assertions only; every HTTP response is synthetic."""
from copy import deepcopy
from dataclasses import FrozenInstanceError
from datetime import datetime, timezone
import importlib.util
import json

import httpx
import pytest

TX = 'a' * 64
NOW = datetime(2026, 9, 7, tzinfo=timezone.utc)
MS = int(NOW.timestamp() * 1000)
CONTRACT = 'a614f803b6fd780986a42c78ec9c7f77e6ded13c'
TOPIC = 'ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'


def module():
    assert importlib.util.find_spec('app.integrations.tron.finality'), 'single-source adapter missing'
    from app.integrations.tron import finality
    return finality


def block(height=100, timestamp=MS-1000, identity='b'):
    return {'blockID': identity * 64, 'block_header': {'raw_data': {
        'number': height, 'timestamp': timestamp}}, 'transactions': [{'txID': TX}]}


def log(amount=10000000):
    return {'address': CONTRACT, 'topics': [TOPIC, '0'*24+'1'*40, '0'*24+'2'*40],
            'data': f'{amount:064x}'}


def fixture(receipt=None, heads=None, mined=None, status=200):
    api = module()
    receipt = deepcopy(receipt) if receipt is not None else {
        'id': TX, 'receipt': {'result': 'SUCCESS'}, 'blockNumber': 99,
        'blockTimeStamp': MS-2000, 'log': [log()]}
    heads = iter(heads or [block(), block()])
    calls = []
    def handle(request):
        calls.append(request)
        assert request.method == 'POST'
        assert request.url.host == 'api.trongrid.io'
        path = request.url.path
        if path == '/walletsolidity/getnowblock':
            value = next(heads)
        elif path == '/walletsolidity/getblockbynum':
            assert json.loads(request.content) == {'num': receipt['blockNumber']}
            value = mined or block(99, MS-2000, 'c')
        else:
            assert path == '/walletsolidity/gettransactioninfobyid'
            assert json.loads(request.content) == {'value': TX}
            value = receipt
        return httpx.Response(status, json=value)
    adapter = api.TronGridFinality(base_url='https://api.trongrid.io',
        transport=httpx.MockTransport(handle), clock=lambda: NOW, max_age_seconds=60)
    return api, adapter, calls


def test_single_source_frozen_complete_evidence_and_read_only_endpoints():
    api, adapter, calls = fixture()
    result = adapter.transaction_evidence(TX)
    assert result.policy == 'TRONGRID_SINGLE_SOURCE_V1'
    assert result.source_id == 'trongrid-mainnet'
    assert result.network == 'tron-mainnet'
    assert result.observed_at == NOW
    assert result.solid_head.height == 100
    assert result.block_id == 'c'*64
    assert result.transfers[0].amount_units == 10000000
    assert result.transfers[0].txid == TX
    assert result.transfers[0].log_index == 0
    assert len(calls) == 4
    with pytest.raises(FrozenInstanceError):
        result.source_id = 'independent'


@pytest.mark.parametrize('change', [
    {}, {'id': 'd'*64}, {'receipt': {}}, {'receipt': {'result': 'FAILED'}},
    {'blockNumber': True}, {'blockNumber': 101}, {'blockTimeStamp': MS},
    {'log': [None]}, {'log': [dict(log(), data='bad')]},
    {'log': [dict(log(), topics=[TOPIC, 'f'*64, '0'*64])]},
    {'log': [dict(log(), topics=[TOPIC])]}, {'log': None},
])
def test_unavailable_never_terminal_failure(change):
    receipt = {'id': TX, 'receipt': {'result': 'SUCCESS'}, 'blockNumber': 99,
               'blockTimeStamp': MS-2000, 'log': [log()]}
    if change:
        receipt.update(change)
    else:
        receipt = {}
    api, adapter, _ = fixture(receipt)
    with pytest.raises(api.TronEvidenceUnavailable):
        adapter.transaction_evidence(TX)


@pytest.mark.parametrize('heads', [
    [block(timestamp=MS-61000)], [block(timestamp=MS+1)],
    [block(), block(99)], [block(), block(identity='d')],
    [block(), block(timestamp=MS-2000)], [block(height=True)],
])
def test_stale_future_regressing_or_conflicting_head_unavailable(heads):
    api, adapter, _ = fixture(heads=heads)
    with pytest.raises(api.TronEvidenceUnavailable):
        adapter.transaction_evidence(TX)


def test_actual_indexes_and_identical_transfers_are_distinct_events():
    receipt = {'id': TX, 'receipt': {'result': 'SUCCESS'}, 'blockNumber': 99,
               'blockTimeStamp': MS-2000,
               'log': [dict(log(), address='3'*40), log(9999999), log(9999999), log(10000001)]}
    _, adapter, _ = fixture(receipt)
    transfers = adapter.transaction_evidence(TX).transfers
    assert [x.log_index for x in transfers] == [1, 2, 3]
    assert [x.amount_units for x in transfers] == [9999999, 9999999, 10000001]


@pytest.mark.parametrize('mined', [block(98, MS-2000), block(99, MS-3000),
                                     dict(block(99, MS-2000), transactions=[])])
def test_receipt_bound_to_matching_block(mined):
    api, adapter, _ = fixture(mined=mined)
    with pytest.raises(api.TronEvidenceUnavailable):
        adapter.transaction_evidence(TX)


def test_solid_head_and_age_boundary():
    _, adapter, _ = fixture(heads=[block(timestamp=MS-60000)])
    assert adapter.solid_head().timestamp_ms == MS-60000


@pytest.mark.parametrize('origin', ['http://api.trongrid.io', 'https://evil.test',
    'https://api.trongrid.io@evil.test', 'https://api.trongrid.io/path',
    'https://api.trongrid.io:444', 'https://api.trongrid.io?secret=x'])
def test_fixed_mainnet_origin(origin):
    with pytest.raises(ValueError):
        module().TronGridFinality(base_url=origin, clock=lambda: NOW, max_age_seconds=60)


def test_http_errors_are_sanitized():
    api, adapter, _ = fixture(status=401)
    with pytest.raises(api.TronEvidenceUnavailable) as error:
        adapter.transaction_evidence(TX)
    assert TX not in str(error.value)
    assert 'https' not in str(error.value)


@pytest.mark.parametrize('response', [
    httpx.Response(302, headers={'Location': 'https://evil.test/secret'}),
    httpx.Response(200, content=b'x'*2_000_001),
    httpx.Response(200, content=b'not json'),
    httpx.Response(200, json=[]),
    httpx.Response(200, json={'Error': 'sensitive upstream details'}),
])
def test_bounded_transport_and_sanitized_invalid_responses(response):
    api = module()
    calls = []
    def handle(request):
        calls.append(request)
        assert request.extensions['timeout']['read'] <= 10
        return response
    adapter = api.TronGridFinality(base_url='https://api.trongrid.io',
        transport=httpx.MockTransport(handle), clock=lambda: NOW, max_age_seconds=60)
    with pytest.raises(api.TronEvidenceUnavailable) as error:
        adapter.solid_head()
    assert len(calls) == 1
    assert 'sensitive' not in str(error.value)
    assert 'secret' not in str(error.value)
    adapter.close()


def test_timeout_error_does_not_expose_url_or_api_key():
    api = module()
    def handle(request):
        raise httpx.ReadTimeout('sensitive secret address', request=request)
    adapter = api.TronGridFinality(base_url='https://api.trongrid.io',
        transport=httpx.MockTransport(handle), clock=lambda: NOW, max_age_seconds=60)
    with pytest.raises(api.TronEvidenceUnavailable) as error:
        adapter.solid_head()
    assert str(error.value) == 'TRON request unavailable'
    assert error.value.__suppress_context__


def test_wrong_contract_returns_no_creditable_logs():
    receipt = {'id': TX, 'receipt': {'result': 'SUCCESS'}, 'blockNumber': 99,
               'blockTimeStamp': MS-2000, 'log': [dict(log(), address='3'*40)]}
    _, adapter, _ = fixture(receipt)
    assert adapter.transaction_evidence(TX).transfers == ()


@pytest.mark.parametrize('age', [True, 0, -1, 301, float('nan'), float('inf')])
def test_invalid_age_configuration(age):
    with pytest.raises(ValueError):
        module().TronGridFinality(base_url='https://api.trongrid.io',
                                 clock=lambda: NOW, max_age_seconds=age)


def test_transaction_block_at_head_requires_same_id():
    receipt = {'id': TX, 'receipt': {'result': 'SUCCESS'}, 'blockNumber': 100,
               'blockTimeStamp': MS-1000, 'log': [log()]}
    api, adapter, _ = fixture(receipt, mined=block(100, MS-1000, 'd'))
    with pytest.raises(api.TronEvidenceUnavailable):
        adapter.transaction_evidence(TX)


def test_advancing_solid_head_is_accepted():
    _, adapter, _ = fixture(heads=[block(), block(101, MS, 'd')])
    assert adapter.transaction_evidence(TX).solid_head.height == 101


def test_log_cap():
    receipt = {'id': TX, 'receipt': {'result': 'SUCCESS'}, 'blockNumber': 99,
               'blockTimeStamp': MS-2000, 'log': [{}]*10001}
    api, adapter, _ = fixture(receipt)
    with pytest.raises(api.TronEvidenceUnavailable):
        adapter.transaction_evidence(TX)
