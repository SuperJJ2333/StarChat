"""Binding rejection has no send side effects and leaves ownership proofs usable."""
import sqlite3

import pytest
from sqlalchemy import event, select
from sqlalchemy.exc import IntegrityError

from app.core.errors import AppError
from app.modules.identity.models import OtpChallenge, User
from app.modules.identity.phone import PhoneAuthService
from test_account_credentials import env, service, email_code


def phone_service(env):
    return PhoneAuthService(env[0], otp=env[1], now=lambda: env[5][0])


def verified_phone(env):
    api = phone_service(env)
    api.request_old_channel_verification(user_id='alice')
    api.confirm_old_channel(user_id='alice', code=env[4].messages[-1][1])
    return api


@pytest.mark.parametrize('target,expected', [('13800000001', 'PHONE_UNCHANGED'), ('13800000002', 'PHONE_TAKEN')])
def test_rejected_phone_does_not_issue_or_consume_old_proof(env, target, expected):
    api = verified_phone(env)
    sends = len(env[4].messages)
    with pytest.raises(AppError) as failure:
        api.request_new_phone_verification(user_id='alice', new_phone=target)
    assert failure.value.code == expected
    assert len(env[4].messages) == sends
    with env[0]() as session:
        assert session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'phone_rebind_new')) is None
    api.request_new_phone_verification(user_id='alice', new_phone='13900000003')
    assert len(env[4].messages) == sends + 1


@pytest.mark.parametrize('target,expected', [(' ALICE@example.test ', 'EMAIL_UNCHANGED'), ('BOB@example.test', 'EMAIL_TAKEN')])
def test_rejected_email_does_not_issue_and_allows_corrected_request(env, target, expected):
    api = service(env)
    api.request_old_email_channel(user_id='alice')
    api.confirm_old_email_channel(user_id='alice', code=email_code(env, 'email_bind_old_email'))
    with pytest.raises(AppError) as failure:
        api.request_new_email(user_id='alice', email=target)
    assert failure.value.code == expected
    with env[0]() as session:
        assert session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'email_bind_new')) is None
    assert api.request_new_email(user_id='alice', email='free@example.test')['accepted']


def test_phone_issue_rechecks_occupancy_before_sending(env, monkeypatch):
    api = verified_phone(env)
    original = env[1].issue
    sends = len(env[4].messages)
    def occupy_then_issue(**kwargs):
        with env[0].begin() as session:
            session.get(User, 'bob').phone_normalized = '+8613900000003'
        return original(**kwargs)
    monkeypatch.setattr(env[1], 'issue', occupy_then_issue)
    with pytest.raises(AppError) as failure:
        api.request_new_phone_verification(user_id='alice', new_phone='13900000003')
    assert failure.value.code == 'PHONE_TAKEN'
    assert len(env[4].messages) == sends


def test_phone_issue_rechecks_old_proof_before_sending(env, monkeypatch):
    from datetime import timedelta
    api = verified_phone(env)
    original = env[1].issue
    sends = len(env[4].messages)
    def expire_then_issue(**kwargs):
        env[5][0] += timedelta(minutes=6)
        return original(**kwargs)
    monkeypatch.setattr(env[1], 'issue', expire_then_issue)
    with pytest.raises(AppError) as failure:
        api.request_new_phone_verification(user_id='alice', new_phone='13900000003')
    assert failure.value.code == 'REBIND_OLD_VERIFICATION_REQUIRED'
    assert len(env[4].messages) == sends


@pytest.mark.parametrize('constraint', ['phone', 'email'])
def test_phone_commit_maps_only_phone_unique_conflict(env, monkeypatch, constraint):
    api = verified_phone(env)
    api.request_new_phone_verification(user_id='alice', new_phone='13900000003')
    code = env[4].messages[-1][1]
    # A database commit conflict after the service's query is the losing race.
    def conflict(session):
        raise IntegrityError('UPDATE users', {}, sqlite3.IntegrityError(
            f'UNIQUE constraint failed: users.{constraint}_normalized'))
    event.listen(env[0], 'before_commit', conflict)
    try:
        if constraint == 'phone':
            with pytest.raises(AppError) as failure:
                api.confirm_new_phone(user_id='alice', new_phone='13900000003', code=code)
            assert failure.value.code == 'PHONE_TAKEN'
        else:
            with pytest.raises(IntegrityError):
                api.confirm_new_phone(user_id='alice', new_phone='13900000003', code=code)
    finally:
        event.remove(env[0], 'before_commit', conflict)
    with env[0]() as session:
        assert session.get(User, 'alice').phone_normalized == '+8613800000001'
        challenge = session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'phone_rebind_new'))
        assert challenge.consumed_at is None
    assert api.confirm_new_phone(user_id='alice', new_phone='13900000003', code=code)['verified']
