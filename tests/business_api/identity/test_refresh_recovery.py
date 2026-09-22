import base64
from datetime import timedelta
import hashlib
import hmac

import pytest
from sqlalchemy import select

from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus
from app.modules.identity.invitations import hash_opaque_token
from app.modules.identity.models import Device, RefreshToken, RefreshTokenFamily, User
from test_tokens_and_recovery import identity_components
from test_mobile_sessions import mobile_sessions
from test_identity_api import api_components


OP = base64.urlsafe_b64encode(bytes(range(32))).decode().rstrip('=')
OTHER_OP = base64.urlsafe_b64encode(bytes(reversed(range(32)))).decode().rstrip('=')


def issue(tokens):
    return tokens.issue_pair(user_id='user-1', device_key='phone', display_name='Phone')


def test_lost_response_recovers_same_result_without_extending_expiry(identity_components):
    factory, tokens, _, _, now = identity_components
    parent = issue(tokens)
    first = tokens.rotate(parent.refresh_token, operation_id=OP)
    expected = base64.urlsafe_b64encode(hmac.new(parent.refresh_token.encode(),
        b'chatflow/mobile-refresh/result/v1\0' + bytes(range(32)), hashlib.sha256).digest()).decode().rstrip('=')
    assert first.refresh_token == expected
    with factory() as session:
        original = session.scalar(select(RefreshToken).where(RefreshToken.token_hash == hash_opaque_token(parent.refresh_token)))
        assert original.operation_hash == hash_opaque_token(OP)
        assert original.result_key_version == 1
        child_id = original.replaced_by_id
        expiry = session.get(RefreshToken, child_id).expires_at
    for days in (1, 2):
        tokens._now_factory = lambda: now + timedelta(days=days)
        retry = tokens.rotate(parent.refresh_token, operation_id=OP)
        assert retry.refresh_token == first.refresh_token
        claims = tokens.decode_access_token(retry.access_token)
        assert claims['exp'] - claims['iat'] == 900
        with factory() as session:
            assert len(list(session.scalars(select(RefreshToken)))) == 2
            assert session.get(RefreshToken, child_id).expires_at == expiry


@pytest.mark.parametrize('operation', [None, OTHER_OP])
def test_mismatched_replay_still_revokes(identity_components, operation):
    factory, tokens, *_ = identity_components
    parent = issue(tokens)
    tokens.rotate(parent.refresh_token, operation_id=OP)
    with pytest.raises(AppError) as failure:
        tokens.rotate(parent.refresh_token, operation_id=operation)
    assert failure.value.code == 'REFRESH_TOKEN_REUSED'
    with factory() as session:
        assert session.get(RefreshTokenFamily, parent.family_id).revoke_reason == 'TOKEN_REUSE'


def test_advanced_result_does_not_revoke_current_session(identity_components):
    factory, tokens, *_ = identity_components
    parent = issue(tokens)
    child = tokens.rotate(parent.refresh_token, operation_id=OP)
    current = tokens.rotate(child.refresh_token, operation_id=OTHER_OP)
    with pytest.raises(AppError) as failure:
        tokens.rotate(parent.refresh_token, operation_id=OP)
    assert (failure.value.code, failure.value.status_code) == ('REFRESH_RESULT_SUPERSEDED', 409)
    assert tokens.decode_access_token(current.access_token)
    with factory() as session:
        assert session.get(RefreshTokenFamily, parent.family_id).revoked_at is None


def test_advanced_expired_child_reports_superseded_with_live_grandchild(identity_components):
    factory, tokens, _, _, now = identity_components
    parent = issue(tokens)
    child = tokens.rotate(parent.refresh_token, operation_id=OP)
    tokens._now_factory = lambda: now + timedelta(days=59)
    current = tokens.rotate(child.refresh_token, operation_id=OTHER_OP)
    tokens._now_factory = lambda: now + timedelta(days=60)
    with pytest.raises(AppError) as failure:
        tokens.rotate(parent.refresh_token, operation_id=OP)
    assert (failure.value.code, failure.value.status_code) == ('REFRESH_RESULT_SUPERSEDED', 409)
    current = tokens.rotate(current.refresh_token, operation_id=OP)
    assert tokens.decode_access_token(current.access_token)
    with factory() as session:
        assert session.get(RefreshTokenFamily, parent.family_id).revoked_at is None


@pytest.mark.parametrize('reason', ['LOGOUT', 'PASSWORD_RESET', 'SESSION_REPLACED', 'DEVICE_REVOKED'])
@pytest.mark.parametrize('operation', [OP, OTHER_OP, None])
def test_prior_revocation_takes_precedence_and_preserves_reason(identity_components, reason, operation):
    factory, tokens, *_ = identity_components
    parent = issue(tokens)
    tokens.rotate(parent.refresh_token, operation_id=OP)
    tokens.revoke_by_refresh_token(parent.refresh_token, reason=reason)
    with pytest.raises(AppError) as failure:
        tokens.rotate(parent.refresh_token, operation_id=operation)
    assert failure.value.code == ('SESSION_REPLACED' if reason == 'SESSION_REPLACED' else 'REFRESH_TOKEN_INVALID')
    with factory() as session:
        assert session.get(RefreshTokenFamily, parent.family_id).revoke_reason == reason


@pytest.mark.parametrize('disabled', ['user', 'device'])
def test_disabled_user_or_device_checked_before_recovery(identity_components, disabled):
    factory, tokens, _, _, now = identity_components
    parent = issue(tokens)
    tokens.rotate(parent.refresh_token, operation_id=OP)
    with factory.begin() as session:
        if disabled == 'user':
            session.get(User, 'user-1').status = AccountStatus.SUSPENDED
        else:
            session.get(Device, parent.device_id).revoked_at = now
    with pytest.raises(AppError) as failure:
        tokens.rotate(parent.refresh_token, operation_id=OP)
    assert failure.value.code == ('ACCOUNT_NOT_ACTIVE' if disabled == 'user' else 'REFRESH_TOKEN_INVALID')
    with factory() as session:
        assert session.get(RefreshTokenFamily, parent.family_id).revoked_at is None


def test_recovery_uses_child_expiry_even_when_parent_expired(identity_components):
    factory, tokens, _, _, now = identity_components
    parent = issue(tokens)
    tokens._now_factory = lambda: now + timedelta(days=59)
    child = tokens.rotate(parent.refresh_token, operation_id=OP)
    tokens._now_factory = lambda: now + timedelta(days=60)
    assert tokens.rotate(parent.refresh_token, operation_id=OP).refresh_token == child.refresh_token
    tokens._now_factory = lambda: now + timedelta(days=119)
    with pytest.raises(AppError) as failure:
        tokens.rotate(parent.refresh_token, operation_id=OP)
    assert failure.value.code == 'REFRESH_TOKEN_EXPIRED'
    with factory() as session:
        assert session.get(RefreshTokenFamily, parent.family_id).revoked_at is None


def test_expired_first_use_reports_expiry_without_consuming(identity_components):
    factory, tokens, _, _, now = identity_components
    parent = issue(tokens)
    tokens._now_factory = lambda: now + timedelta(days=60)
    with pytest.raises(AppError) as failure:
        tokens.rotate(parent.refresh_token, operation_id=OP)
    assert failure.value.code == 'REFRESH_TOKEN_EXPIRED'
    assert failure.value.message == '登录已过期，请重新登录'
    with factory() as session:
        assert session.scalar(select(RefreshToken)).consumed_at is None


@pytest.mark.parametrize('operation', ['', 'secret-operation', OP + '=', OP[:-1] + '9', 'é' * 43, 123])
def test_invalid_operation_never_consumes_or_echoes(identity_components, operation):
    factory, tokens, *_ = identity_components
    parent = issue(tokens)
    with pytest.raises(AppError) as failure:
        tokens.rotate(parent.refresh_token, operation_id=operation)
    assert failure.value.status_code == 422
    assert str(operation) not in str(failure.value) or operation == ''
    with factory() as session:
        assert session.scalar(select(RefreshToken)).consumed_at is None


@pytest.mark.parametrize('corruption', ['version', 'hash', 'missing'])
def test_inconsistent_recovery_metadata_never_creates_result(identity_components, corruption):
    factory, tokens, *_ = identity_components
    parent = issue(tokens)
    tokens.rotate(parent.refresh_token, operation_id=OP)
    with factory.begin() as session:
        record = session.scalar(select(RefreshToken).where(RefreshToken.token_hash == hash_opaque_token(parent.refresh_token)))
        if corruption == 'version':
            record.result_key_version = 2
        elif corruption == 'missing':
            record.replaced_by_id = 'missing'
        else:
            session.get(RefreshToken, record.replaced_by_id).token_hash = '0' * 64
    with pytest.raises(AppError):
        tokens.rotate(parent.refresh_token, operation_id=OP)
    with factory() as session:
        assert len(list(session.scalars(select(RefreshToken)))) == 2


def test_legacy_replay_does_not_overwrite_logout_reason(identity_components):
    factory, tokens, *_ = identity_components
    parent = issue(tokens)
    tokens.rotate(parent.refresh_token)
    tokens.revoke_by_refresh_token(parent.refresh_token)
    with pytest.raises(AppError):
        tokens.rotate(parent.refresh_token)
    with factory() as session:
        assert session.get(RefreshTokenFamily, parent.family_id).revoke_reason == 'LOGOUT'


def test_mobile_recovery_cannot_consume_admin_token(mobile_sessions):
    factory, tokens = mobile_sessions
    admin = tokens.issue_admin_pair(user_id='alice', display_name='Browser')
    with pytest.raises(AppError) as failure:
        tokens.rotate(admin.refresh_token, operation_id=OP)
    assert failure.value.code == 'REFRESH_TOKEN_INVALID'
    rotated = tokens.rotate_admin(admin.refresh_token)
    with pytest.raises(AppError):
        tokens.rotate_admin(admin.refresh_token)
    with factory() as session:
        assert session.get(RefreshTokenFamily, rotated.family_id).revoke_reason == 'TOKEN_REUSE'


@pytest.mark.asyncio
async def test_api_recovery_and_safe_validation(api_components):
    from httpx import AsyncClient, ASGITransport
    app, factory = api_components
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        login = await client.post('/api/v1/auth/login', json=dict(username='active',
            password='correct horse battery staple', device_key='phone', device_name='Phone'))
        assert login.status_code == 200
        parent = login.json()['refresh_token']
        invalid = await client.post('/api/v1/auth/refresh', json=dict(refresh_token=parent, operation_id='private-malformed-nonce'))
        assert invalid.status_code == 422
        assert 'private-malformed-nonce' not in invalid.text
        with factory() as session:
            assert session.scalar(select(RefreshToken)).consumed_at is None
        body = dict(refresh_token=parent, operation_id=OP)
        first = await client.post('/api/v1/auth/refresh', json=body)
        assert first.status_code == 200
        retry = await client.post('/api/v1/auth/refresh', json=body)
        assert retry.status_code == 200
        assert first.json()['refresh_token'] == retry.json()['refresh_token']
        assert (await client.post('/api/v1/auth/logout', json=body)).status_code == 422


@pytest.mark.asyncio
async def test_legacy_strict_refresh_model_returns_422_without_consumption(identity_components):
    from fastapi import FastAPI
    from httpx import AsyncClient, ASGITransport
    from app.api.identity import RefreshRequest
    factory, tokens, *_ = identity_components
    parent = issue(tokens)
    app = FastAPI()
    @app.post('/legacy-refresh')
    def legacy_refresh(body: RefreshRequest):
        tokens.rotate(body.refresh_token)
        return {}
    async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
        response = await client.post('/legacy-refresh', json=dict(refresh_token=parent.refresh_token, operation_id=OP))
    assert response.status_code == 422
    with factory() as session:
        assert session.scalar(select(RefreshToken)).consumed_at is None


@pytest.mark.parametrize('action', ['issue', 'bind'])
@pytest.mark.parametrize('state,code', [('missing', 'ACCESS_TOKEN_INVALID'),
    ('logout', 'ACCESS_TOKEN_INVALID'), ('suspended', 'ACCOUNT_NOT_ACTIVE'),
    ('device', 'ACCESS_TOKEN_INVALID'), ('replaced', 'SESSION_REPLACED')])
def test_matrix_failure_reports_actual_cause(identity_components, action, state, code):
    from app.modules.identity.matrix_login import MatrixLoginTokenService
    from app.modules.identity.matrix_sessions import MatrixSessionService
    factory, tokens, _, _, now = identity_components
    parent = issue(tokens)
    family_id = parent.family_id
    with factory.begin() as session:
        if state == 'missing':
            family_id = 'missing'
        elif state == 'suspended':
            session.get(User, 'user-1').status = AccountStatus.SUSPENDED
        elif state == 'device':
            session.get(Device, parent.device_id).revoked_at = now
        else:
            family = session.get(RefreshTokenFamily, family_id)
            family.revoked_at = now
            family.revoke_reason = 'LOGOUT' if state == 'logout' else 'SESSION_REPLACED'
    with pytest.raises(AppError) as failure:
        if action == 'issue':
            MatrixLoginTokenService(factory, gateway=None, public_homeserver_url='https://matrix.invalid',
                expires_in=60).issue('user-1', family_id=family_id)
        else:
            MatrixSessionService(factory, gateway=None).bind(user_id='user-1', family_id=family_id,
                matrix_access_token='unused', matrix_device_id='unused')
    assert failure.value.code == code
    assert '其他设备' not in failure.value.message


def test_terminal_server_diagnostic_is_fixed_and_contains_no_credentials(identity_components, caplog):
    import logging
    factory, tokens, *_ = identity_components
    parent = issue(tokens)
    child = tokens.rotate(parent.refresh_token, operation_id=OP)
    with caplog.at_level(logging.INFO, logger='app.modules.identity.tokens'):
        with pytest.raises(AppError):
            tokens.rotate(parent.refresh_token, operation_id=OTHER_OP)
    records = [record for record in caplog.records if record.name == 'app.modules.identity.tokens']
    assert len(records) == 1
    assert records[0].getMessage() == 'mobile_refresh terminal_invalidated TOKEN_REUSE 401'
    for secret in (parent.refresh_token, child.refresh_token, OP, OTHER_OP,
            hash_opaque_token(OP), parent.device_id, parent.family_id, 'user-1'):
        assert secret not in caplog.text
    caplog.clear()
    with caplog.at_level(logging.INFO, logger='app.modules.identity.tokens'):
        with pytest.raises(AppError):
            tokens.rotate('random-unknown-token', operation_id=OP)
    assert not caplog.records
