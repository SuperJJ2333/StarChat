from copy import deepcopy
from datetime import datetime, timezone

import httpx
import pytest
from coincurve import PrivateKey

from app.integrations.tron.finality import TronGridFinality, TronEvidenceUnavailable
from app.integrations.tron.message_signature import address_from_public_key


def account_adapter(change=None, advance=False):
    address = address_from_public_key(PrivateKey().public_key.format(compressed=False))
    now = datetime(2026, 9, 7, tzinfo=timezone.utc)
    permission = {'threshold': 1, 'keys': [{'address': address, 'weight': 1}]}
    account = {'address': address, 'owner_permission': deepcopy(permission),
        'active_permission': [dict(deepcopy(permission), type='Active', id=2, operations='ff'*32)]}
    if change:
        change(account)
    heads = [0]

    def handle(request):
        if request.url.path == '/walletsolidity/getaccount':
            return httpx.Response(200, json=account)
        assert request.url.path == '/walletsolidity/getnowblock'
        heads[0] += 1
        height = 100 + (1 if advance and heads[0] > 1 else 0)
        return httpx.Response(200, json={'blockID': f'{height:064x}',
            'block_header': {'raw_data': {'number': height, 'timestamp': int(now.timestamp()*1000)-1000}}})

    return address, TronGridFinality(base_url='https://api.trongrid.io', clock=lambda: now,
        max_age_seconds=120, transport=httpx.MockTransport(handle))


def test_single_key_control_at_a_stable_solid_head():
    address, adapter = account_adapter()
    with_adapter = adapter.account_control(address)
    assert with_adapter.address == address
    assert with_adapter.policy == 'TRONGRID_SINGLE_SOURCE_V1'
    assert with_adapter.solid_head.height == 100
    adapter.close()


@pytest.mark.parametrize('change', [
    lambda a: a.pop('owner_permission'),
    lambda a: a.pop('active_permission'),
    lambda a: a.update(address='wrong'),
    lambda a: a.update(type='Contract'),
    lambda a: a.update(witness_permission={'threshold': 1}),
    lambda a: a['owner_permission'].update(threshold=2),
    lambda a: a['owner_permission'].update(threshold=True),
    lambda a: a['owner_permission'].update(id=False),
    lambda a: a['owner_permission'].update(type=False),
    lambda a: a['active_permission'][0].update(type=2.0),
    lambda a: a['owner_permission']['keys'][0].update(weight=True),
    lambda a: a['owner_permission']['keys'][0].update(address='wrong'),
    lambda a: a['active_permission'][0]['keys'][0].update(address='delegated'),
    lambda a: a['active_permission'][0].update(operations='bad'),
    lambda a: a['active_permission'][0].update(type='Owner'),
])
def test_unsupported_or_unverified_account_control_rejected(change):
    address, adapter = account_adapter(change)
    with pytest.raises(TronEvidenceUnavailable):
        adapter.account_control(address)
    adapter.close()


def test_account_state_moving_across_heads_is_unavailable():
    address, adapter = account_adapter(advance=True)
    with pytest.raises(TronEvidenceUnavailable):
        adapter.account_control(address)
    adapter.close()
