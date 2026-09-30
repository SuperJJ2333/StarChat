from decimal import Decimal

import pytest
from app.core.errors import AppError
from app.modules.wallet.support_payout import SupportPayoutState
from app.modules.wallet.manual_payout_models import ManualPayoutOrder
from test_manual_payouts import core, request
from test_support_payout import scoped
from test_support_payout_discovery import started, receipt


def proof(session):
    return lambda: None


def test_unstarted_takeover_requires_proof_rotates_and_replays(scoped):
    core, service, claims = scoped
    order = request(core)
    old = service.claim(claims=claims['bob'], order_id=order['id'], idempotency_key='old-claim')
    args = dict(claims=claims['owner'], order_id=order['id'], expected_claim_version=1,
        reason_code='SUPPORT_OWNER_RECOVERY', idempotency_key='takeover')
    with pytest.raises(AppError):
        service.takeover(**args)
    result = service.takeover(**args, owner_authorize=proof)
    assert result['claim_token'] != old['claim_token'] and result['claim_version'] == 2
    assert service.takeover(**args)['claim_token'] == result['claim_token']
    with pytest.raises(AppError):
        service.heartbeat(claims=claims['bob'], order_id=order['id'], claim_token=old['claim_token'])
    assert result['can_begin'] and not result['can_evidence']


def test_started_takeover_only_evidence_revokes_old_token_and_preserves_payment(scoped):
    core, service, claims = scoped
    order, old = started(scoped)
    result = service.takeover(claims=claims['owner'], order_id=order['id'], expected_claim_version=1,
        reason_code='SUPPORT_OWNER_RECOVERY', idempotency_key='evidence-takeover', owner_authorize=proof)
    token = result['evidence_token']
    assert result['can_evidence'] and not result['can_begin']
    for actor, value in [('bob', old['claim_token']), ('owner', token)]:
        with pytest.raises(AppError):
            service.begin_payment(claims=claims[actor], order_id=order['id'], claim_token=value,
                expected_digest=order['digest'], idempotency_key='bad-begin-'+actor)
    with pytest.raises(AppError):
        service.read_payment_address(claims=claims['bob'], order_id=order['id'], claim_token=old['claim_token'])
    with pytest.raises(AppError):
        service.submit_txid(claims=claims['bob'], order_id=order['id'], claim_token=old['claim_token'],
            txid='a'*64, idempotency_key='old-txid')
    assert service.read_payment_address(claims=claims['owner'], order_id=order['id'], claim_token=token)['target_address'] == core[3]
    core[6].evidence = receipt(core)
    service.submit_txid(claims=claims['owner'], order_id=order['id'], claim_token=token,
        txid='a'*64, idempotency_key='new-txid')
    assert service.reconcile(claims=claims['owner'], order_id=order['id'], claim_token=token)['status'] == 'SETTLED'
    with core[1]() as session:
        assert session.get(ManualPayoutOrder, order['id']).claimed_by == 'bob'
        assert session.get(SupportPayoutState, order['id']).claimed_by == 'bob'


def test_projection_disables_other_staff_and_owner_requires_fresh_proof(scoped):
    _, service, claims = scoped
    order = request(scoped[0])
    service.claim(claims=claims['owner'], order_id=order['id'], idempotency_key='owner-claim')
    staff = service.detail(claims=claims['bob'], order_id=order['id'])
    assert not any(staff[name] for name in ('can_claim','can_takeover','can_begin','can_evidence'))
    owner = service.detail(claims=claims['owner'], order_id=order['id'])
    assert owner['owner_proof_required']


@pytest.mark.asyncio
async def test_http_takeover_requires_live_owner_nested_new_proof_and_exact_replay(scoped):
    from fastapi import FastAPI
    from httpx import ASGITransport, AsyncClient
    from types import SimpleNamespace
    from app.api.support_payout import create_support_payout_router
    from app.core.config import Settings
    from app.core.errors import install_error_handlers
    from app.modules.identity.operation_password import AdminWalletOperationPasswordService
    from app.modules.identity.operation_password_models import AdminOperationAttempt, AdminOperationCommand, AdminOperationCredential
    from app.core.database import Base
    from app.modules.identity.tokens import TokenService
    from app.modules.identity.models import UserRole
    from sqlalchemy import select
    core, service, claims = scoped
    Base.metadata.create_all(core[1].kw['bind'], tables=[AdminOperationAttempt.__table__,
        AdminOperationCommand.__table__, AdminOperationCredential.__table__], checkfirst=True)
    passwords = AdminWalletOperationPasswordService(core[1], owner_id=lambda:'owner',
        auth_mode=lambda:'operation_password', clock=lambda:core[2][0], scope='support-orders')
    passwords.set_password(claims=claims['owner'], login_password='correct login password',
        new_operation_password='operation-password-123', idempotency_key='takeover-password-setup')
    settings = Settings(_env_file=None, environment='test',
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes').model_copy(update=vars(service.settings))
    tokens = TokenService(core[1],jwt_secret=settings.jwt_secret,jwt_issuer=settings.jwt_issuer,
        now_factory=lambda:core[2][0])
    owner_pair = tokens.issue_admin_pair(user_id='owner',display_name='Browser')
    staff_pair = tokens.issue_admin_pair(user_id='bob',display_name='Browser')
    order = request(core)
    service.claim(claims=tokens.decode_access_token(staff_pair.access_token),order_id=order['id'],idempotency_key='http-old')
    app=FastAPI(); install_error_handlers(app)
    app.include_router(create_support_payout_router(settings,core[1],runtime=SimpleNamespace(
        payouts=core[0],payout_execution_enabled=True)),prefix='/api/v1')
    path='/api/v1/admin/support-orders/payouts/'+order['id']+'/takeover'
    body=dict(expected_claim_version=1,reason_code='SUPPORT_OWNER_RECOVERY')
    headers={'Authorization':'Bearer '+owner_pair.access_token,'Idempotency-Key':'http-takeover'}
    async with AsyncClient(transport=ASGITransport(app=app),base_url='https://test') as client:
        assert (await client.post(path,headers=headers,json=body)).status_code in (401,403)
        assert (await client.post(path,headers=headers,json=body|{'proof':{'mfa_proof':'123456'}})).status_code==403
        assert (await client.post(path,headers=headers,json=body|{'operation_password':'operation-password-123'})).status_code==422
        staff_headers=headers|{'Authorization':'Bearer '+staff_pair.access_token}
        assert (await client.post(path,headers=staff_headers,json=body|{'proof':{'operation_password':'operation-password-123'}})).status_code==403
        result=await client.post(path,headers=headers,json=body|{'proof':{'operation_password':'operation-password-123'}})
        assert result.status_code==200, result.text
        assert result.headers['Cache-Control']=='no-store' and core[3] not in result.text
        assert (await client.post(path,headers=headers,json=body)).json()==result.json()
        with core[1].begin() as session:
            session.delete(session.scalar(select(UserRole).where(UserRole.user_id=='owner')))
        assert (await client.post(path,headers=headers,json=body)).status_code in (401,403)
