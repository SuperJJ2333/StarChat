from types import SimpleNamespace
from fastapi import FastAPI
from fastapi.testclient import TestClient
from test_legacy_handover import handover  # noqa: F401


def test_handover_api_requires_actual_owner_mfa_and_forbids_client_evidence(handover):
    from app.api.manual_wallet_handover import create_manual_wallet_handover_router
    from app.core.errors import install_error_handlers
    from app.modules.identity.models import User, UserRole
    from app.modules.identity.enums import AccountStatus, RoleCode
    from app.modules.identity.tokens import TokenService
    service,factory,_,now,_,file=handover
    with factory.begin() as session:
        session.add(User(id='owner',username='owner',username_normalized='owner',email='owner@example.test',
            email_normalized='owner@example.test',password_hash='fixture',status=AccountStatus.ACTIVE,created_at=now[0],updated_at=now[0]))
        session.add(UserRole(id='owner-role',user_id='owner',role_code=RoleCode.SUPER_ADMIN,assigned_by='fixture',assigned_at=now[0]))
    settings=SimpleNamespace(jwt_secret='handover-test-secret-'*4,jwt_issuer='fixture',wallet_real_mode='manual_tron',
        wallet_manual_owner_admin_id='owner',wallet_handover_deployment_record_path=str(file),
        wallet_handover_preparation_mode=True,wallet_real_funds_enabled=False)
    app=FastAPI()
    install_error_handlers(app)
    app.include_router(create_manual_wallet_handover_router(settings,factory,monitor_factory=lambda:service.monitor,
        mfa_verifier=lambda **kwargs:kwargs['proof']=='123456',clock=lambda:now[0]),prefix='/api/v1/admin')
    client=TestClient(app)
    token=TokenService(factory,jwt_secret=settings.jwt_secret,jwt_issuer=settings.jwt_issuer,now_factory=lambda:now[0]).issue_pair(
        user_id='owner',device_key='fixture',display_name='fixture').access_token
    headers={'Authorization':'Bearer '+token,'Idempotency-Key':'prepare'}
    path='/api/v1/admin/wallet/manual/handover/prepare'
    body=dict(reason_code='OWNER_HANDOVER',mfa_proof='123456')
    assert client.post(path,json=body).status_code == 401
    assert client.post(path,json=body|{'mfa_proof':'000000'},headers=headers).status_code == 403
    bad=client.post(path,json=body|{'incident_ids':['arbitrary']},headers=headers)
    assert bad.status_code == 422 and '123456' not in bad.text
    response=client.post(path,json=body,headers=headers)
    assert response.status_code == 200,response.text
    assert response.json()['status'] == 'PREPARED' and len(response.json()['incidents']) == 3
    assert response.headers['cache-control'] == 'no-store'
    settings.wallet_manual_owner_admin_id='another-owner'
    assert client.get('/api/v1/admin/wallet/manual/handover/'+response.json()['id'],headers=headers).status_code == 403
