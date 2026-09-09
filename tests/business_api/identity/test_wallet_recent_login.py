from datetime import datetime, timedelta, timezone

import jwt
import pytest
from sqlalchemy import create_engine, update

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import RefreshTokenFamily, User
from app.modules.identity.tokens import TokenService


def test_recent_login_uses_server_family_not_refreshed_token_iat():
    engine = create_engine('sqlite+pysqlite:///:memory:')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id='operator', username='operator', username_normalized='operator',
            email='operator@example.invalid', email_normalized='operator@example.invalid',
            password_hash='fixture-not-used', status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
    tokens = TokenService(factory, jwt_secret='fixture-'*8, jwt_issuer='fixture', now_factory=lambda: now)
    pair = tokens.issue_pair(user_id='operator', device_key='fixture-device', display_name='fixture')
    assert tokens.require_recent_login(pair.access_token)['sub'] == 'operator'
    with factory.begin() as session:
        session.execute(update(RefreshTokenFamily).values(created_at=now-timedelta(minutes=6)))
    refreshed = tokens.rotate(pair.refresh_token)
    with pytest.raises(AppError) as caught:
        tokens.require_recent_login(refreshed.access_token)
    assert caught.value.code == 'RECENT_LOGIN_REQUIRED'
    engine.dispose()


def test_test_environment_token_without_session_is_not_recent_login():
    engine = create_engine('sqlite+pysqlite:///:memory:')
    Base.metadata.create_all(engine)
    now = datetime.now(timezone.utc)
    tokens = TokenService(create_session_factory(engine), jwt_secret='fixture-'*8,
        jwt_issuer='fixture', require_session_claims=False)
    token = jwt.encode({'sub':'fixture', 'iss':'fixture', 'iat':now,
        'exp':now+timedelta(minutes=10)}, 'fixture-'*8, algorithm='HS256')
    with pytest.raises(AppError) as caught:
        tokens.require_recent_login(token)
    assert caught.value.code == 'RECENT_LOGIN_REQUIRED'
    engine.dispose()
