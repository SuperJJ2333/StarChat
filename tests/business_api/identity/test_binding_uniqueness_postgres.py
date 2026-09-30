"""Real PostgreSQL phone ownership races; all targets and proofs are synthetic."""
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier

import pytest
from sqlalchemy import select, text

from app.core.errors import AppError
from app.modules.identity.models import OtpChallenge, User
from app.modules.identity.phone import PhoneAuthService
from test_account_credentials_postgres import pg_env


def api_for(env):
    return PhoneAuthService(env[0], otp=env[1], now=lambda: env[5][0])


def verify_old(api, env, owner):
    api.request_old_channel_verification(user_id=owner)
    api.confirm_old_channel(user_id=owner, code=env[4].messages[-1][1])


@pytest.mark.parametrize('index_kind', ['metadata', 'migration'])
def test_parallel_phone_commits_have_one_owner_and_known_loser(pg_env, monkeypatch, index_kind):
    factory, otp, _, _, sender, _ = pg_env
    engine = factory.kw['bind']
    assert engine.dialect.name == 'postgresql'
    if index_kind == 'migration':
        # Match the actual 0078 unique partial index, inside this fixture schema.
        with engine.begin() as connection:
            connection.execute(text('ALTER TABLE users DROP CONSTRAINT users_phone_normalized_key'))
            connection.execute(text('CREATE UNIQUE INDEX uq_users_phone_normalized ON users (phone_normalized) WHERE phone_normalized IS NOT NULL'))
    api = api_for(pg_env)
    codes = {}
    for owner in ('alice', 'bob'):
        verify_old(api, pg_env, owner)
        api.request_new_phone_verification(user_id=owner, new_phone='13900000003')
        codes[owner] = sender.messages[-1][1]
    # The normal issuer supersedes the earlier target's challenge. Explicitly
    # construct two live fixture proofs to force the final database race rather
    # than allowing that earlier guard to short-circuit the uniqueness check.
    with factory.begin() as session:
        rows = session.scalars(select(OtpChallenge).where(OtpChallenge.purpose == 'phone_rebind_new')).all()
        assert len(rows) == 2
        for row in rows:
            row.invalidated_at = None
    barrier = Barrier(2)
    require = api._require_new_phone
    def both_read_available(session, owner, target):
        user = require(session, owner, target)
        barrier.wait(timeout=5)
        return user
    monkeypatch.setattr(api, '_require_new_phone', both_read_available)
    def confirm(owner):
        try:
            return api.confirm_new_phone(user_id=owner, new_phone='13900000003', code=codes[owner])
        except AppError as failure:
            return failure.code
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = {owner: pool.submit(confirm, owner) for owner in ('alice', 'bob')}
        results = {owner: future.result(timeout=10) for owner, future in futures.items()}
    assert list(results.values()).count('PHONE_TAKEN') == 1
    winner = next(owner for owner, result in results.items() if isinstance(result, dict) and result['verified'])
    loser = next(owner for owner in results if owner != winner)
    with factory() as session:
        users = session.scalars(select(User).where(User.phone_normalized == '+8613900000003')).all()
        assert [user.id for user in users] == [winner]
        challenges = {row.user_id: row for row in session.scalars(select(OtpChallenge).where(OtpChallenge.purpose == 'phone_rebind_new'))}
        assert challenges[winner].consumed_at is not None
        assert challenges[loser].consumed_at is None
        assert session.get(User, loser).phone_normalized == '+861380000000' + ('1' if loser == 'alice' else '2')
    monkeypatch.setattr(api, '_require_new_phone', require)
    # The losing transaction did not consume the old identity ownership proof.
    api.request_new_phone_verification(user_id=loser, new_phone='13900000004')
    assert api.confirm_new_phone(user_id=loser, new_phone='13900000004', code=sender.messages[-1][1])['verified']


def test_phone_issue_rechecks_committed_occupant_before_delivery(pg_env, monkeypatch):
    api = api_for(pg_env)
    verify_old(api, pg_env, 'alice')
    sends = len(pg_env[4].messages)
    issue = pg_env[1].issue
    def occupy_then_issue(**kwargs):
        with pg_env[0].begin() as session:
            session.get(User, 'bob').phone_normalized = '+8613900000003'
        return issue(**kwargs)
    monkeypatch.setattr(pg_env[1], 'issue', occupy_then_issue)
    with pytest.raises(AppError) as failure:
        api.request_new_phone_verification(user_id='alice', new_phone='13900000003')
    assert failure.value.code == 'PHONE_TAKEN'
    assert len(pg_env[4].messages) == sends
    with pg_env[0]() as session:
        assert session.scalar(select(OtpChallenge).where(OtpChallenge.purpose == 'phone_rebind_new')) is None
        assert session.get(User, 'alice').phone_normalized == '+8613800000001'


def test_normal_phone_challenge_supersession_cannot_transfer_owner(pg_env):
    api = api_for(pg_env)
    for owner in ('alice', 'bob'):
        verify_old(api, pg_env, owner)
        api.request_new_phone_verification(user_id=owner, new_phone='13900000003')
        if owner == 'alice':
            earlier_code = pg_env[4].messages[-1][1]
    with pytest.raises(AppError) as failure:
        api.confirm_new_phone(user_id='alice', new_phone='13900000003', code=earlier_code)
    assert failure.value.code == 'OTP_INVALID'
    assert api.confirm_new_phone(user_id='bob', new_phone='13900000003', code=pg_env[4].messages[-1][1])['verified']
    with pytest.raises(AppError) as failure:
        api.request_new_phone_verification(user_id='alice', new_phone='13900000003')
    assert failure.value.code == 'PHONE_TAKEN'
