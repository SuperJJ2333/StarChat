from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine, select

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.modules.wallet.binding import WalletBindingService, VerifiedBindingBarrier
from app.modules.wallet.binding_models import WalletBinding, WalletBindingChallenge
from app.modules.wallet.models import WalletControl
from app.modules.wallet.funding import DepositIntentService, OfficialFundingConfig
from app.modules.wallet.funding_models import DepositIntent
from app.integrations.tron.message_signature import TronMessageVerifier, address_from_public_key, message_digest


@pytest.fixture
def core():
    from coincurve import PrivateKey
    engine = create_engine('sqlite://')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    with factory.begin() as session:
        session.add(WalletControl(id='global', withdrawals_paused=True))
    now = [datetime(2026, 9, 7, tzinfo=timezone.utc)]
    keys = [PrivateKey() for _ in range(3)]
    addresses = [address_from_public_key(k.public_key.format(compressed=False)) for k in keys]
    service = WalletBindingService(factory, domain='wallet.example.test', clock=lambda: now[0],
        mfa_verifier=lambda **kw: kw['proof'] == 'verified-test-mfa',
        permission_verifier=lambda **kw: True)
    yield service, factory, now, keys, addresses
    engine.dispose()


def sign(key, message):
    raw = key.sign_recoverable(message_digest(message), hasher=None)
    return (raw[:64] + bytes([raw[64] + 27])).hex()


def test_address_registration_is_explicit_and_replay_safe(core):
    service, factory, now, keys, addresses = core
    args = dict(user_id='alice', session_id='session', address=addresses[0],
        expected_version=0, idempotency_key='register-1')
    with pytest.raises(AppError): service.register_address(**args)
    service.address_registration_enabled = True
    result = service.register_address(**args)
    assert result['status'] == 'PENDING'
    assert service.register_address(**args) == result
    with pytest.raises(AppError):
        service.register_address(**{**args, 'address': addresses[1]})
    with factory() as db:
        assert len(db.scalars(select(WalletBinding)).all()) == 1
    enable_barrier(service)
    service.permission_verifier = None
    assert service.activate_pending(user_id='alice', binding_id=result['id'])['status'] == 'ACTIVE'
    assert service.status('alice')['address'] == addresses[0]
    assert service.status('bob')['address'] is None


def test_address_registration_rejects_bad_checksum(core):
    service, *_ = core
    service.address_registration_enabled = True
    with pytest.raises(AppError, match='WALLET_ADDRESS_INVALID'):
        service.register_address(user_id='alice', session_id='session', address='T'+'1'*33,
            expected_version=0, idempotency_key='invalid-address')


def pending(core, index=0, version=0, suffix='1', old_index=None):
    service, _, _, keys, addresses = core
    c = service.challenge(user_id='alice', session_id='session', address=addresses[index],
        expected_version=version, idempotency_key='challenge-' + suffix)
    return service.confirm(user_id='alice', session_id='session', challenge_id=c['id'],
        signature=sign(keys[index], c['message']),
        old_signature=sign(keys[old_index], c['message']) if old_index is not None else None,
        mfa_proof='verified-test-mfa', idempotency_key='confirm-' + suffix)


def enable_barrier(service, height=100):
    service.barrier_verifier = lambda **kw: VerifiedBindingBarrier(
        height=height, block_id=f'{height:064x}', network='tron-mainnet',
        source_ids=('independent-a', 'independent-b'), binding_id=kw['binding'].id,
        observed_at=kw['now'])


def test_barrier_timestamp_uses_clock_after_network_read(core):
    service, _, now, _, _ = core
    first = pending(core)
    def read_barrier(**kw):
        now[0] += timedelta(seconds=2)
        return VerifiedBindingBarrier(height=100, block_id='a'*64, network='tron-mainnet',
            source_ids=('independent-a', 'independent-b'), binding_id=kw['binding'].id,
            observed_at=now[0])
    service.barrier_verifier = read_barrier
    assert service.activate_pending(user_id='alice', binding_id=first['id'])['status'] == 'ACTIVE'


@pytest.mark.parametrize('source_ids, evidence_policy, accepted', [
    (('trongrid-mainnet',), 'TRONGRID_SINGLE_SOURCE_V1', True),
    (('other-source',), 'TRONGRID_SINGLE_SOURCE_V1', False),
    (('trongrid-mainnet', 'other-source'), 'TRONGRID_SINGLE_SOURCE_V1', False),
    (('trongrid-mainnet',), 'INDEPENDENT_V1', False),
])
def test_explicit_single_source_policy_is_persisted_and_not_inferred(core, source_ids, evidence_policy, accepted):
    original, factory, now, keys, addresses = core
    service = WalletBindingService(factory, domain=original.domain, clock=lambda: now[0],
        mfa_verifier=original.mfa_verifier, permission_verifier=original.permission_verifier,
        finality_policy='TRONGRID_SINGLE_SOURCE_V1')
    first = pending((service, factory, now, keys, addresses))
    service.barrier_verifier = lambda **kw: VerifiedBindingBarrier(height=100, block_id='a'*64,
        network='tron-mainnet', source_ids=source_ids, binding_id=kw['binding'].id,
        observed_at=kw['now'], policy=evidence_policy)
    if accepted:
        service.activate_pending(user_id='alice', binding_id=first['id'])
        with factory() as session:
            assert session.get(WalletBinding, first['id']).barrier_policy == 'TRONGRID_SINGLE_SOURCE_V1'
    else:
        with pytest.raises(AppError, match='WALLET_BINDING_BARRIER_INVALID'):
            service.activate_pending(user_id='alice', binding_id=first['id'])


@pytest.mark.parametrize('fail_activation_audit', [False, True])
def test_rebind_closes_deposit_intent_atomically(core, monkeypatch, fail_activation_audit):
    service, factory, now, _, addresses = core
    first = pending(core)
    enable_barrier(service)
    service.activate_pending(user_id='alice', binding_id=first['id'])
    funding = DepositIntentService(factory,
        official_config=OfficialFundingConfig(addresses[2], 'isolated-config-v1'),
        intent_ttl=timedelta(minutes=20), clock=lambda: now[0])
    intent = funding.create(user_id='alice', expected_amount='10.000000',
        expected_binding_version=1, idempotency_key='deposit-before-rebind')
    second = pending(core, index=1, version=1, suffix='2', old_index=0)
    enable_barrier(service, 200)
    if fail_activation_audit:
        import app.modules.wallet.binding as binding_module
        real_audit = binding_module.audit_write

        def fail_audit(session, actor, subject, action, reason):
            if action == 'wallet.binding_activated':
                raise RuntimeError('isolated audit failure')
            return real_audit(session, actor, subject, action, reason)

        monkeypatch.setattr(binding_module, 'audit_write', fail_audit)
        with pytest.raises(RuntimeError, match='isolated audit failure'):
            service.activate_pending(user_id='alice', binding_id=second['id'])
    else:
        service.activate_pending(user_id='alice', binding_id=second['id'])
    with factory() as session:
        row = session.get(DepositIntent, intent['id'])
        assert row.status == ('OPEN' if fail_activation_audit else 'CLOSED_BY_REBIND')
        assert (row.closed_at is None) == fail_activation_audit
        assert row.source_address == addresses[0]
        assert row.binding_id == first['id']
        assert session.get(WalletBinding, first['id']).status == ('ACTIVE' if fail_activation_audit else 'RETIRED')


def test_proof_stays_pending_without_trusted_barrier(core):
    service, factory, _, _, _ = core
    result = pending(core)
    assert result['status'] == 'PENDING'
    with pytest.raises(AppError, match='WALLET_BINDING_BARRIER_UNAVAILABLE'):
        service.activate_pending(user_id='alice', binding_id=result['id'])
    with factory() as session:
        assert session.get(WalletBinding, result['id']).effective_from_block is None
        assert session.scalar(select(WalletBindingChallenge)).consumed_at is not None


def test_replay_is_stable_and_payload_bound(core):
    first = pending(core)
    assert pending(core) == first
    service, _, _, keys, _ = core
    with pytest.raises(AppError, match='WALLET_IDEMPOTENCY_CONFLICT'):
        service.confirm(user_id='alice', session_id='session', challenge_id='other',
            signature='00', old_signature=None, mfa_proof='verified-test-mfa', idempotency_key='confirm-1')


def test_expired_and_cross_session_proof_does_not_consume_nonce(core):
    service, factory, now, keys, addresses = core
    c = service.challenge(user_id='alice', session_id='session', address=addresses[0], expected_version=0, idempotency_key='c')
    for session_id in ('other', 'session'):
        if session_id == 'session':
            now[0] += timedelta(minutes=5)
        with pytest.raises(AppError):
            service.confirm(user_id='alice', session_id=session_id, challenge_id=c['id'],
                signature=sign(keys[0], c['message']), old_signature=None, mfa_proof='verified-test-mfa', idempotency_key=session_id)
    with factory() as session:
        assert session.get(WalletBindingChallenge, c['id']).consumed_at is None


def test_rebind_requires_old_key_and_exact_thirty_days(core):
    service, factory, now, _, _ = core
    first = pending(core)
    enable_barrier(service)
    service.activate_pending(user_id='alice', binding_id=first['id'])
    with pytest.raises(AppError, match='WALLET_OLD_SIGNATURE_REQUIRED'):
        pending(core, 1, 1, '2')
    second = pending(core, 1, 1, '2', 0)
    enable_barrier(service, 200)
    service.activate_pending(user_id='alice', binding_id=second['id'])
    with factory() as session:
        assert session.get(WalletBinding, first['id']).effective_to_block == 201
        assert session.get(WalletBinding, second['id']).effective_from_block == 201
    now[0] += timedelta(days=30, microseconds=-1)
    with pytest.raises(AppError, match='WALLET_REBIND_TOO_SOON'):
        pending(core, 2, 2, '3', 1)
    now[0] += timedelta(microseconds=1)
    assert pending(core, 2, 2, '3', 1)['status'] == 'PENDING'


def test_address_cannot_move_to_other_user(core):
    service, _, _, keys, addresses = core
    pending(core)
    c = service.challenge(user_id='bob', session_id='b', address=addresses[0], expected_version=0, idempotency_key='b')
    with pytest.raises(AppError, match='WALLET_ADDRESS_OWNED'):
        service.confirm(user_id='bob', session_id='b', challenge_id=c['id'], signature=sign(keys[0], c['message']),
            old_signature=None, mfa_proof='verified-test-mfa', idempotency_key='b')


def test_rejects_invalid_mfa_and_unsupported_permissions(core):
    service, _, _, _, _ = core
    service.mfa_verifier = None
    with pytest.raises(AppError, match='WALLET_MFA_REQUIRED'):
        pending(core)
    service.mfa_verifier = lambda **kw: True
    service.permission_verifier = None
    with pytest.raises(AppError, match='WALLET_PERMISSION_UNAVAILABLE'):
        pending(core)


def test_real_signature_recovery_rejects_other_address_and_message(core):
    _, _, _, keys, addresses = core
    verifier = TronMessageVerifier()
    signature = sign(keys[0], '仅证明绑定，不授权转账')
    assert verifier.verify('仅证明绑定，不授权转账', signature, addresses[0])
    assert not verifier.verify('different', signature, addresses[0])
    assert not verifier.verify('仅证明绑定，不授权转账', signature, addresses[1])


def test_independent_tronweb_604_utf8_vector():
    # Offline, randomly generated test account; private key discarded by TronWeb.
    assert TronMessageVerifier().verify(
        'StarChat isolated binding verification — 仅证明绑定，不授权转账。',
        '0x647ba4864afaa745b9a2c8e4df6689ad0b7ef8f2735245be1e8b43756c0b15e6237396a1c9942f553aca539bd4d691860e298af06c0a5f40d7c135b9ee27bb5a1b',
        'TBcE2DrVnDBLhNZiThHfgeNeWx78dgHjCv')


@pytest.mark.parametrize('status', ['REQUESTED', 'FINANCE_APPROVED', 'ADMIN_APPROVED', 'SUBMITTING', 'UNKNOWN', 'BROADCAST'])
def test_any_nonterminal_withdrawal_blocks_activation(core, status):
    from decimal import Decimal
    from app.modules.wallet.models import Withdrawal
    service, factory, now, _, addresses = core
    result = pending(core)
    enable_barrier(service)
    with factory.begin() as session:
        session.add(Withdrawal(id='w', user_id='alice', client_order_id='w', address=addresses[0],
            amount=Decimal('10'), status=status, created_at=now[0], updated_at=now[0]))
    with pytest.raises(AppError, match='WALLET_WITHDRAWAL_IN_PROGRESS'):
        service.activate_pending(user_id='alice', binding_id=result['id'])


def test_two_challenges_only_one_can_confirm(core):
    service, _, _, keys, addresses = core
    c = service.challenge(user_id='alice', session_id='session', address=addresses[1], expected_version=0, idempotency_key='second')
    pending(core)
    with pytest.raises(AppError, match='WALLET_BINDING_PENDING'):
        service.confirm(user_id='alice', session_id='session', challenge_id=c['id'], signature=sign(keys[1], c['message']),
            old_signature=None, mfa_proof='verified-test-mfa', idempotency_key='second')


def test_audit_failure_rolls_back_nonce_and_pending(core, monkeypatch):
    from app.modules.wallet import binding
    service, factory, _, keys, addresses = core
    c = service.challenge(user_id='alice', session_id='session', address=addresses[0], expected_version=0, idempotency_key='c')
    def fail(*args):
        raise RuntimeError('audit unavailable')
    monkeypatch.setattr(binding, 'audit_write', fail)
    with pytest.raises(RuntimeError, match='audit unavailable'):
        service.confirm(user_id='alice', session_id='session', challenge_id=c['id'], signature=sign(keys[0], c['message']),
            mfa_proof='verified-test-mfa', idempotency_key='c')
    with factory() as session:
        assert session.get(WalletBindingChallenge, c['id']).consumed_at is None
        assert session.scalar(select(WalletBinding)) is None


def test_cross_domain_rejects_unconsumed_challenge(core):
    service, _, _, keys, addresses = core
    c = service.challenge(user_id='alice', session_id='session', address=addresses[0], expected_version=0, idempotency_key='c')
    service.domain = 'other.example.test'
    with pytest.raises(AppError, match='WALLET_CHALLENGE_INVALID'):
        service.confirm(user_id='alice', session_id='session', challenge_id=c['id'], signature=sign(keys[0], c['message']),
            mfa_proof='verified-test-mfa', idempotency_key='c')


@pytest.mark.parametrize('invalid', ['one_source', 'stale', 'future', 'other_binding', 'network'])
def test_barrier_evidence_fails_closed(core, invalid):
    service, _, now, _, _ = core
    result = pending(core)
    service.barrier_verifier = lambda **kw: VerifiedBindingBarrier(height=100, block_id='0' * 64,
        network='other' if invalid == 'network' else 'tron-mainnet',
        source_ids=('same', 'same') if invalid == 'one_source' else ('a', 'b'),
        binding_id='other' if invalid == 'other_binding' else result['id'],
        observed_at=now[0] + (timedelta(minutes=-6) if invalid == 'stale' else timedelta(seconds=1) if invalid == 'future' else timedelta(0)))
    with pytest.raises(AppError, match='WALLET_BINDING_BARRIER_INVALID'):
        service.activate_pending(user_id='alice', binding_id=result['id'])


def test_database_rejects_active_without_activation_evidence(core):
    from sqlalchemy.exc import IntegrityError
    _, factory, _, _, _ = core
    result = pending(core)
    with pytest.raises(IntegrityError):
        with factory.begin() as session:
            session.get(WalletBinding, result['id']).status = 'ACTIVE'


def test_restricted_wallet_cannot_activate_or_start_challenges(core):
    from app.modules.wallet.models import WalletSafetyState
    service, factory, _, _, addresses = core
    result = pending(core)
    enable_barrier(service)
    with factory.begin() as session:
        session.add(WalletSafetyState(id='alice', restricted=True, epoch=1, reason='TEST_RESTRICTION'))
    with pytest.raises(AppError, match='WALLET_ACCOUNT_RESTRICTED'):
        service.activate_pending(user_id='alice', binding_id=result['id'])
    with pytest.raises(AppError, match='WALLET_ACCOUNT_RESTRICTED'):
        service.challenge(user_id='alice', session_id='session', address=addresses[1], expected_version=0, idempotency_key='other')


@pytest.mark.parametrize(('field', 'value'), [
    ('source_ids', 'ab'), ('source_ids', None), ('source_ids', True),
    ('source_ids', ('a', 1)), ('source_ids', ('a', [])),
    ('source_ids', ('a', ' b')), ('source_ids', ('a', '')), ('source_ids', ('a', 'A')),
    ('block_id', None), ('block_id', True), ('height', None), ('height', True),
    ('observed_at', None), ('observed_at', True), ('observed_at', '2026-09-07'),
    ('observed_at', datetime(2026, 9, 7)),
])
def test_malformed_barrier_has_stable_error(core, field, value):
    service, factory, now, _, _ = core
    result = pending(core)
    data = dict(height=100, block_id='0' * 64, network='tron-mainnet', source_ids=('a', 'b'),
                binding_id=result['id'], observed_at=now[0])
    data[field] = value
    service.barrier_verifier = lambda **kw: VerifiedBindingBarrier(**data)
    with pytest.raises(AppError, match='WALLET_BINDING_BARRIER_INVALID') as error:
        service.activate_pending(user_id='alice', binding_id=result['id'])
    assert error.value.status_code == 503
    with factory() as session:
        assert session.get(WalletBinding, result['id']).status == 'PENDING'


def test_activation_persists_source_and_observation_evidence(core):
    service, factory, now, _, _ = core
    result = pending(core)
    enable_barrier(service)
    service.activate_pending(user_id='alice', binding_id=result['id'])
    with factory() as session:
        binding = session.get(WalletBinding, result['id'])
        assert binding.barrier_source_ids == ['independent-a', 'independent-b']
        assert binding.barrier_observed_at.replace(tzinfo=timezone.utc) == now[0]
