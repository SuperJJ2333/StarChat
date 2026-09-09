"""Synthetic chain fixtures; no real monitored wallet addresses."""
import hashlib
import importlib
import json

import httpx
import pytest


def address(byte):
    raw = bytes.fromhex('41' + byte * 20)
    raw += hashlib.sha256(hashlib.sha256(raw).digest()).digest()[:4]
    alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
    number, result = int.from_bytes(raw, 'big'), ''
    while number:
        number, remainder = divmod(number, 58)
        result = alphabet[remainder] + result
    return result


ACCOUNT, OTHER = address('11'), address('22')
TXID = 'ab' * 32
TRANSFER = 'ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'
CONTRACT_HEX = 'a614f803b6fd780986a42c78ec9c7f77e6ded13c'


def module():
    from app.integrations import tron
    assert hasattr(tron, 'TronReader'), 'read-only TRON adapter is not implemented'
    return importlib.import_module('app.integrations.tron.reader')


def transfer(amount=1234567):
    return {'address': CONTRACT_HEX, 'topics': [TRANSFER, '0' * 24 + '22' * 20,
            '0' * 24 + '11' * 20], 'data': f'{amount:064x}'}


def receipt():
    return {'id': TXID, 'blockNumber': 100, 'blockTimeStamp': 1500,
            'receipt': {'result': 'SUCCESS'}, 'log': [
                {'address': CONTRACT_HEX, 'topics': ['00' * 32], 'data': ''},
                transfer(), transfer(2)]}


class Chain:
    def __init__(self):
        self.receipt = receipt()
        self.pages = [{'success': True, 'data': [{'transaction_id': TXID}], 'meta': {}}]
        self.heads = [110, 110]
        self.requests = []
        self.balance = {'result': {'result': True}, 'constant_result': [f'{9000000:064x}']}
        self.error = None

    def respond(self, request):
        self.requests.append(request)
        if self.error:
            raise self.error
        path = request.url.path
        if path.endswith('/getnowblock'):
            height = self.heads.pop(0)
            result = {'blockID': f'{height:064x}', 'block_header': {'raw_data': {
                'number': height, 'timestamp': 2000}}}
        elif '/transactions/trc20' in path:
            result = self.pages.pop(0)
        elif path.endswith('/gettransactioninfobyid'):
            result = self.receipt
        elif path.endswith('/triggerconstantcontract'):
            result = self.balance
        else:
            pytest.fail(f'unexpected endpoint {path}')
        return httpx.Response(200, json=result)

    def reader(self, **kwargs):
        return module().TronReader(client=httpx.Client(transport=httpx.MockTransport(self.respond)), **kwargs)


def test_receipt_is_authoritative_and_real_log_indices_preserved():
    chain = Chain()
    result = chain.reader().snapshot(ACCOUNT, 1000, 2000)
    assert result == {'events': [dict(txid=TXID, log_index=i, block_number=100,
        timestamp_ms=1500, from_address=OTHER, to_address=ACCOUNT, amount_units=amount)
        for i, amount in [(1, 1234567), (2, 2)]], 'balance_units': 9000000,
        'solid_block': 110, 'solid_timestamp_ms': 2000, 'stable_balance': True}
    history = next(r for r in chain.requests if r.method == 'GET')
    assert history.url.params['only_confirmed'] == 'true'
    assert history.url.params['min_timestamp'] == '1000'
    assert history.url.params['max_timestamp'] == '2000'
    constant = json.loads(chain.requests[-2].content)
    assert constant['function_selector'] == 'balanceOf(address)'
    assert constant['parameter'] == '0' * 24 + '11' * 20


def test_pagination_and_duplicate_transaction_fetch_once():
    chain = Chain()
    chain.pages = [{'success': True, 'data': [{'transaction_id': TXID}],
                    'meta': {'fingerprint': 'cursor-A'}},
                   {'success': True, 'data': [{'transaction_id': TXID}], 'meta': {}}]
    result = chain.reader().snapshot(ACCOUNT, 1000, 2000)
    assert len(result['events']) == 2
    gets = [r for r in chain.requests if r.method == 'GET']
    assert gets[1].url.params['fingerprint'] == 'cursor-A'
    assert sum(r.url.path.endswith('/gettransactioninfobyid') for r in chain.requests) == 1


@pytest.mark.parametrize('mutation', [
    lambda r: r['receipt'].update(result='REVERT'),
    lambda r: r.update(id='cd' * 32),
    lambda r: r.update(blockNumber=111),
    lambda r: r.update(blockTimeStamp=999),
    lambda r: r['log'][1].update(data='not-hex'),
    lambda r: r['log'][1].update(topics=[TRANSFER, 'f' * 64, '0' * 24 + '11' * 20]),
    lambda r: r.update(log='invalid'),
])
def test_rejects_unverifiable_receipt(mutation):
    chain = Chain()
    mutation(chain.receipt)
    with pytest.raises(module().TronReadError):
        chain.reader().snapshot(ACCOUNT, 1000, 2000)


def test_wrong_contract_logs_never_create_events():
    chain = Chain()
    for log in chain.receipt['log']:
        log['address'] = '33' * 20
    with pytest.raises(module().TronReadError):
        chain.reader().snapshot(ACCOUNT, 1000, 2000)


@pytest.mark.parametrize('page', [
    {'success': False, 'data': [], 'meta': {}},
    {'success': True, 'data': None, 'meta': {}},
    {'success': True, 'data': [{'transaction_id': 'bad'}], 'meta': {}},
    {'success': True, 'data': [], 'meta': {'fingerprint': 123}},
])
def test_bad_history_fails_closed(page):
    chain = Chain()
    chain.pages = [page]
    with pytest.raises(module().TronReadError):
        chain.reader().snapshot(ACCOUNT, 1000, 2000)


def test_repeated_cursor_and_page_cap_fail_closed():
    for cap in [1, 5]:
        chain = Chain()
        chain.pages = [{'success': True, 'data': [{'transaction_id': TXID}],
                        'meta': {'fingerprint': 'repeat'}}] * 2
        with pytest.raises(module().TronReadError):
            chain.reader(max_pages=cap).snapshot(ACCOUNT, 1000, 2000)


def test_moving_head_makes_balance_unverified():
    chain = Chain()
    chain.pages *= 3
    chain.heads = [110, 111, 111, 112, 112, 113]
    assert chain.reader().snapshot(ACCOUNT, 1000, 2000)['stable_balance'] is False


def test_snapshot_retries_changed_head_with_a_complete_new_observation():
    chain = Chain()
    chain.pages *= 2
    chain.heads = [110, 111, 111, 111]
    result = chain.reader().snapshot(ACCOUNT, 1000, 2000)
    assert result['stable_balance'] is True
    assert result['solid_block'] == 111
    assert len([r for r in chain.requests if r.url.path.endswith('triggerconstantcontract')]) == 2
    assert len(result['events']) == 2


def test_snapshot_rejects_head_regression_between_attempts():
    chain = Chain()
    chain.heads = [110, 112, 111, 111]
    with pytest.raises(module().TronReadError, match='regressed'):
        chain.reader().snapshot(ACCOUNT, 1000, 2000)


@pytest.mark.parametrize('requested_end, expected_end', [(2050, 2050), (3000, 2100)])
def test_retry_rebuilds_events_and_balance_using_original_requested_window(requested_end, expected_end):
    chain = Chain()
    chain.heads = [110, 111, 111, 111]
    chain.pages.append({'success': True, 'data': [], 'meta': {}})
    head_reads, balance_reads = 0, 0
    def respond(request):
        nonlocal head_reads, balance_reads
        response = chain.respond(request)
        payload = response.json()
        if request.url.path.endswith('/getnowblock'):
            head_reads += 1
            payload['block_header']['raw_data']['timestamp'] = 2000 if head_reads == 1 else 2100
        if request.url.path.endswith('/triggerconstantcontract'):
            balance_reads += 1
            payload['constant_result'] = [f'{9000000 if balance_reads == 1 else 8000000:064x}']
        return httpx.Response(200, json=payload)
    reader = module().TronReader(client=httpx.Client(transport=httpx.MockTransport(respond)))
    result = reader.snapshot(ACCOUNT, 1000, requested_end)
    assert result['stable_balance'] is True
    assert result['events'] == []
    assert result['balance_units'] == 8000000
    windows = [int(r.url.params['max_timestamp']) for r in chain.requests if r.method == 'GET']
    assert windows == [2000, expected_end]


def test_retry_does_not_reset_original_total_deadline(monkeypatch):
    clock = [100.0]
    monkeypatch.setattr(module().time, 'monotonic', lambda: clock[0])
    chain = Chain()
    chain.heads = [110, 111, 111, 111]
    chain.pages *= 2
    def respond(request):
        clock[0] += 1
        return chain.respond(request)
    reader = module().TronReader(client=httpx.Client(transport=httpx.MockTransport(respond)), max_scan_seconds=6)
    with pytest.raises(module().TronReadError, match='deadline'):
        reader.snapshot(ACCOUNT, 1000, 2000)
    assert len(chain.requests) == 6


@pytest.mark.parametrize('position', ['within', 'between'])
@pytest.mark.parametrize('conflict', ['blockID', 'timestamp'])
def test_retry_cannot_forget_same_height_solid_head_conflict(position, conflict):
    chain = Chain()
    chain.heads = [110, 110, 110, 110] if position == 'within' else [110, 111, 111, 111]
    chain.pages *= 2
    head_reads = 0
    def respond(request):
        nonlocal head_reads
        payload = chain.respond(request).json()
        if request.url.path.endswith('/getnowblock'):
            head_reads += 1
            if head_reads >= (2 if position == 'within' else 3):
                if conflict == 'blockID':
                    payload['blockID'] = 'ff' * 32
                else:
                    payload['block_header']['raw_data']['timestamp'] += 1
        return httpx.Response(200, json=payload)
    reader = module().TronReader(client=httpx.Client(transport=httpx.MockTransport(respond)))
    with pytest.raises(module().TronReadError, match='conflicted'):
        reader.snapshot(ACCOUNT, 1000, 2000)


def test_timeout_is_sanitized_and_constant_failure_rejected():
    chain = Chain()
    chain.error = httpx.ReadTimeout('sensitive request details')
    with pytest.raises(module().TronReadError, match='^TRON request failed$'):
        chain.reader().snapshot(ACCOUNT, 1000, 2000)
    chain = Chain()
    chain.balance['result']['result'] = False
    with pytest.raises(module().TronReadError):
        chain.reader().snapshot(ACCOUNT, 1000, 2000)


def test_address_check_rejects_bad_checksum_and_hex_input():
    assert module().validate_tron_address(ACCOUNT) == ACCOUNT
    for value in [ACCOUNT[:-1] + ('1' if ACCOUNT[-1] != '1' else '2'), '41' + '11' * 20, '', None]:
        with pytest.raises(ValueError):
            module().validate_tron_address(value)


def test_transaction_cap_stops_before_receipt_fetch():
    chain = Chain()
    chain.pages[0]['data'].append({'transaction_id': 'cd' * 32})
    with pytest.raises(module().TronReadError, match='cap'):
        chain.reader(max_transactions=1).snapshot(ACCOUNT, 1000, 2000)
    assert len(chain.requests) == 2


@pytest.mark.parametrize('status', [302, 429, 500])
def test_http_errors_and_redirects_do_not_leak_request(status):
    calls = []
    def respond(request):
        calls.append(request)
        return httpx.Response(status, headers={'location': 'https://other.invalid/path'})
    client = httpx.Client(transport=httpx.MockTransport(respond), follow_redirects=True)
    reader = module().TronReader(client=client, api_key='synthetic-token')
    with pytest.raises(module().TronReadError, match='^TRON request failed$'):
        reader.snapshot(ACCOUNT, 1000, 2000)
    assert len(calls) == 1


def test_invalid_window_never_calls_network():
    chain = Chain()
    with pytest.raises(ValueError):
        chain.reader().snapshot(ACCOUNT, 2000, 1000)
    assert not chain.requests


def test_receipt_timestamp_cannot_exceed_solid_head_timestamp():
    chain = Chain()
    chain.receipt['blockTimeStamp'] = 2500
    with pytest.raises(module().TronReadError):
        chain.reader().snapshot(ACCOUNT, 1000, 3000)


def test_history_window_is_capped_at_first_solid_head():
    chain = Chain()
    chain.reader().snapshot(ACCOUNT, 1000, 3000)
    history = next(r for r in chain.requests if r.method == 'GET')
    assert history.url.params['max_timestamp'] == '2000'


def test_window_start_after_solid_head_fails_closed():
    chain = Chain()
    with pytest.raises(module().TronReadError):
        chain.reader().snapshot(ACCOUNT, 2500, 3000)


def test_fixed_contract_has_valid_checksum_and_matches_receipt_contract():
    reader = module()
    assert reader.validate_tron_address(reader.USDT_CONTRACT) == reader.USDT_CONTRACT
    assert reader._decode_address(reader.USDT_CONTRACT).hex() == '41' + CONTRACT_HEX


def test_next_link_without_fingerprint_cannot_truncate_history():
    chain = Chain()
    chain.pages[0]['meta'] = {'links': {'next': 'https://api.trongrid.io/next'}}
    with pytest.raises(module().TronReadError):
        chain.reader().snapshot(ACCOUNT, 1000, 2000)


def test_total_scan_deadline_stops_successful_but_slow_requests(monkeypatch):
    clock = [100.0]
    monkeypatch.setattr(module().time, 'monotonic', lambda: clock[0])
    chain = Chain()
    def slow(request):
        clock[0] += 11
        return chain.respond(request)
    client = httpx.Client(transport=httpx.MockTransport(slow))
    reader = module().TronReader(client=client, max_scan_seconds=20)
    with pytest.raises(module().TronReadError, match='deadline'):
        reader.snapshot(ACCOUNT, 1000, 2000)
    assert len(chain.requests) == 2


@pytest.mark.parametrize('seconds', [0, -1, float('inf'), float('nan'), True, 301])
def test_invalid_scan_budget_is_rejected(seconds):
    with pytest.raises(ValueError):
        module().TronReader(max_scan_seconds=seconds)
