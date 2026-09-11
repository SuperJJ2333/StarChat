from datetime import datetime, timedelta, timezone
from dataclasses import replace

from fastapi import FastAPI
from fastapi.testclient import TestClient
import jwt
import pytest
from sqlalchemy import select

from app.core.config import Settings
from app.core.errors import install_error_handlers
from app.modules.audit.models import AuditEvent
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import Device, RefreshTokenFamily, User, UserRole
from app.modules.identity.tokens import TokenService
from test_manual_payouts import core, quote, request, claim, evidence  # noqa: F401

URL = '/admin/wallet/manual/payouts'


@pytest.fixture
def api(core):
    from app.api.manual_wallet_admin import create_manual_wallet_admin_router
    settings = Settings(_env_file=None,environment='test',jwt_secret='manual-admin-test-secret-'*3)
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_manual_wallet_admin_router(settings,core[1]),prefix='/admin')
    tokens = TokenService(core[1],jwt_secret=settings.jwt_secret,jwt_issuer=settings.jwt_issuer)
    pair = tokens.issue_pair(user_id='owner',device_key='admin-test',display_name='test')
    headers = {'Authorization':'Bearer '+pair.access_token}
    with TestClient(app,raise_server_exceptions=False) as client:
        yield client,headers,settings,tokens


def test_list_and_detail_return_snapshot_history_and_audit(api,core):
    order = claim(core)
    core[0].submit_txid(admin_id='owner',order_id=order['id'],txid='a'*64,idempotency_key='tx')
    core[6].evidence = evidence(core)
    core[0].reconcile(order_id=order['id'])
    client,headers,*_ = api
    page = client.get(URL,headers=headers)
    assert page.status_code == 200
    assert page.headers['cache-control'] == 'no-store'
    assert page.headers['x-content-type-options'] == 'nosniff'
    assert page.json()['items'][0]['settlement_txid'] == 'a'*64
    detail = client.get(URL+'/'+order['id'],headers=headers)
    assert detail.status_code == 200
    body = detail.json()
    assert body['snapshot']['target_address'] == core[3]
    assert body['snapshot']['binding_id'] == 'binding'
    assert body['snapshot']['fee'] == '0.000000'
    assert body['candidates'][0]['txid'] == body['settlement_txid'] == 'a'*64
    with core[1]() as s:
        audits = s.scalars(select(AuditEvent).where(AuditEvent.action == 'wallet.manual_payout.viewed')).all()
        assert len(audits) == 2
        assert all(a.actor_id == 'owner' for a in audits)
        assert core[3] not in str([(a.subject_id,a.after_data,a.reason_code) for a in audits])


@pytest.mark.parametrize('role,allowed',[(RoleCode.USER,False),(RoleCode.SUPPORT_AGENT,False),
    (RoleCode.FINANCE_SUPPORT,True),(RoleCode.SUPPORT_SUPERVISOR,True),(RoleCode.SUPER_ADMIN,True)])
def test_actual_finance_or_audit_role(api,core,role,allowed):
    with core[1].begin() as s: s.get(UserRole,'role').role_code = role
    response = api[0].get(URL,headers=api[1])
    assert response.status_code == (200 if allowed else 403)


@pytest.mark.parametrize('fault',['missing','sessionless','revoked_family','revoked_device','inactive','expired'])
def test_actual_session_required(api,core,fault):
    client,headers,settings,_ = api
    headers = dict(headers)
    if fault == 'missing': headers = {}
    elif fault in ('sessionless','expired'):
        claims = jwt.decode(headers['Authorization'][7:],settings.jwt_secret,algorithms=['HS256'],options={'verify_aud':False})
        if fault == 'sessionless':
            claims.pop('family_id'); claims.pop('device_id')
            claims['roles'] = ['SUPER_ADMIN']
        else: claims['exp'] = int((datetime.now(timezone.utc)-timedelta(seconds=1)).timestamp())
        headers['Authorization'] = 'Bearer '+jwt.encode(claims,settings.jwt_secret,algorithm='HS256')
    else:
        # 吊销必须命中请求 actor 自己的会话行；表里还有其他用户的行，
        # 无 WHERE 的 select 首行在支付 PIN fixture 引入后不再指向 owner。
        claims = jwt.decode(headers['Authorization'][7:],settings.jwt_secret,algorithms=['HS256'],options={'verify_aud':False})
        with core[1].begin() as s:
            if fault == 'revoked_family': s.get(RefreshTokenFamily,claims['family_id']).revoked_at = datetime.now(timezone.utc)
            elif fault == 'revoked_device': s.get(Device,claims['device_id']).revoked_at = datetime.now(timezone.utc)
            else: s.get(User,'owner').status = AccountStatus.SUSPENDED
    assert client.get(URL,headers=headers).status_code == 401


@pytest.mark.parametrize('params',[{'limit':'0'},{'limit':'101'},{'limit':'1.0'},{'limit':'true'},
    {'cursor':'bad'},{'cursor':'x'*150},{'cursor':''},{'administrator':'true'}])
def test_strict_pagination(api,params):
    assert api[0].get(URL,headers=api[1],params=params).status_code == 422


def test_keyset_pagination_and_missing_order(api,core):
    request(core)
    core[2][0] += timedelta(seconds=1)
    second = request(core,quote(core,idempotency_key='q2'),idempotency_key='r2')
    first = api[0].get(URL,headers=api[1],params={'limit':'1'}).json()
    assert first['items'][0]['id'] == second['id']
    next_page = api[0].get(URL,headers=api[1],params={'limit':'1','cursor':first['next_cursor']}).json()
    assert next_page['items'][0]['id'] != second['id'] and next_page['next_cursor'] is None
    assert api[0].get(URL+'/missing',headers=api[1]).status_code == 404


def test_no_financial_write_routes(api,core):
    order = request(core)
    for method in ('post','put','patch','delete'):
        assert getattr(api[0],method)(URL+'/'+order['id'],headers=api[1]).status_code == 405
    assert core[0].status(user_id='alice',order_id=order['id'])['status'] == 'REQUESTED'


def test_audit_failure_discloses_no_detail(api,core,monkeypatch):
    from app.modules.audit.writer import AuditWriter
    order = request(core)
    def failure(*args,**kwargs): raise RuntimeError('audit-unavailable')
    monkeypatch.setattr(AuditWriter,'record',failure)
    response = api[0].get(URL+'/'+order['id'],headers=api[1])
    assert response.status_code == 500
    assert core[3] not in response.text


def test_corrected_settlement_preserves_original_candidate_history(api,core):
    order = claim(core)
    core[0].submit_txid(admin_id='owner',order_id=order['id'],txid='a'*64,idempotency_key='original')
    core[0].correct_candidate(admin_id='owner',session_id='session',mfa_proof='123456',order_id=order['id'],
        txid='b'*64,reason_code='OPERATOR_TYPO',idempotency_key='correct')
    observed = replace(evidence(core,txid='b'*64),txid='b'*64)
    core[6].transaction_evidence = lambda txid: observed if txid == 'b'*64 else None
    assert core[0].reconcile(order_id=order['id'])['status'] == 'SETTLED'
    body = api[0].get(URL+'/'+order['id'],headers=api[1]).json()
    assert body['candidate_txid'] == 'a'*64
    assert body['settlement_txid'] == 'b'*64
    assert {c['txid'] for c in body['candidates']} == {'a'*64,'b'*64}
    assert body['snapshot']['target_address'] == core[3]
