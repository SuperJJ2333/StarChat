import pytest

from app.core.outbox import OutboxMessage
from main import build_identity_handlers


def test_staff_password_completion_has_dedicated_safe_consumer():
    from tasks.identity import AccountCredentialsObservationTask
    handlers = build_identity_handlers(session_factory=None,
        verification_secret='test-verification-secret', public_base_url='https://example.test',
        email_sender=object())
    assert isinstance(handlers['identity.account_credentials'], AccountCredentialsObservationTask)
    task = handlers['identity.account_credentials']
    valid = OutboxMessage('event', 'identity.account_credentials', 'identity.password.reset', 'user',
        'staff', {'user_id': 'staff', 'reason_code': 'PASSWORD_RESET'}, {}, 1)
    task(valid)
    for payload in ({'user_id': 'staff', 'reason_code': 'PASSWORD_RESET', 'password': 'secret'},
                    {'user_id': 'staff', 'reason_code': 'PASSWORD_RESET', 'email': 'staff@example.test'},
                    {'user_id': 'other', 'reason_code': 'PASSWORD_RESET'}):
        with pytest.raises(ValueError, match='ACCOUNT_CREDENTIALS_EVENT_INVALID'):
            task(OutboxMessage('event', 'identity.account_credentials', 'identity.password.reset',
                'user', 'staff', payload, {}, 1))
