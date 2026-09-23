from types import SimpleNamespace
from decimal import Decimal
from test_review_flow_api import env, get, post  # noqa: F401
from app.modules.identity.tokens import TokenService
from app.modules.identity.wallet_grant_models import WalletAccessGrant
from sqlalchemy import select


def test_real_staff_proof_can_claim_but_app_token_and_revoked_proof_cannot(env):
    app,factory,_,headers=env
    service=app.state.recharge_service
    service.settlement_enabled=True
    service.official_config=SimpleNamespace(address='isolated-test-address',version='v1')
    order=service.submit(user_id='alice',amount_usdt=Decimal('10'),idempotency_key='new-managed')
    route=f"/api/v1/recharge/admin/requests/{order['id']}/claim"
    assert post(app,headers['alice'],route,{}).status_code==401
    claim=post(app,headers['agent'],route,{})
    assert claim.status_code==200,claim.text
    token=claim.json()['claim_token']
    events=get(app,headers['agent'],'/api/v1/recharge/admin/events')
    assert events.status_code==200,events.text
    assert any(item['order_id']==order['id'] for item in events.json()['items'])
    with factory.begin() as session:
        grant=session.scalar(select(WalletAccessGrant).where(WalletAccessGrant.user_id=='agent'))
        grant.revoked_at=service._utcnow()
    rejected=post(app,headers['agent'],route.replace('/claim','/heartbeat'),{'claim_token':token})
    assert rejected.status_code==403,rejected.text


def test_management_session_replacement_blocks_recharge_reads(env):
    app,factory,_,headers=env
    tokens=TokenService(factory,jwt_secret='test-jwt-secret-at-least-thirty-two-bytes',jwt_issuer='test')
    tokens.issue_admin_pair(user_id='agent',display_name='another support browser')
    assert get(app,headers['agent'],'/api/v1/recharge/admin/requests/pending').status_code==401
