"""Settlement aggregates have narrow read access, independent of payout holds."""
from datetime import datetime, timedelta, timezone

import pytest
from test_review_flow_api import env, get  # noqa: F401
from app.modules.identity.models import (
    AdminSession, Device, RefreshTokenFamily, SecurityHold, User, UserRole,
)
from app.modules.identity.staff_activation import StaffActivation
from app.modules.identity.tokens import TokenService

PATH = '/api/v1/recharge/admin/reserve-valuation'
STAFF_FIELDS = {'caibi_face', 'caibi_reference_usdt', 'usdt_obligation'}


@pytest.mark.parametrize('held', [False, True])
def test_finance_staff_reads_only_aggregates_even_with_recovery_hold(env, held):
    app, factory, _, headers = env
    if held:
        now = datetime.now(timezone.utc)
        with factory.begin() as session:
            session.add(SecurityHold(id='hold', user_id='agent', hold_type='WITHDRAWAL',
                reason_code='PASSWORD_RESET', starts_at=now - timedelta(minutes=1),
                ends_at=now + timedelta(days=1), created_at=now))
    result = get(app, headers['agent'], PATH)
    assert result.status_code == 200, result.text
    assert set(result.json()) == STAFF_FIELDS
    assert result.json()['caibi_face'] == '0.00'
    assert result.json()['usdt_obligation'] == '0.000000'
    assert result.json()['caibi_reference_usdt'] is None
    if held:
        blocked = get(app, headers['agent'], '/api/v1/recharge/admin/requests/pending')
        assert blocked.status_code == 403
        assert blocked.json()['error']['code'] == 'WALLET_RECOVERY_HOLD'


@pytest.mark.parametrize('change', [
    'anonymous', 'ordinary_user', 'app_session', 'support_only', 'role_removed',
    'unactivated', 'contact_changed', 'disabled', 'expired', 'replaced',
    'family_revoked', 'device_revoked',
])
def test_reference_read_rejects_invalid_staff_access(env, change):
    app, factory, _, headers = env
    actor_headers = headers['agent']
    tokens = TokenService(factory, jwt_secret='test-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer='liuhetong')
    if change == 'anonymous':
        actor_headers = {}
    elif change == 'ordinary_user':
        actor_headers = headers['alice']
    elif change == 'app_session':
        pair = tokens.issue_pair(user_id='agent', device_key='app', display_name='app')
        actor_headers = {'Authorization': 'Bearer ' + pair.access_token}
    elif change == 'replaced':
        tokens.issue_admin_pair(user_id='agent', display_name='replacement')
    else:
        with factory.begin() as session:
            if change == 'support_only':
                session.get(UserRole, 'r-agent').role_code = 'SUPPORT_AGENT'
            elif change == 'role_removed':
                session.delete(session.get(UserRole, 'r-agent'))
            elif change == 'unactivated':
                session.delete(session.get(StaffActivation, 'agent'))
            elif change == 'contact_changed':
                session.get(User, 'agent').email_normalized = 'changed@example.test'
            elif change == 'disabled':
                session.get(User, 'agent').status = 'DISABLED'
            elif change == 'expired':
                session.get(AdminSession, 'agent').expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
            else:
                family = session.get(RefreshTokenFamily, session.get(AdminSession, 'agent').family_id)
                if change == 'family_revoked':
                    family.revoked_at = datetime.now(timezone.utc)
                else:
                    session.get(Device, family.device_id).revoked_at = datetime.now(timezone.utc)
    result = get(app, actor_headers, PATH)
    assert result.status_code in (401, 403), result.text


def test_administrator_reference_payload_stays_compatible(env):
    app, factory, _, _ = env
    tokens = TokenService(factory, jwt_secret='test-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer='liuhetong')
    pair = tokens.issue_admin_pair(user_id='root', display_name='administrator')
    result = get(app, {'Authorization': 'Bearer ' + pair.access_token}, PATH)
    assert result.status_code == 200
    assert set(result.json()) == STAFF_FIELDS | {'valuation_rate', 'approved_unpaid_usdt'}
