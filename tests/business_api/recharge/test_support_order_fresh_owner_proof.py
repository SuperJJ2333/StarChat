"""A support-order takeover needs a new owner proof for this request."""
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest

from app.api.admin_wallet_auth import AdminWalletProofBody
from app.core.config import Settings
from app.core.errors import AppError
from app.modules.identity.enums import RoleCode
from app.modules.identity.models import User, UserRole
from app.modules.identity.operation_password import AdminWalletOperationPasswordService
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.tokens import TokenService
from app.modules.identity.support_order_auth import fresh_owner_proof_authorization
from test_review_flow_api import env, get, post  # noqa: F401


def owner_setup(env):
    app, factory, _, _ = env
    now = [datetime.now(timezone.utc)]
    with factory.begin() as session:
        session.get(User, 'root').password_hash = PasswordHasher().hash('owner-login-password')
    tokens = TokenService(factory, jwt_secret='test-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=Settings.model_fields['jwt_issuer'].default, require_session_claims=True)
    pair = tokens.issue_admin_pair(user_id='root', display_name='owner test', admin_only=True)
    claims = tokens.decode_access_token(pair.access_token)
    now[0] = datetime.now(timezone.utc)
    settings = SimpleNamespace(wallet_manual_owner_admin_id='root',
        wallet_admin_auth_mode='operation_password', wallet_access_grant_enabled=True)
    service = AdminWalletOperationPasswordService(factory, owner_id=lambda: 'root',
        auth_mode=lambda: settings.wallet_admin_auth_mode, clock=lambda: now[0],
        scope='support-orders')
    service.set_password(claims=claims, login_password='owner-login-password',
        new_operation_password='owner-operation-password', idempotency_key='set-owner-password')
    return factory, now, settings, claims, pair.access_token


def test_owner_proof_ignores_old_grant_and_expires_after_30_seconds(env):
    factory, now, settings, claims, _ = owner_setup(env)
    proof = AdminWalletProofBody(operation_password='owner-operation-password')
    authorize = fresh_owner_proof_authorization(settings, factory, lambda: now[0], claims, proof)
    with factory.begin() as session:
        authorize(session)()
    settings.wallet_admin_auth_mode = 'totp'
    with factory.begin() as session, pytest.raises(AppError):
        authorize(session)()
    settings.wallet_admin_auth_mode = 'operation_password'
    now[0] += timedelta(seconds=31)
    with factory.begin() as session, pytest.raises(AppError):
        authorize(session)()


def test_owner_proof_checks_selected_mode_and_live_role(env):
    factory, now, settings, claims, _ = owner_setup(env)
    with pytest.raises(AppError) as mismatched:
        fresh_owner_proof_authorization(settings, factory, lambda: now[0], claims,
            AdminWalletProofBody(mfa_proof='123456'))
    assert mismatched.value.status_code == 403
    authorize = fresh_owner_proof_authorization(settings, factory, lambda: now[0], claims,
        AdminWalletProofBody(operation_password='owner-operation-password'))
    with factory.begin() as session:
        session.query(UserRole).filter_by(user_id='root', role_code=RoleCode.SUPER_ADMIN).delete()
    with factory.begin() as session, pytest.raises(AppError) as revoked:
        authorize(session)()
    assert revoked.value.status_code in (401, 403)


def test_non_owner_cannot_get_takeover_proof(env):
    factory, now, settings, claims, _ = owner_setup(env)
    settings.wallet_manual_owner_admin_id = 'someone-else'
    with pytest.raises(AppError) as denied:
        fresh_owner_proof_authorization(settings, factory, lambda: now[0], claims,
            AdminWalletProofBody(operation_password='owner-operation-password'))
    assert denied.value.status_code == 403


def test_owner_totp_mode_requires_new_one_time_proof(env):
    from app.modules.identity.totp import TotpService, FernetSecretProtector
    from app.modules.wallet.binding_adapters import WalletTotpVerifier
    factory, now, settings, claims, _ = owner_setup(env)
    settings.wallet_admin_auth_mode = 'totp'
    totp = TotpService(factory, protector=FernetSecretProtector.generate(), now_factory=lambda:now[0])
    enrollment = totp.enroll('root')
    code = totp.code_at(enrollment.secret, now[0])
    totp.enable('root', code)
    verifier = WalletTotpVerifier(totp, SimpleNamespace(hit=lambda *args,**kwargs:None), clock=lambda:now[0])
    authorize = fresh_owner_proof_authorization(settings, factory, lambda: now[0], claims,
        AdminWalletProofBody(mfa_proof=code), mfa_verifier=verifier)
    with factory.begin() as session:
        authorize(session)()
    settings.wallet_admin_auth_mode = 'operation_password'
    with factory.begin() as session, pytest.raises(AppError):
        authorize(session)()
    settings.wallet_admin_auth_mode = 'totp'
    now[0] += timedelta(seconds=31)
    with factory.begin() as session, pytest.raises(AppError):
        authorize(session)()


def test_owner_totp_proof_cannot_survive_credential_replacement(env):
    from app.modules.identity.models import TotpCredential
    from app.modules.identity.totp import TotpService, FernetSecretProtector
    from app.modules.wallet.binding_adapters import WalletTotpVerifier
    factory, now, settings, claims, _ = owner_setup(env)
    settings.wallet_admin_auth_mode = 'totp'
    totp = TotpService(factory, protector=FernetSecretProtector.generate(), now_factory=lambda:now[0])
    enrollment = totp.enroll('root')
    code = totp.code_at(enrollment.secret, now[0])
    totp.enable('root', code)
    verifier = WalletTotpVerifier(totp, SimpleNamespace(hit=lambda *args,**kwargs:None), clock=lambda:now[0])
    authorize = fresh_owner_proof_authorization(settings, factory, lambda:now[0], claims,
        AdminWalletProofBody(mfa_proof=code), mfa_verifier=verifier)
    with factory.begin() as session:
        session.delete(session.get(TotpCredential, enrollment.credential_id))
    with factory.begin() as session, pytest.raises(AppError):
        authorize(session)()


def test_recharge_takeover_route_requires_current_owner_proof_and_rotates_token(env, monkeypatch):
    app, _, _, _ = env
    factory, _, _, _, token = owner_setup(env)
    recharge = app.state.recharge_service
    recharge.settlement_enabled = True
    recharge.official_config = SimpleNamespace(address='isolated-test-address', version='v1')
    from binding_fixture import seed_active_binding
    with factory.begin() as session:
        seed_active_binding(session,user_id='alice',now=recharge._utcnow())
    order = recharge.submit(user_id='alice', amount_usdt='10', idempotency_key='owner-route-order')
    first = recharge.claim_order(request_id=order['id'], actor_id='agent',
        idempotency_key='first-owner-route-claim')
    route = f"/api/v1/recharge/admin/requests/{order['id']}/takeover"
    body = {'expected_claim_version': first['claim_version'],
        'reason_code': 'RECHARGE_SHIFT_HANDOFF',
        'proof': {'operation_password': 'owner-operation-password'}}
    readable = get(app, {'Authorization': 'Bearer ' + token},
        '/api/v1/recharge/admin/requests/pending')
    assert readable.status_code == 200, readable.text
    response = post(app, {'Authorization': 'Bearer ' + token}, route, body)
    assert response.status_code == 200, response.text
    assert response.headers.get('cache-control') == 'no-store'
    assert response.json()['claimed_by'] == 'root'
    assert response.json()['claim_version'] == first['claim_version'] + 1
    def reused_proof(self, **kwargs):
        raise AppError(code='TOTP_REPLAYED', message='proof already consumed', status_code=403)
    monkeypatch.setattr(AdminWalletOperationPasswordService, 'verify', reused_proof)
    replay = post(app, {'Authorization': 'Bearer ' + token}, route, body)
    assert replay.status_code == 200, replay.text
    assert replay.json()['claim_token'] == response.json()['claim_token']
