from types import SimpleNamespace
from fastapi import FastAPI
from fastapi.testclient import TestClient
from app.core.errors import install_error_handlers
from app.modules.identity.tokens import TokenService
from app.api.admin_wallet_security import create_admin_wallet_security_router
from test_operation_password import security


def test_security_api_setup_is_explicit_no_cache_and_masks_secrets(security):
    settings=SimpleNamespace(jwt_secret='security-api-key-'*4,jwt_issuer='test',wallet_manual_owner_admin_id='owner',wallet_admin_auth_mode='operation_password')
    app=FastAPI()
    install_error_handlers(app)
    app.include_router(create_admin_wallet_security_router(settings,security[1],clock=lambda:security[2][0]),prefix='/api/v1/admin')
    pair=TokenService(security[1],jwt_secret=settings.jwt_secret,jwt_issuer='test',now_factory=lambda:security[2][0]).issue_pair(
        user_id='owner',device_key='api-fixture',display_name='fixture')
    headers={'Authorization':'Bearer '+pair.access_token,'Idempotency-Key':'setup'}
    client=TestClient(app)
    path='/api/v1/admin/wallet/security'
    assert client.get(path).status_code==401
    result=client.get(path,headers=headers)
    assert result.json()==dict(auth_mode='operation_password',configured=False,version=0)
    assert result.headers['cache-control']=='no-store'
    body=dict(login_password='login-password-123',new_operation_password='operation-password-123')
    denied=client.post(path+'/operation-password',headers=headers,json=body|{'user_id':'someone'})
    assert denied.status_code==422 and body['new_operation_password'] not in denied.text
    result=client.post(path+'/operation-password',headers=headers,json=body)
    assert result.status_code==200 and result.json()['version']==1
    assert result.headers['cache-control']=='no-store'
    assert body['new_operation_password'] not in result.text
    settings.wallet_manual_owner_admin_id='someone-else'
    assert client.get(path,headers=headers).status_code==403
