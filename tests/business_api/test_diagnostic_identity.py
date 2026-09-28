import re

import pytest
from pydantic import SecretStr

from app.core.config import Settings
from app.api.client_diagnostics import create_client_diagnostics_router


def test_diagnostic_refs_are_stable_domain_separated_and_keyed():
    from app.core.diagnostic_identity import diagnostic_ref

    first = b'0123456789abcdef0123456789abcdef'
    second = b'abcdef0123456789abcdef0123456789'
    subject = diagnostic_ref(first, 'subject', 'immutable-user-id')
    assert re.fullmatch(r'[0-9a-f]{64}', subject)
    assert subject == diagnostic_ref(first, 'subject', 'immutable-user-id')
    assert subject != diagnostic_ref(first, 'subject', 'another-user-id')
    assert subject != diagnostic_ref(first, 'device', 'immutable-user-id')
    assert subject != diagnostic_ref(second, 'subject', 'immutable-user-id')


def test_production_requires_independent_diagnostic_identity_secret():
    base = Settings(environment='test').model_copy(update={
        'environment': 'production',
        'totp_issuer': 'ChatFlow',
        'jwt_secret': 'j' * 32,
        'email_verification_secret': 'e' * 32,
        'password_reset_secret': 'p' * 32,
        'synapse_admin_access_token': 's' * 32,
        'matrix_provision_secret': 'm' * 32,
        'avatar_url_signing_secret': 'a' * 32,
        'referral_code_secret': 'r' * 32,
        'matrix_public_homeserver_url': 'https://matrix.example.test',
        'avatar_public_base_url': 'https://images.example.test',
    })
    with pytest.raises(ValueError, match='BUSINESS_DIAGNOSTIC_IDENTITY_SECRET'):
        base.validate_production_secrets()
    with pytest.raises(ValueError, match='BUSINESS_DIAGNOSTIC_IDENTITY_SECRET'):
        base.model_copy(update={
            'diagnostic_identity_secret': SecretStr('short'),
        }).validate_production_secrets()
    configured = base.model_copy(update={
        'diagnostic_identity_secret': SecretStr('d' * 32),
        'diagnostic_identity_previous_secret': SecretStr('x' * 32),
    })
    configured.validate_production_secrets()
    with pytest.raises(ValueError, match='BUSINESS_DIAGNOSTIC_IDENTITY_SECRET'):
        configured.model_copy(update={
            'diagnostic_identity_previous_secret': SecretStr('d' * 32),
        }).validate_production_secrets()
    with pytest.raises(ValueError, match='BUSINESS_DIAGNOSTIC_IDENTITY_SECRET'):
        configured.model_copy(update={
            'diagnostic_identity_secret': SecretStr('j' * 32),
        }).validate_production_secrets()


def test_blank_example_secret_uses_process_local_key_in_development():
    settings = Settings(environment='development', diagnostic_identity_secret='')
    router = create_client_diagnostics_router(settings, None, None)
    assert router.routes
