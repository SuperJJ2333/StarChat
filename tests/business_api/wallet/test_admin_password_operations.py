from datetime import datetime, timezone
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.operation_password_models import AdminOperationCredential
from test_manual_operations_api import core, monitor, coverage, threaded_sqlite, operations


def test_operations_password_mode_never_calls_injected_totp(core,monitor,operations):
    client,headers,settings,mfa=operations
    settings.wallet_admin_auth_mode='operation_password'
    now=datetime.now(timezone.utc)
    with core[1].begin() as session:
        session.add(AdminOperationCredential(user_id='alice',password_hash=PasswordHasher().hash('operation-password-123'),version=1,created_at=now,updated_at=now))
    row=monitor[0].incidents.observe([dict(fingerprint='manual-reserve:FIXTURE',code='FIXTURE',severity='P0',subject_id='global')],complete=False)[0]
    path='/api/v1/admin/wallet/manual/operations/incidents/'+row['id']+'/ack'
    body=dict(expected_version=1,reason_code='OWNER_REVIEW')
    assert client.post(path,headers=headers,json=body|{'mfa_proof':'123456'}).status_code==403
    assert client.post(path,headers=headers,json=body|{'mfa_proof':'123456','operation_password':'operation-password-123'}).status_code==403
    assert client.post(path,headers=headers,json=body|{'operation_password':'wrong-password-123'}).status_code==401
    response=client.post(path,headers=headers,json=body|{'operation_password':'operation-password-123'})
    assert response.status_code==200,response.text
    assert not mfa
