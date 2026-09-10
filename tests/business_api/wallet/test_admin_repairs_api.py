"""New write contracts require explicit confirmation and server identity."""
import pytest
import asyncio
import httpx
from fastapi import FastAPI
from pydantic import ValidationError
from sqlalchemy import create_engine
from app.api.admin_wallet_repairs import create_admin_wallet_repairs_router, RepairExecuteBody
from app.core.config import Settings
from app.core.database import create_session_factory
from app.core.errors import install_error_handlers


@pytest.mark.parametrize('confirmation', [None, False, 'true', 1])
def test_execute_requires_explicit_true_boolean(confirmation):
    payload = dict(preview_id='preview', digest='a'*64, expected_version=1, operation_id='operation')
    if confirmation is not None:
        payload['confirmed'] = confirmation
    with pytest.raises(ValidationError):
        RepairExecuteBody.model_validate(payload)


@pytest.mark.parametrize('path', ['/deposit-repairs/candidates?txid='+'a'*64+'&log_index=0',
    '/deposit-repairs/operation', '/payout-reconciliations/operation'])
def test_sensitive_read_without_identity_is_unauthorized(path):
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_admin_wallet_repairs_router(Settings(),
        create_session_factory(create_engine('sqlite://')), runtime=None), prefix='/api/v1/admin')
    async def read():
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            return await client.get('/api/v1/admin/wallet/manual'+path)
    response = asyncio.run(read())
    assert response.status_code == 401
    assert response.json()['error']['code'] == 'AUTH_REQUIRED'
    assert response.headers['cache-control'] == 'no-store'
