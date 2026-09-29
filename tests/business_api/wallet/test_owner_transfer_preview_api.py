"""The preview accepts a missing locator; execution remains exact and protected."""
import asyncio
from datetime import datetime, timezone
from types import SimpleNamespace

import httpx
import jwt
from fastapi import FastAPI

from app.api.admin_wallet_owner_transfers import create_admin_owner_transfer_router
from app.core.errors import install_error_handlers
from app.integrations.tron.finality import SolidHead, TransactionEvidence, TransferEvidence
from app.modules.wallet.funding import OfficialFundingConfig
from tests.business_api.identity.test_wallet_access_grant import grant_context  # noqa: F401


TX = '7' * 64
OFFICIAL = 'T' + 'A' * 33
TARGET = 'T' + 'B' * 33
BASE = '/api/v1/admin/wallet/manual/owner-transfers'


def fixture_app(grant_context):
    _, factory, now, claims, settings = grant_context
    settings.jwt_secret = 'owner-transfer-preview-test-secret-at-least-32-bytes'
    settings.jwt_issuer = 'owner-transfer-preview-test'
    settings.wallet_owner_transfers_enabled = True
    indices = [7]
    proof_calls = []

    class Adapter:
        def transaction_evidence(self, txid):
            proof_calls.append(txid)
            when = now[0]
            timestamp = int(when.timestamp() * 1000)
            transfers = tuple(TransferEvidence(txid, index, 102, 'c' * 64, timestamp,
                OFFICIAL, TARGET, 2_000000) for index in indices)
            return TransactionEvidence(txid, 102, 'c' * 64, timestamp,
                SolidHead(104, 'd' * 64, timestamp, when), transfers, when)

    runtime = SimpleNamespace(receipts=SimpleNamespace(wallet_ledger=None, adapter=Adapter(),
        official_config=OfficialFundingConfig(OFFICIAL, 'test-v1'), clock=lambda: now[0]))
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_admin_owner_transfer_router(settings, factory, runtime=runtime,
        clock_trusted=lambda: True), prefix='/api/v1/admin')
    token = jwt.encode(claims | {'iss': settings.jwt_issuer}, settings.jwt_secret, algorithm='HS256')
    return app, indices, proof_calls, {'Authorization': 'Bearer ' + token}, settings


def payload(**changes):
    result = dict(txid=TX, reason_code='OWNER_TEST_DRAW',
        reason_detail='synthetic owner test', ownership_attested=True)
    result.update(changes)
    return result


def test_preview_omitted_index_and_explicit_index_are_accepted_but_execute_still_requires_it(grant_context):
    app, _, proof_calls, headers, _ = fixture_app(grant_context)
    grant_context[0].verify(claims=grant_context[3], operation_password='operation-password-123')

    async def run():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            implicit = await client.post(BASE + '/preview', headers=headers, json=payload())
            assert implicit.status_code == 200, implicit.text
            assert implicit.json()['log_index'] == 7
            assert implicit.json()['amount_units'] == '2000000'
            assert implicit.json()['to_address'] == TARGET
            explicit = await client.post(BASE + '/preview', headers=headers, json=payload(log_index=7))
            assert explicit.status_code == 200, explicit.text
            assert explicit.json()['log_index'] == 7
            missing_execute = await client.post(BASE, headers=headers | {'Idempotency-Key': 'synthetic-http-key'},
                json=payload())
            assert missing_execute.status_code == 422, missing_execute.text

    asyncio.run(run())
    assert proof_calls == [TX, TX]


def test_preview_zero_and_multiple_official_transfers_have_distinct_409_codes(grant_context):
    app, indices, proof_calls, headers, _ = fixture_app(grant_context)
    grant_context[0].verify(claims=grant_context[3], operation_password='operation-password-123')

    async def run():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            indices.clear()
            missing = await client.post(BASE + '/preview', headers=headers, json=payload())
            assert missing.status_code == 409, missing.text
            assert missing.json()['error']['code'] == 'TRANSFER_NOT_FOUND'
            indices.extend([7, 8])
            ambiguous = await client.post(BASE + '/preview', headers=headers, json=payload())
            assert ambiguous.status_code == 409, ambiguous.text
            assert ambiguous.json()['error']['code'] == 'TRANSFER_SELECTION_REQUIRED'

    asyncio.run(run())
    assert proof_calls == [TX, TX]


def test_preview_authorization_precedes_trongrid_for_missing_index(grant_context):
    app, _, proof_calls, headers, settings = fixture_app(grant_context)

    async def run():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            without_grant = await client.post(BASE + '/preview', headers=headers, json=payload())
            assert without_grant.status_code == 403, without_grant.text
            assert without_grant.json()['error']['code'] == 'WALLET_ACCESS_REQUIRED'
            settings.wallet_manual_owner_admin_id = 'not-owner'
            wrong_owner = await client.post(BASE + '/preview', headers=headers, json=payload())
            assert wrong_owner.status_code == 403, wrong_owner.text
            assert wrong_owner.json()['error']['code'] == 'PERMISSION_DENIED'

    asyncio.run(run())
    assert proof_calls == []


def test_grant_invalidation_after_budget_lock_blocks_proof(grant_context, monkeypatch):
    from app.modules.wallet import owner_transfers

    app, _, proof_calls, headers, settings = fixture_app(grant_context)
    grant_context[0].verify(claims=grant_context[3], operation_password='operation-password-123')
    real_lock_budget = owner_transfers.lock_budget
    lock_calls = []

    def invalidate_after_lock(session):
        result = real_lock_budget(session)
        lock_calls.append(True)
        settings.wallet_access_grant_enabled = False
        return result

    monkeypatch.setattr(owner_transfers, 'lock_budget', invalidate_after_lock)

    async def run():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            response = await client.post(BASE + '/preview', headers=headers, json=payload())
            assert response.status_code == 403, response.text
            assert response.json()['error']['code'] == 'WALLET_ACCESS_REQUIRED'

    asyncio.run(run())
    assert lock_calls == [True]
    assert proof_calls == []


def test_openapi_keeps_execute_locator_required_and_documents_preview_ambiguity(grant_context):
    app, _, _, _, _ = fixture_app(grant_context)
    document = app.openapi()
    preview = document['paths'][BASE + '/preview']['post']
    execute = document['paths'][BASE]['post']
    preview_schema = document['components']['schemas'][preview['requestBody']['content']['application/json']['schema']['$ref'].split('/')[-1]]
    execute_schema = document['components']['schemas'][execute['requestBody']['content']['application/json']['schema']['$ref'].split('/')[-1]]
    assert 'log_index' not in preview_schema['required']
    assert 'log_index' in execute_schema['required']
    assert 'TRANSFER_NOT_FOUND' in preview['responses']['409']['description']
    assert 'TRANSFER_SELECTION_REQUIRED' in preview['responses']['409']['description']
