from datetime import datetime, timezone
from types import SimpleNamespace
from fastapi import FastAPI
from fastapi.testclient import TestClient
from app.core.config import Settings
from app.core.errors import install_error_handlers, AppError
from app.modules.identity.tokens import TokenService
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.operation_password_models import AdminOperationCredential
from app.api.manual_wallet import create_manual_wallet_router
from test_manual_payouts import core
import pytest


def test_user_request_retains_totp_but_admin_claim_submit_correct_require_password(core):
    settings=Settings(_env_file=None,environment='test',jwt_secret='password-payouts-'*4,
        wallet_admin_auth_mode='operation_password',wallet_manual_owner_admin_id='owner')
    runtime=SimpleNamespace(funds_enabled=True,payouts=core[0],intents=None)
    now=datetime.now(timezone.utc)
    with core[1].begin() as session:
        session.add(AdminOperationCredential(user_id='owner',password_hash=PasswordHasher().hash('operation-password-123'),version=1,created_at=now,updated_at=now))
    app=FastAPI(); install_error_handlers(app)
    app.include_router(create_manual_wallet_router(settings,core[1],runtime=runtime))
    tokens=TokenService(core[1],jwt_secret=settings.jwt_secret,jwt_issuer=settings.jwt_issuer)
    headers={user:{'Authorization':'Bearer '+tokens.issue_pair(user_id=user,device_key=user,display_name='fixture').access_token,'Idempotency-Key':'fixture'} for user in ('alice','owner')}
    client=TestClient(app)
    quote=client.post('/manual/payout-quotes',headers=headers['alice'],json=dict(amount='10.000000',expected_binding_version=1)).json()
    assert client.post('/manual/payouts',headers=headers['alice'],json=dict(quote_id=quote['id'],operation_password='operation-password-123')).status_code==422
    order=client.post('/manual/payouts',headers=headers['alice'],json=dict(quote_id=quote['id'],mfa_proof='123456')).json()
    path='/manual/payouts/'+order['id']
    assert client.post(path+'/claim',headers=headers['owner'],json=dict(expected_digest=order['digest'],mfa_proof='123456')).status_code==403
    password=dict(operation_password='operation-password-123')
    claimed=client.post(path+'/claim',headers=headers['owner'],json=dict(expected_digest=order['digest'])|password)
    assert claimed.status_code==200,claimed.text
    assert client.post(path+'/txid',headers=headers['owner'],json=dict(txid='a'*64)).status_code==403
    submitted=client.post(path+'/txid',headers=headers['owner'],json=dict(txid='a'*64)|password)
    assert submitted.status_code==200,submitted.text
    corrected=client.post(path+'/correct-candidate',headers=headers['owner'],json=dict(txid='b'*64,reason_code='OWNER_CORRECTION')|password)
    assert corrected.status_code==200,corrected.text


@pytest.mark.parametrize('operation',['claim','submit','correct'])
def test_final_password_authorization_failure_rolls_back_admin_mutation(core,operation):
    from test_manual_payouts import request,claim
    from app.modules.wallet.manual_payout_models import ManualPayoutOrder,ManualPayoutCandidate
    from sqlalchemy import select,func
    order=request(core)
    if operation!='claim':claim(core,order)
    if operation=='correct':core[0].submit_txid(admin_id='owner',order_id=order['id'],txid='a'*64,idempotency_key='first')
    counts=[0]
    def authorization(session):
        def final():
            counts[0]+=1
            if counts[0]==(3 if operation=='claim' else 2):
                raise AppError(code='OPERATION_PASSWORD_CHANGED',message='OPERATION_PASSWORD_CHANGED',status_code=403)
        return final
    with pytest.raises(AppError,match='OPERATION_PASSWORD_CHANGED'):
        if operation=='claim':core[0].claim(admin_id='owner',session_id='fixture',order_id=order['id'],expected_digest=order['digest'],idempotency_key='guarded',authorize=authorization)
        elif operation=='submit':core[0].submit_txid(admin_id='owner',order_id=order['id'],txid='b'*64,idempotency_key='guarded',authorize=authorization)
        else:core[0].correct_candidate(admin_id='owner',session_id='fixture',order_id=order['id'],txid='b'*64,reason_code='OWNER_CORRECTION',idempotency_key='guarded',authorize=authorization)
    with core[1]() as session:
        row=session.get(ManualPayoutOrder,order['id'])
        assert row.status=={'claim':'REQUESTED','submit':'CLAIMED','correct':'UNKNOWN'}[operation]
        assert session.scalar(select(func.count()).select_from(ManualPayoutCandidate))==(1 if operation=='correct' else 0)
