"""Transactional wallet control proofs; trusted external evidence gates activation.

Callbacks are server-owned adapters, never request-provided booleans. MFA verifies
the supplied credential against the authenticated user/session; account permission
checks must confirm a standard single-owner EOA. No default adapter asserts either.
"""
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import hashlib
import json
import re
import secrets
from uuid import uuid4

from sqlalchemy import select

from app.core.errors import AppError
from app.integrations.tron.message_signature import TronMessageVerifier, canonical_address
from app.modules.ledger.reserve import lock_budget
from app.modules.wallet.binding_models import (
    WalletAddressOwner, WalletBinding, WalletBindingChallenge, WalletBindingRequest, WalletBindingState,
)
from app.modules.wallet.models import WalletControl, WalletSafetyState, Withdrawal
from app.modules.wallet.safety import audit_write
from app.modules.wallet.funding import close_deposit_intents_for_rebind
from app.modules.wallet.manual_payouts import has_pending_manual_payout

NETWORK = 'tron-mainnet'
TERMINAL_WITHDRAWALS = {'CHAIN_CONFIRMED', 'FAILED_COMPENSATED', 'CANCELLED'}


def _utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def _fail(code, status=409):
    raise AppError(code=code, message=code, status_code=status)


@dataclass(frozen=True)
class VerifiedBindingBarrier:
    """Result of a trusted policy-specific finality adapter, not an API model."""
    height: int
    block_id: str
    network: str
    source_ids: tuple[str, ...]
    binding_id: str
    observed_at: datetime
    policy: str = 'INDEPENDENT_V1'


class WalletBindingService:
    address_registration_enabled = False

    def register_address(self, *, user_id, session_id, address, expected_version, idempotency_key):
        """User-declared address, not proof of wallet ownership (ADR-0058)."""
        if not self.address_registration_enabled:
            _fail('WALLET_ADDRESS_REGISTRATION_DISABLED', 403)
        try:
            address = canonical_address(address)
        except ValueError:
            _fail('WALLET_ADDRESS_INVALID', 400)
        if not user_id or not session_id or type(expected_version) is not int or expected_version < 0:
            _fail('WALLET_CHALLENGE_INVALID', 400)
        now = _utc(self.clock())
        payload = [session_id, self.domain, NETWORK, address, expected_version]
        with self.factory.begin() as session:
            state = self._lock(session, user_id)
            replay = self._replay(session, user_id, 'REGISTER', idempotency_key, payload)
            if replay is not None:
                return replay
            self._eligible(session, state, expected_version, now)
            owner = session.get(WalletAddressOwner, address)
            if owner and owner.user_id != user_id:
                _fail('WALLET_ADDRESS_OWNED')
            if owner is None:
                session.add(WalletAddressOwner(address=address, user_id=user_id, created_at=now))
                session.flush()
            row = WalletBinding(id=str(uuid4()), user_id=user_id, address=address,
                version=state.version+1, status='PENDING', created_at=now)
            session.add(row)
            state.pending_binding_id = row.id
            return self._record(session, user_id, 'REGISTER', idempotency_key, payload,
                {'id':row.id, 'status':'PENDING', 'version':row.version,
                 'blocked_reason':'WALLET_BINDING_BARRIER_REQUIRED'}, now)
    def __init__(self, session_factory, *, domain, signature_verifier=None,
                 mfa_verifier=None, permission_verifier=None, barrier_verifier=None,
                 clock=None, finality_policy='INDEPENDENT_V1'):
        if not domain or len(domain) > 255 or any(c.isspace() for c in domain):
            raise ValueError('server wallet domain required')
        self.factory = session_factory
        if finality_policy not in ('INDEPENDENT_V1', 'TRONGRID_SINGLE_SOURCE_V1'):
            raise ValueError('unsupported wallet finality policy')
        self.finality_policy = finality_policy
        self.domain = domain
        self.signature_verifier = signature_verifier or TronMessageVerifier()
        self.mfa_verifier = mfa_verifier
        self.permission_verifier = permission_verifier
        self.barrier_verifier = barrier_verifier
        self.clock = clock or (lambda: datetime.now(timezone.utc))

    def _lock(self, session, user_id):
        # Follow the withdrawal/reserve lock order. Global lock also serializes
        # claims of an address by two different accounts, including absent rows.
        lock_budget(session)
        control = session.get(WalletControl, 'global', with_for_update=True)
        if control is None:
            _fail('WALLET_CONTROL_UNAVAILABLE', 503)
        safety = session.get(WalletSafetyState, user_id)
        if safety and safety.restricted:
            _fail('WALLET_ACCOUNT_RESTRICTED', 403)
        state = session.get(WalletBindingState, user_id, with_for_update=True)
        if state is None:
            state = WalletBindingState(user_id=user_id, version=0)
            session.add(state)
            session.flush()
        return state

    def _replay(self, session, user_id, operation, key, payload):
        if not key or len(key) > 128:
            _fail('WALLET_IDEMPOTENCY_REQUIRED', 400)
        existing = session.scalar(select(WalletBindingRequest).where(
            WalletBindingRequest.user_id == user_id, WalletBindingRequest.operation == operation,
            WalletBindingRequest.idempotency_key == key))
        if existing:
            if existing.digest != _digest(payload):
                _fail('WALLET_IDEMPOTENCY_CONFLICT')
            return existing.response
        return None

    def _record(self, session, user_id, operation, key, payload, response, now):
        session.add(WalletBindingRequest(id=str(uuid4()), user_id=user_id, operation=operation,
            idempotency_key=key, digest=_digest(payload), response=response, created_at=now))
        audit_write(session, user_id, response['id'], 'wallet.binding_' + operation.lower(),
            'WALLET_BINDING_' + operation)
        session.flush()
        return response

    def _eligible(self, session, state, version, now):
        if state.version != version:
            _fail('WALLET_BINDING_VERSION_CONFLICT')
        if state.pending_binding_id:
            _fail('WALLET_BINDING_PENDING')
        if state.last_rebind_at and now < _utc(state.last_rebind_at) + timedelta(days=30):
            _fail('WALLET_REBIND_TOO_SOON')
        self._no_withdrawals(session, state.user_id)

    def _no_withdrawals(self, session, user_id):
        if has_pending_manual_payout(session, user_id=user_id):
            _fail('WALLET_WITHDRAWAL_IN_PROGRESS')
        if session.scalar(select(Withdrawal.id).where(Withdrawal.user_id == user_id,
                Withdrawal.status.not_in(TERMINAL_WITHDRAWALS)).limit(1)):
            _fail('WALLET_WITHDRAWAL_IN_PROGRESS')

    def challenge(self, *, user_id, session_id, address, expected_version, idempotency_key):
        try:
            address = canonical_address(address)
        except ValueError:
            _fail('WALLET_ADDRESS_INVALID', 400)
        if not user_id or not session_id or type(expected_version) is not int or expected_version < 0:
            _fail('WALLET_CHALLENGE_INVALID', 400)
        now = _utc(self.clock())
        payload = [session_id, self.domain, NETWORK, address, expected_version]
        with self.factory.begin() as session:
            state = self._lock(session, user_id)
            replay = self._replay(session, user_id, 'CHALLENGE', idempotency_key, payload)
            if replay is not None:
                return replay
            self._eligible(session, state, expected_version, now)
            active = session.get(WalletBinding, state.active_binding_id) if state.active_binding_id else None
            if active and active.address == address:
                _fail('WALLET_ALREADY_BOUND')
            identifier = str(uuid4())
            expires = now + timedelta(minutes=5)
            session_digest = _digest(session_id)
            message = '仅证明绑定，不授权转账 / Wallet binding proof only; no transfer authorization.\n' + json.dumps({
                'domain': self.domain, 'network': NETWORK, 'user_id': user_id, 'session': session_digest,
                'action': 'REBIND' if state.version else 'BIND', 'address': address,
                'old_address': active.address if active else None, 'old_version': expected_version,
                'nonce': secrets.token_hex(32), 'challenge_id': identifier,
                'issued_at': now.isoformat(), 'expires_at': expires.isoformat(),
            }, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
            session.add(WalletBindingChallenge(id=identifier, user_id=user_id, session_digest=session_digest,
                domain=self.domain, network=NETWORK, address=address, expected_version=expected_version,
                message=message, created_at=now, expires_at=expires))
            return self._record(session, user_id, 'CHALLENGE', idempotency_key, payload,
                {'id': identifier, 'message': message, 'expires_at': expires.isoformat(), 'protocol': 'signMessageV2'}, now)

    def confirm(self, *, user_id, session_id, challenge_id, signature, old_signature=None,
                mfa_proof=None, idempotency_key):
        now = _utc(self.clock())
        # Credentials are deliberately neither persisted nor part of replay data.
        payload = [session_id, self.domain, challenge_id, signature, old_signature]
        with self.factory.begin() as session:
            state = self._lock(session, user_id)
            replay = self._replay(session, user_id, 'CONFIRM', idempotency_key, payload)
            if replay is not None:
                return replay
            challenge = session.get(WalletBindingChallenge, challenge_id, with_for_update=True)
            if (challenge is None or challenge.user_id != user_id or challenge.session_digest != _digest(session_id)
                    or challenge.domain != self.domain or challenge.network != NETWORK):
                _fail('WALLET_CHALLENGE_INVALID', 400)
            if challenge.consumed_at is not None or now >= _utc(challenge.expires_at):
                _fail('WALLET_CHALLENGE_EXPIRED_OR_CONSUMED')
            self._eligible(session, state, challenge.expected_version, now)
            if self.mfa_verifier is None or self.mfa_verifier(user_id=user_id, session_id=session_id,
                    proof=mfa_proof, now=now) is not True:
                _fail('WALLET_MFA_REQUIRED', 403)
            if not self.signature_verifier.verify(challenge.message, signature, challenge.address):
                _fail('WALLET_SIGNATURE_INVALID', 400)
            old = session.get(WalletBinding, state.active_binding_id) if state.active_binding_id else None
            if old and (not old_signature or not self.signature_verifier.verify(challenge.message, old_signature, old.address)):
                _fail('WALLET_OLD_SIGNATURE_REQUIRED', 403)
            if self.permission_verifier is None:
                _fail('WALLET_PERMISSION_UNAVAILABLE', 503)
            for address in {challenge.address, old.address if old else challenge.address}:
                if self.permission_verifier(address=address, network=NETWORK, now=now) is not True:
                    _fail('WALLET_PERMISSION_UNSUPPORTED', 403)
            owner = session.get(WalletAddressOwner, challenge.address)
            if owner and owner.user_id != user_id:
                _fail('WALLET_ADDRESS_OWNED')
            if owner is None:
                session.add(WalletAddressOwner(address=challenge.address, user_id=user_id, created_at=now))
                session.flush()
            binding = WalletBinding(id=str(uuid4()), user_id=user_id, address=challenge.address,
                version=state.version + 1, status='PENDING', created_at=now)
            session.add(binding)
            state.pending_binding_id = binding.id
            challenge.consumed_at = now
            return self._record(session, user_id, 'CONFIRM', idempotency_key, payload,
                {'id': binding.id, 'status': 'PENDING', 'version': binding.version,
                 'blocked_reason': 'WALLET_BINDING_BARRIER_REQUIRED'}, now)

    def activate_pending(self, *, user_id, binding_id):
        """Worker/application-only entry point; never accepts caller barrier data."""
        now = _utc(self.clock())
        with self.factory.begin() as session:
            state = self._lock(session, user_id)
            binding = session.get(WalletBinding, binding_id)
            if binding is None or binding.user_id != user_id:
                _fail('WALLET_BINDING_NOT_FOUND', 404)
            if state.active_binding_id == binding_id and binding.status == 'ACTIVE':
                return {'id': binding.id, 'status': binding.status, 'version': binding.version}
            if state.pending_binding_id != binding_id or binding.version != state.version + 1:
                _fail('WALLET_BINDING_VERSION_CONFLICT')
            self._no_withdrawals(session, user_id)
            if state.last_rebind_at and now < _utc(state.last_rebind_at) + timedelta(days=30):
                _fail('WALLET_REBIND_TOO_SOON')
            if self.barrier_verifier is None:
                _fail('WALLET_BINDING_BARRIER_UNAVAILABLE', 503)
            evidence = self.barrier_verifier(binding=binding, now=now)
            # Evidence is timestamped after network I/O; compare with a fresh
            # server clock, never with the time before the request began.
            checked_at = _utc(self.clock())
            if checked_at < now:
                _fail('WALLET_BINDING_BARRIER_INVALID', 503)
            now = checked_at
            if (not isinstance(evidence, VerifiedBindingBarrier) or evidence.binding_id != binding.id
                    or evidence.policy != self.finality_policy
                    or evidence.network != NETWORK or type(evidence.height) is not int or evidence.height < 0
                    or not isinstance(evidence.block_id, str) or not re.fullmatch(r'[0-9a-fA-F]{64}', evidence.block_id)
                    or not isinstance(evidence.source_ids, (tuple, list))
                    or not ((self.finality_policy == 'INDEPENDENT_V1' and 2 <= len(evidence.source_ids) <= 16)
                        or (self.finality_policy == 'TRONGRID_SINGLE_SOURCE_V1'
                            and tuple(evidence.source_ids) == ('trongrid-mainnet',)))
                    or any(not isinstance(s, str) or not re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,127}', s) for s in evidence.source_ids)
                    or len(set(evidence.source_ids)) != len(evidence.source_ids)
                    or not isinstance(evidence.observed_at, datetime) or evidence.observed_at.tzinfo is None
                    or evidence.observed_at.utcoffset() is None
                    or not timedelta(0) <= now - _utc(evidence.observed_at) <= timedelta(minutes=5)):
                _fail('WALLET_BINDING_BARRIER_INVALID', 503)
            if not self.address_registration_enabled and (self.permission_verifier is None or self.permission_verifier(
                    address=binding.address, network=NETWORK, now=now) is not True):
                _fail('WALLET_PERMISSION_UNAVAILABLE', 503)
            old = session.get(WalletBinding, state.active_binding_id) if state.active_binding_id else None
            if old:
                if old.effective_from_block is None or evidence.height + 1 <= old.effective_from_block:
                    _fail('WALLET_BINDING_BARRIER_INVALID', 503)
                close_deposit_intents_for_rebind(session, user_id=user_id,
                    binding_id=old.id, binding_version=old.version, actor_id=user_id, now=now)
                old.effective_to_block = evidence.height + 1
                old.status = 'RETIRED'
                state.last_rebind_at = now
                session.flush()
            binding.status = 'ACTIVE'
            binding.activated_at = now
            binding.effective_from_block = evidence.height + 1
            binding.barrier_height = evidence.height
            binding.barrier_block_id = evidence.block_id.lower()
            binding.barrier_source_ids = list(evidence.source_ids)
            binding.barrier_observed_at = _utc(evidence.observed_at)
            binding.barrier_policy = evidence.policy
            state.active_binding_id = binding.id
            state.pending_binding_id = None
            state.version = binding.version
            audit_write(session, user_id, binding.id, 'wallet.binding_activated', 'WALLET_BINDING_ACTIVATED')
            session.flush()
            return {'id': binding.id, 'status': binding.status, 'version': binding.version}

    def status(self, user_id):
        with self.factory() as session:
            state = session.get(WalletBindingState, user_id)
            active = session.get(WalletBinding, state.active_binding_id) if state and state.active_binding_id else None
            pending = session.get(WalletBinding, state.pending_binding_id) if state and state.pending_binding_id else None
            return {'status': 'ACTIVE' if active else ('PENDING' if pending else 'UNBOUND'),
                'id': active.id if active else None, 'version': state.version if state else 0,
                  'masked_address': active.address[:6] + '…' + active.address[-4:] if active else None,
                  'address': active.address if active else None,
                'pending_id': pending.id if pending else None,
                'next_rebind_at': (_utc(state.last_rebind_at) + timedelta(days=30)).isoformat() if state and state.last_rebind_at else None}
