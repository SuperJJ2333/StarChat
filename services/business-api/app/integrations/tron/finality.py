"""Bounded mainnet observation under ADR-0013, not independent consensus proof.

Solidity receipts and matching blocks come from one provider. Missing, unsuccessful,
contradictory or stale evidence is unavailable, never proof a payment has failed.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import json
import math
import time
from typing import Callable
from urllib.parse import urlsplit

import httpx

from .reader import USDT_CONTRACT, _USDT_HEX, _TRANSFER, _WORD, _encode_address
from .message_signature import canonical_address

POLICY = 'TRONGRID_SINGLE_SOURCE_V1'
SOURCE_ID = 'trongrid-mainnet'
NETWORK = 'tron-mainnet'
MANUAL_SOLID_HEAD_MAX_AGE_SECONDS = 180


class TronEvidenceUnavailable(RuntimeError):
    """Sanitized retry/review signal; carries no terminal payment decision."""


@dataclass(frozen=True)
class SolidHead:
    height: int
    block_id: str
    timestamp_ms: int
    observed_at: datetime
    policy: str = POLICY
    source_id: str = SOURCE_ID
    network: str = NETWORK


@dataclass(frozen=True)
class TransferEvidence:
    txid: str
    log_index: int
    block_number: int
    block_id: str
    timestamp_ms: int
    from_address: str
    to_address: str
    amount_units: int
    contract: str = USDT_CONTRACT


@dataclass(frozen=True)
class TransactionEvidence:
    txid: str
    block_number: int
    block_id: str
    timestamp_ms: int
    solid_head: SolidHead
    transfers: tuple[TransferEvidence, ...]
    observed_at: datetime
    policy: str = POLICY
    source_id: str = SOURCE_ID
    network: str = NETWORK
    contract: str = USDT_CONTRACT


@dataclass(frozen=True)
class AccountControlEvidence:
    address: str
    solid_head: SolidHead
    observed_at: datetime
    policy: str = POLICY
    source_id: str = SOURCE_ID
    network: str = NETWORK


def transaction_evidence_fresh(evidence, now):
    """Recheck at consumption after database locks; never age by transfer time."""
    if not isinstance(evidence, TransactionEvidence) or not isinstance(evidence.solid_head, SolidHead):
        return False
    observed = (now, evidence.observed_at, evidence.solid_head.observed_at)
    if any(not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None for value in observed):
        return False
    timestamp = evidence.solid_head.timestamp_ms
    return (type(timestamp) is int
        and all(0 <= (now-value).total_seconds() <= 120 for value in observed[1:])
        and 0 <= int(now.timestamp()*1000)-timestamp <= MANUAL_SOLID_HEAD_MAX_AGE_SECONDS*1000)


def _integer(value: object) -> int:
    if type(value) is not int or not 0 <= value < 2**63:
        raise TronEvidenceUnavailable('Malformed TRON integer')
    return value


def _word(value: object) -> str:
    if not isinstance(value, str) or _WORD.fullmatch(value) is None:
        raise TronEvidenceUnavailable('Malformed TRON word')
    return value.lower()


class TronGridFinality:
    """Read-only, fixed origin adapter. Clock must return aware UTC-compatible time.

    Each operation has its own monotonic deadline; no shared scan state. Inject a
    transport for tests, or an HTTP client owned by the caller. No redirects.
    """

    def __init__(self, *, base_url: str, clock: Callable[[], datetime],
                 max_age_seconds: float, api_key: str | None = None,
                 solid_head_max_age_seconds: float | None = None,
                 client: httpx.Client | None = None,
                 transport: httpx.BaseTransport | None = None):
        url = urlsplit(base_url)
        if (url.scheme != 'https' or url.netloc != 'api.trongrid.io'
                or url.path not in ('', '/') or url.query or url.fragment):
            raise ValueError('TRON endpoint must be the configured mainnet HTTPS origin')
        if (type(max_age_seconds) not in (int, float) or not math.isfinite(max_age_seconds)
                or not 0 < max_age_seconds <= 300):
            raise ValueError('Invalid solid head age limit')
        if client is not None and transport is not None:
            raise ValueError('Supply either client or transport')
        self._base_url = 'https://api.trongrid.io'
        self._clock = clock
        self._max_age_ms = max_age_seconds * 1000
        head_limit = max_age_seconds if solid_head_max_age_seconds is None else solid_head_max_age_seconds
        if (type(head_limit) not in (int, float) or not math.isfinite(head_limit)
                or not 0 < head_limit <= 300):
            raise ValueError('Invalid solid head age limit')
        self._solid_head_max_age_ms = head_limit * 1000
        self._headers = {'TRON-PRO-API-KEY': api_key} if api_key else {}
        self._client = client if client is not None else httpx.Client(
            transport=transport, timeout=10, follow_redirects=False, trust_env=False)
        self._owns_client = client is None

    def close(self) -> None:
        if self._owns_client:
            self._client.close()

    def _now(self) -> datetime:
        now = self._clock()
        if not isinstance(now, datetime) or now.tzinfo is None or now.utcoffset() is None:
            raise TronEvidenceUnavailable('Invalid observation clock')
        return now.astimezone(timezone.utc)

    def _request(self, path: str, payload: dict, deadline: float) -> dict:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TronEvidenceUnavailable('TRON observation deadline exceeded')
        try:
            with self._client.stream('POST', self._base_url + path, json=payload,
                    headers=self._headers, timeout=min(10, remaining), follow_redirects=False) as response:
                response.raise_for_status()
                body = bytearray()
                for chunk in response.iter_bytes(chunk_size=65536):
                    if time.monotonic() >= deadline:
                        raise TronEvidenceUnavailable('TRON observation deadline exceeded')
                    body.extend(chunk)
                    if len(body) > 2_000_000:
                        raise TronEvidenceUnavailable('TRON response exceeds cap')
                data = json.loads(body)
        except (httpx.HTTPError, ValueError, RecursionError):
            raise TronEvidenceUnavailable('TRON request unavailable') from None
        if time.monotonic() >= deadline:
            raise TronEvidenceUnavailable('TRON observation deadline exceeded')
        if not isinstance(data, dict) or 'Error' in data or 'error' in data:
            raise TronEvidenceUnavailable('Malformed TRON response')
        return data

    def _block(self, data: dict, now: datetime) -> SolidHead:
        try:
            raw = data['block_header']['raw_data']
            return SolidHead(_integer(raw['number']), _word(data['blockID']),
                             _integer(raw['timestamp']), now)
        except (KeyError, TypeError):
            raise TronEvidenceUnavailable('Malformed TRON block') from None

    def _fresh(self, head: SolidHead, now: datetime) -> None:
        age = int(now.timestamp() * 1000) - head.timestamp_ms
        observation_age = (now-head.observed_at).total_seconds()*1000
        if not 0 <= age <= self._solid_head_max_age_ms or not 0 <= observation_age <= self._max_age_ms:
            raise TronEvidenceUnavailable('TRON solid head is stale or future')

    def _head(self, deadline: float) -> SolidHead:
        data = self._request('/walletsolidity/getnowblock', {}, deadline)
        now = self._now()
        head = self._block(data, now)
        self._fresh(head, now)
        return head

    def solid_head(self) -> SolidHead:
        return self._head(time.monotonic() + 30)

    def account_control(self, address: str) -> AccountControlEvidence:
        """Only ordinary accounts with no independently delegated keys are supported."""
        try:
            address = canonical_address(address)
        except (ValueError, TypeError):
            raise TronEvidenceUnavailable('Invalid TRON account') from None
        deadline = time.monotonic() + 30
        before = self._head(deadline)
        data = self._request('/walletsolidity/getaccount', {'address': address, 'visible': True}, deadline)
        def enum_is(value, label, number):
            return (type(value) is str and value == label) or (type(value) is int and value == number)

        if (data.get('address') != address or not enum_is(data.get('type', 'Normal'), 'Normal', 0)
                or data.get('witness_permission') is not None):
            raise TronEvidenceUnavailable('Unsupported TRON account control')

        def single_key(permission, *, owner):
            if not isinstance(permission, dict):
                return False
            if type(permission.get('parent_id', 0)) is not int or permission.get('parent_id', 0) != 0:
                return False
            if owner:
                if (not enum_is(permission.get('type', 'Owner'), 'Owner', 0)
                        or type(permission.get('id', 0)) is not int or permission.get('id', 0) != 0):
                    return False
            elif (not enum_is(permission.get('type'), 'Active', 2)
                    or type(permission.get('id')) is not int or not 2 <= permission['id'] <= 9
                    or not isinstance(permission.get('operations'), str)
                    or _WORD.fullmatch(permission['operations']) is None):
                return False
            keys = permission.get('keys')
            return (type(permission.get('threshold')) is int and permission['threshold'] == 1
                and isinstance(keys, list) and len(keys) == 1 and isinstance(keys[0], dict)
                and keys[0].get('address') == address
                and type(keys[0].get('weight')) is int and keys[0]['weight'] == 1)

        active = data.get('active_permission')
        if (not single_key(data.get('owner_permission'), owner=True)
                or not isinstance(active, list) or len(active) > 8
                or any(not single_key(permission, owner=False) for permission in active)
                or len({permission['id'] for permission in active}) != len(active)):
            raise TronEvidenceUnavailable('Unsupported TRON account permissions')
        after = self._head(deadline)
        self._fresh(before, after.observed_at)
        if (after.observed_at < before.observed_at
                or (before.height, before.block_id, before.timestamp_ms)
                != (after.height, after.block_id, after.timestamp_ms)):
            raise TronEvidenceUnavailable('TRON account observation crossed solid heads')
        return AccountControlEvidence(address, after, after.observed_at)

    def transaction_evidence(self, txid: str) -> TransactionEvidence:
        if _word(txid) != txid:
            raise TronEvidenceUnavailable('TRON transaction id must be canonical')
        deadline = time.monotonic() + 30
        before = self._head(deadline)
        receipt = self._request('/walletsolidity/gettransactioninfobyid', {'value': txid}, deadline)
        if (receipt.get('id') != txid or not isinstance(receipt.get('receipt'), dict)
                or receipt['receipt'].get('result') != 'SUCCESS'):
            raise TronEvidenceUnavailable('TRON successful receipt unavailable')
        height = _integer(receipt.get('blockNumber'))
        timestamp = _integer(receipt.get('blockTimeStamp'))
        if height > before.height or timestamp > before.timestamp_ms:
            raise TronEvidenceUnavailable('TRON receipt outside solid head')
        data = self._request('/walletsolidity/getblockbynum', {'num': height}, deadline)
        mined = self._block(data, self._now())
        transactions = data.get('transactions')
        if (mined.height != height or mined.timestamp_ms != timestamp
                or not isinstance(transactions, list) or len(transactions) > 10000
                or any(not isinstance(item, dict) for item in transactions)
                or sum(item.get('txID') == txid for item in transactions) != 1
                or (height == before.height and mined.block_id != before.block_id)):
            raise TronEvidenceUnavailable('TRON receipt block mismatch')
        logs = receipt.get('log')
        if not isinstance(logs, list) or len(logs) > 10000:
            raise TronEvidenceUnavailable('Malformed TRON logs')
        transfers = []
        for index, log in enumerate(logs):
            if not isinstance(log, dict):
                raise TronEvidenceUnavailable('Malformed TRON log')
            if log.get('address') not in (_USDT_HEX, '41' + _USDT_HEX):
                continue
            topics = log.get('topics')
            if not isinstance(topics, list) or not 1 <= len(topics) <= 4:
                raise TronEvidenceUnavailable('Malformed TRON topics')
            words = [_word(topic) for topic in topics]
            if words[0] != _TRANSFER:
                continue
            if len(words) != 3 or any(word[:24] != '0'*24 for word in words[1:]):
                raise TronEvidenceUnavailable('Malformed TRON Transfer topics')
            sender, recipient = [_encode_address(bytes.fromhex('41' + word[24:])) for word in words[1:]]
            transfers.append(TransferEvidence(txid, index, height, mined.block_id, timestamp,
                sender, recipient, int(_word(log.get('data')), 16)))
        after = self._head(deadline)
        self._fresh(before, after.observed_at)
        if (after.observed_at < before.observed_at or after.height < before.height
                or after.timestamp_ms < before.timestamp_ms
                or (after.height == before.height and (
                    after.block_id != before.block_id or after.timestamp_ms != before.timestamp_ms))):
            raise TronEvidenceUnavailable('TRON solid head regressed or conflicted')
        return TransactionEvidence(txid, height, mined.block_id, timestamp, after,
                                   tuple(transfers), after.observed_at)
