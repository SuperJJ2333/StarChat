"""Bounded, single-source mainnet USDT observation. Never signs or broadcasts."""
from __future__ import annotations

import hashlib
import re
import time
from urllib.parse import urlsplit

import httpx
from . import diagnostics as diag
from uuid import uuid4

USDT_CONTRACT = 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t'
_USDT_HEX = 'a614f803b6fd780986a42c78ec9c7f77e6ded13c'
_TRANSFER = 'ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'
_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
_WORD = re.compile(r'[0-9a-fA-F]{64}\Z')


class TronReadError(RuntimeError):
    """A complete, verified observation could not be obtained (safe to log)."""


def _checksum(raw: bytes) -> bytes:
    return hashlib.sha256(hashlib.sha256(raw).digest()).digest()[:4]


def _decode_address(address: str) -> bytes:
    if not isinstance(address, str) or len(address) != 34:
        raise ValueError('Invalid TRON address')
    number = 0
    for character in address:
        if character not in _ALPHABET:
            raise ValueError('Invalid TRON address')
        number = number * 58 + _ALPHABET.index(character)
    raw = number.to_bytes((number.bit_length() + 7) // 8, 'big')
    if len(raw) != 25 or raw[0] != 0x41 or _checksum(raw[:-4]) != raw[-4:]:
        raise ValueError('Invalid TRON address')
    return raw[:-4]


def validate_tron_address(address: str) -> str:
    """Accept only a canonical mainnet Base58Check address; never echo errors."""
    _decode_address(address)
    return address


def _encode_address(raw: bytes) -> str:
    number = int.from_bytes(raw + _checksum(raw), 'big')
    result = ''
    while number:
        number, remainder = divmod(number, 58)
        result = _ALPHABET[remainder] + result
    return result


def _integer(value: object) -> int:
    if type(value) is not int or value < 0:
        raise TronReadError('Malformed TRON integer')
    return value


def _word(value: object) -> str:
    if not isinstance(value, str) or _WORD.fullmatch(value) is None:
        raise TronReadError('Malformed TRON ABI word')
    return value.lower()


class TronReader:
    def __init__(self, base_url: str = 'https://api.trongrid.io', api_key: str | None = None,
                 client: httpx.Client | None = None, *, max_pages: int = 100,
                 max_transactions: int = 10000, max_scan_seconds: float = 60):
        url = urlsplit(base_url)
        if url.scheme != 'https' or not url.netloc or url.username or url.password or url.query or url.fragment:
            raise ValueError('TRON endpoint must be an HTTPS origin')
        if url.path not in ('', '/'):
            raise ValueError('TRON endpoint must be an HTTPS origin')
        if type(max_pages) is not int or not 1 <= max_pages <= 1000:
            raise ValueError('Invalid page cap')
        if type(max_transactions) is not int or not 1 <= max_transactions <= 100000:
            raise ValueError('Invalid transaction cap')
        if type(max_scan_seconds) not in (int, float) or not 0 < max_scan_seconds <= 300:
            raise ValueError('Invalid scan deadline')
        self.base_url = base_url.rstrip('/')
        self._headers = {'TRON-PRO-API-KEY': api_key} if api_key else {}
        self._client = client or httpx.Client(timeout=20.0, follow_redirects=False)
        self._owns_client = client is None
        self.max_pages = max_pages
        self.max_transactions = max_transactions
        self.max_scan_seconds = max_scan_seconds
        self._deadline: float | None = None

    def close(self) -> None:
        if self._owns_client:
            self._client.close()

    def _request(self, method: str, path: str, **kwargs) -> dict:
        started = time.monotonic()
        stage = {'/walletsolidity/getnowblock': 'head',
                 '/walletsolidity/triggerconstantcontract': 'balance',
                 '/walletsolidity/gettransactioninfobyid': 'receipt'}.get(path, 'unknown')
        if path.startswith('/v1/accounts/') and path.endswith('/transactions/trc20'):
            stage = 'history'
        context = dict(stage=stage, request_id=uuid4().hex)
        diag.emit('DEBUG', 'request_started', component='reader', **context)
        remaining = 20.0 if self._deadline is None else self._deadline - time.monotonic()
        if remaining <= 0:
            diag.emit('ERROR', 'request_failed', component='reader', reason_code='SCAN_DEADLINE', **context)
            raise TronReadError('TRON scan deadline exceeded')
        response = None
        try:
            response = self._client.request(method, self.base_url + path, headers=self._headers,
                                            timeout=min(20.0, remaining), follow_redirects=False, **kwargs)
            response.raise_for_status()
            payload = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            reason = 'HTTP_TRANSPORT_ERROR'
            for kind, code in ((httpx.ConnectTimeout, 'CONNECT_TIMEOUT'), (httpx.ReadTimeout, 'READ_TIMEOUT'),
                    (httpx.WriteTimeout, 'WRITE_TIMEOUT'), (httpx.PoolTimeout, 'POOL_TIMEOUT'),
                    (httpx.ConnectError, 'CONNECT_ERROR'), (httpx.RemoteProtocolError, 'PROTOCOL_ERROR'),
                    (ValueError, 'INVALID_JSON')):
                if isinstance(exc, kind):
                    reason = code
                    break
            status = response.status_code if response is not None else None
            if isinstance(exc, httpx.HTTPStatusError):
                reason = 'HTTP_RATE_LIMITED' if status == 429 else 'HTTP_SERVER_ERROR' if status >= 500 else 'HTTP_CLIENT_ERROR'
            diag.emit('ERROR', 'request_failed', component='reader', reason_code=reason,
                      http_status=status, duration_ms=int((time.monotonic()-started)*1000),
                      budget_ms=int(max(0, remaining)*1000), **context, **diag.exception_info(exc))
            raise TronReadError('TRON request failed') from None
        if self._deadline is not None and time.monotonic() >= self._deadline:
            diag.emit('ERROR', 'request_failed', component='reader', reason_code='SCAN_DEADLINE', **context)
            raise TronReadError('TRON scan deadline exceeded')
        if not isinstance(payload, dict) or any(key in payload for key in ('Error', 'error')):
            diag.emit('ERROR', 'request_failed', component='reader', reason_code='INVALID_RESPONSE', **context)
            raise TronReadError('Malformed TRON response')
        diag.emit('DEBUG', 'request_completed', component='reader', http_status=response.status_code,
                  duration_ms=int((time.monotonic()-started)*1000), **context)
        return payload

    def _head(self) -> tuple[int, int, str]:
        data = self._request('POST', '/walletsolidity/getnowblock', json={})
        try:
            raw = data['block_header']['raw_data']
            return _integer(raw['number']), _integer(raw['timestamp']), _word(data['blockID'])
        except (KeyError, TypeError):
            raise TronReadError('Malformed solid block') from None

    def _transactions(self, address: str, start_ms: int, end_ms: int) -> list[str]:
        params = {'only_confirmed': 'true', 'contract_address': USDT_CONTRACT,
                  'min_timestamp': start_ms, 'max_timestamp': end_ms,
                  'limit': 200, 'order_by': 'block_timestamp,asc'}
        transactions: dict[str, None] = {}
        cursors: set[str] = set()
        for page_index in range(self.max_pages):
            page = self._request('GET', f'/v1/accounts/{address}/transactions/trc20', params=params)
            if page.get('success') is not True or not isinstance(page.get('data'), list) or not isinstance(page.get('meta'), dict):
                raise TronReadError('Malformed TRON history page')
            if len(page['data']) > 200:
                raise TronReadError('TRON history page exceeds cap')
            for row in page['data']:
                if not isinstance(row, dict):
                    raise TronReadError('Malformed TRON history row')
                txid = _word(row.get('transaction_id'))
                transactions[txid] = None
                if len(transactions) > self.max_transactions:
                    raise TronReadError('TRON transaction cap exceeded')
            cursor = page['meta'].get('fingerprint')
            diag.emit('DEBUG', 'history_page_completed', component='reader', stage='history',
                      page_count=page_index+1, transaction_count=len(transactions))
            links = page['meta'].get('links', {})
            if not isinstance(links, dict):
                raise TronReadError('Malformed TRON pagination links')
            if cursor is None:
                if links.get('next'):
                    raise TronReadError('TRON pagination cursor missing')
                return list(transactions)
            if not isinstance(cursor, str) or not cursor or len(cursor) > 4096 or cursor in cursors or not page['data']:
                raise TronReadError('Invalid TRON pagination cursor')
            cursors.add(cursor)
            params['fingerprint'] = cursor
        raise TronReadError('TRON history page cap exceeded')

    def _events(self, txid: str, address: str, start_ms: int, end_ms: int, head: int) -> list[dict]:
        data = self._request('POST', '/walletsolidity/gettransactioninfobyid', json={'value': txid})
        if data.get('id') != txid or not isinstance(data.get('receipt'), dict) or data['receipt'].get('result') != 'SUCCESS':
            raise TronReadError('Unverified TRON receipt')
        block = _integer(data.get('blockNumber'))
        timestamp = _integer(data.get('blockTimeStamp'))
        if block > head or not start_ms <= timestamp <= end_ms:
            raise TronReadError('TRON receipt outside finalized window')
        logs = data.get('log')
        if not isinstance(logs, list) or len(logs) > 10000:
            raise TronReadError('Malformed TRON logs')
        events = []
        for index, log in enumerate(logs):
            if not isinstance(log, dict):
                raise TronReadError('Malformed TRON log')
            if log.get('address') not in (_USDT_HEX, '41' + _USDT_HEX):
                continue
            topics = log.get('topics')
            if not isinstance(topics, list) or not topics:
                raise TronReadError('Malformed TRON topics')
            if _word(topics[0]) != _TRANSFER:
                continue
            if len(topics) != 3:
                raise TronReadError('Malformed Transfer topics')
            sender, recipient = _word(topics[1]), _word(topics[2])
            if sender[:24] != '0' * 24 or recipient[:24] != '0' * 24:
                raise TronReadError('Malformed Transfer address')
            sender = _encode_address(bytes.fromhex('41' + sender[24:]))
            recipient = _encode_address(bytes.fromhex('41' + recipient[24:]))
            amount = int(_word(log.get('data')), 16)
            if address not in (sender, recipient):
                continue
            events.append({'txid': txid, 'log_index': index, 'block_number': block,
                           'timestamp_ms': timestamp, 'from_address': sender,
                           'to_address': recipient, 'amount_units': amount})
        if not events:
            raise TronReadError('History transaction has no matching USDT Transfer')
        return events

    def snapshot(self, address: str, start_ms: int, end_ms: int) -> dict:
        validate_tron_address(address)
        _integer(start_ms)
        _integer(end_ms)
        if start_ms > end_ms:
            raise ValueError('Invalid observation window')
        self._deadline = time.monotonic() + self.max_scan_seconds
        minimum_head = None
        for _ in range(3):
            result, minimum_head = self._snapshot_once(address, start_ms, end_ms, minimum_head)
            if result['stable_balance']:
                return result
        return result

    def _snapshot_once(self, address, start_ms, end_ms, minimum_head):
        # Every retry rebuilds the complete observation under the original
        # deadline. Never combine a prior event cut with a newer balance.
        before = self._head()
        if minimum_head is not None and (before[0] < minimum_head[0] or before[1] < minimum_head[1]):
            raise TronReadError('TRON solid head regressed')
        if minimum_head is not None and before[0] == minimum_head[0] and before != minimum_head:
            raise TronReadError('TRON solid head conflicted')
        end_ms = min(end_ms, before[1])
        if start_ms > end_ms:
            raise TronReadError('Observation window is not solidified yet')
        events = []
        for txid in self._transactions(address, start_ms, end_ms):
            events.extend(self._events(txid, address, start_ms, end_ms, before[0]))
        result = self._request('POST', '/walletsolidity/triggerconstantcontract', json={
            'owner_address': address, 'contract_address': USDT_CONTRACT, 'visible': True,
            'function_selector': 'balanceOf(address)',
            'parameter': '0' * 24 + _decode_address(address)[1:].hex()})
        constants = result.get('constant_result')
        if not isinstance(result.get('result'), dict) or result['result'].get('result') is not True or not isinstance(constants, list) or len(constants) != 1:
            raise TronReadError('Unverified TRON balance result')
        balance = int(_word(constants[0]), 16)
        after = self._head()
        if after[0] < before[0] or after[1] < before[1]:
            raise TronReadError('TRON solid head regressed')
        if after[0] == before[0] and after != before:
            raise TronReadError('TRON solid head conflicted')
        return {'events': sorted(events, key=lambda event: (event['block_number'], event['txid'], event['log_index'])),
                'balance_units': balance, 'solid_block': before[0],
                'solid_timestamp_ms': before[1], 'stable_balance': before == after}, after
