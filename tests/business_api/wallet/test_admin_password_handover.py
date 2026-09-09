from types import SimpleNamespace
from fastapi import FastAPI
from fastapi.testclient import TestClient
from test_legacy_handover import handover
from app.api.manual_wallet_handover import create_manual_wallet_handover_router
from app.core.errors import install_error_handlers
from app.modules.identity.models import User,UserRole
from app.modules.identity.enums import AccountStatus
from app.modules.identity.tokens import TokenService
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.operation_password_models import AdminOperationCredential


def test_handover_fixed_password_cannot_be_bypassed_by_totp_injection(handover):
    service,factory,_,now,_,file=handover
    with factory.begin() as session:
        session.add(User(id='owner',username='owner',username_normalized='owner',email='owner@example.test',email_normalized='owner@example.test',
            password_hash='fixture',status=AccountStatus.ACTIVE,created_at=now[0],updated_at=now[0]))
        session.add(UserRole(id='role',user_id='owner',role_code='SUPER_ADMIN',assigned_by='fixture',assigned_at=now[0]))
        session.add(AdminOperationCredential(user_id='owner',password_hash=PasswordHasher().hash('operation-password-123'),version=1,created_at=now[0],updated_at=now[0]))
    settings=SimpleNamespace(jwt_secret='handover-password-'*4,jwt_issuer='fixture',wallet_real_mode='manual_tron',wallet_manual_owner_admin_id='owner',
        wallet_admin_auth_mode='operation_password',wallet_handover_deployment_record_path=str(file),wallet_handover_preparation_mode=True,wallet_real_funds_enabled=False)
    app=FastAPI();install_error_handlers(app)
    def forbidden(**kwargs):raise AssertionError('TOTP fallback forbidden')
    app.include_router(create_manual_wallet_handover_router(settings,factory,monitor_factory=lambda:service.monitor,mfa_verifier=forbidden,clock=lambda:now[0]))
    token=TokenService(factory,jwt_secret=settings.jwt_secret,jwt_issuer='fixture',now_factory=lambda:now[0]).issue_pair(user_id='owner',device_key='fixture',display_name='fixture').access_token
    headers={'Authorization':'Bearer '+token,'Idempotency-Key':'prepare'}
    client=TestClient(app);path='/wallet/manual/handover/prepare'
    assert client.post(path,headers=headers,json=dict(reason_code='OWNER_HANDOVER',mfa_proof='123456')).status_code==403
    result=client.post(path,headers=headers,json=dict(reason_code='OWNER_HANDOVER',operation_password='operation-password-123'))
    assert result.status_code==200,result.text
    assert result.json()['status']=='PREPARED'
