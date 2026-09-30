from datetime import timedelta

import pytest

from test_manual_payouts import core, request  # noqa: F401
from test_support_payout import scoped  # noqa: F401
from app.core.errors import AppError
from app.modules.identity.enums import RoleCode
from app.modules.identity.models import UserRole
from app.modules.identity.support_order_auth import SupportOrderSessionAuthorizer


@pytest.mark.parametrize('action', ['list', 'detail', 'claim'])
def test_finance_staff_cannot_access_admin_payout(scoped, action):
    core, service, claims = scoped
    order = request(core)
    before = core[5].balance('HOLD:alice')
    with pytest.raises(AppError) as error:
        if action == 'list':
            service.list(claims=claims['bob'])
        elif action == 'detail':
            service.detail(claims=claims['bob'], order_id=order['id'])
        else:
            service.claim(claims=claims['bob'], order_id=order['id'], idempotency_key='staff')
    assert error.value.status_code == 403
    assert core[5].balance('HOLD:alice') == before


def test_finance_staff_can_still_use_recharge_order_authorizer(scoped):
    _, service, claims = scoped
    SupportOrderSessionAuthorizer(service.settings, service.factory, service.payout.clock).require(claims=claims['bob'])


def test_non_owner_super_admin_cannot_operate_payout(scoped):
    core, service, claims = scoped
    with service.factory.begin() as session:
        session.add(UserRole(id='bob-super', user_id='bob', role_code=RoleCode.SUPER_ADMIN,
            assigned_by='owner', assigned_at=core[2][0]))
    order = request(core)
    with pytest.raises(AppError):
        service.claim(claims=claims['bob'], order_id=order['id'], idempotency_key='other-admin')


def test_owner_role_revocation_after_lease_denies_start(scoped):
    core, service, claims = scoped
    order = request(core)
    lease = service.claim(claims=claims['owner'], order_id=order['id'], idempotency_key='owner-lease')
    with service.factory.begin() as session:
        for role in session.query(UserRole).filter(UserRole.user_id == 'owner').all():
            session.delete(role)
    with pytest.raises(AppError):
        service.begin_payment(claims=claims['owner'], order_id=order['id'],
            claim_token=lease['claim_token'], expected_digest=order['digest'], idempotency_key='revoked')


def test_owner_admin_can_read_and_lease(scoped):
    core, service, claims = scoped
    order = request(core)
    lease = service.claim(claims=claims['owner'], order_id=order['id'], idempotency_key='owner')
    assert lease['claimed_by'] == 'owner'
    assert service.detail(claims=claims['owner'], order_id=order['id'])['id'] == order['id']


def test_begin_requires_independent_proof_not_only_admin_session(scoped):
    core, service, claims = scoped
    order = request(core)
    lease = service.claim(claims=claims['owner'], order_id=order['id'], idempotency_key='owner')
    with pytest.raises(AppError) as error:
        service.begin_payment(claims=claims['owner'], order_id=order['id'],
            claim_token=lease['claim_token'], expected_digest=order['digest'], idempotency_key='no-proof')
    assert error.value.status_code == 403
    assert core[0].status(user_id='alice', order_id=order['id'])['status'] == 'REQUESTED'
