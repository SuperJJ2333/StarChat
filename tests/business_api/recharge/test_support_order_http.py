import pytest
from types import SimpleNamespace
from decimal import Decimal
from test_review_flow_api import env, get, post  # noqa: F401
from app.modules.identity.tokens import TokenService
from app.modules.identity.models import RefreshTokenFamily, AdminSession
from sqlalchemy import select


def test_passwordless_staff_can_claim_but_app_token_and_revoked_session_cannot(env):
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
        grant=session.get(RefreshTokenFamily, session.get(AdminSession, 'agent').family_id)
        grant.revoked_at=service._utcnow()
    rejected=post(app,headers['agent'],route.replace('/claim','/heartbeat'),{'claim_token':token})
    assert rejected.status_code==401,rejected.text


def test_management_session_replacement_blocks_recharge_reads(env):
    app,factory,_,headers=env
    tokens=TokenService(factory,jwt_secret='test-jwt-secret-at-least-thirty-two-bytes',jwt_issuer='test')
    tokens.issue_admin_pair(user_id='agent',display_name='another support browser')
    assert get(app,headers['agent'],'/api/v1/recharge/admin/requests/pending').status_code==401


def test_support_security_is_unlocked_without_credentials_or_grant(env):
    app, factory, _, headers = env
    from app.modules.identity.operation_password_models import AdminOperationCredential
    from app.modules.identity.wallet_grant_models import WalletAccessGrant
    with factory() as session:
        assert session.scalar(select(AdminOperationCredential)) is None
        assert session.scalar(select(WalletAccessGrant)) is None
    response = get(app, headers['agent'], '/api/v1/admin/support-orders/security')
    assert response.status_code == 200, response.text
    assert response.json()['verified'] is True
    assert response.json()['auth_mode'] == 'session'
    assert response.json()['grant_id'] is None


@pytest.mark.parametrize('change', ['disabled', 'unactivated', 'role', 'contact'])
def test_recharge_reads_recheck_current_staff_identity(env, change):
    from app.modules.identity.models import User, UserRole
    from app.modules.identity.staff_activation import StaffActivation
    app, factory, _, headers = env
    with factory.begin() as session:
        if change == 'disabled':
            session.get(User, 'agent').status = 'DISABLED'
        elif change == 'unactivated':
            session.delete(session.get(StaffActivation, 'agent'))
        elif change == 'role':
            session.delete(session.get(UserRole, 'r-agent'))
        else:
            session.get(User, 'agent').email_normalized = 'changed@example.test'
    response = get(app, headers['agent'], '/api/v1/recharge/admin/requests/pending')
    assert response.status_code in (401, 403), response.text
