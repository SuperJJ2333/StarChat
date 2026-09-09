"""Server-owned deposit intent snapshots. No receipt ingestion or money writes."""
from dataclasses import dataclass
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import re
from uuid import uuid4

from sqlalchemy import select

from app.core.errors import AppError
from app.integrations.tron.message_signature import canonical_address
from app.modules.ledger.reserve import lock_budget
from app.modules.wallet.binding_models import WalletBinding, WalletBindingState
from app.modules.wallet.funding_models import DepositIntent
from app.modules.wallet.models import WalletControl, WalletSafetyState
from app.modules.wallet.safety import audit_write


def _fail(code, status=409):
    raise AppError(code=code, message=code, status_code=status)


def _utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


@dataclass(frozen=True)
class OfficialFundingConfig:
    address: str
    version: str


class DepositIntentService:
    def __init__(self, session_factory, *, official_config, intent_ttl, clock):
        if not isinstance(intent_ttl, timedelta) or intent_ttl <= timedelta(0):
            raise ValueError('server intent expiry policy required')
        if not callable(clock):
            raise ValueError('server clock required')
        self.factory = session_factory
        self.official_config = official_config
        self.intent_ttl = intent_ttl
        self.clock = clock

    def _now(self):
        now = self.clock()
        if not isinstance(now, datetime) or now.tzinfo is None or now.utcoffset() is None:
            raise ValueError('timezone-aware server clock required')
        return now.astimezone(timezone.utc)

    @staticmethod
    def _lock(session, user_id):
        lock_budget(session)
        if session.get(WalletControl, 'global', with_for_update=True) is None:
            _fail('WALLET_CONTROL_UNAVAILABLE', 503)
        return session.get(WalletBindingState, user_id, with_for_update=True)

    @staticmethod
    def _close(session, row, *, status, actor_id, now):
        row.status = status
        row.closed_at = now
        audit_write(session, actor_id, row.id, 'wallet.deposit_intent_closed', 'WALLET_DEPOSIT_INTENT_' + status)

    def create(self, *, user_id, expected_amount, expected_binding_version, idempotency_key):
        if (not isinstance(expected_amount, str) or not re.fullmatch(r'(0|[1-9][0-9]{0,23})\.[0-9]{6}', expected_amount)
                or Decimal(expected_amount) < Decimal('10.000000')):
            _fail('WALLET_DEPOSIT_AMOUNT_INVALID', 400)
        if not user_id or type(expected_binding_version) is not int or expected_binding_version < 1:
            _fail('WALLET_BINDING_VERSION_CONFLICT')
        if not isinstance(idempotency_key, str) or not idempotency_key.strip() or len(idempotency_key) > 128:
            _fail('WALLET_IDEMPOTENCY_REQUIRED', 400)
        amount = Decimal(expected_amount)
        with self.factory.begin() as session:
            state = self._lock(session, user_id)
            safety = session.get(WalletSafetyState, user_id)
            if safety and safety.restricted:
                _fail('WALLET_ACCOUNT_RESTRICTED', 403)
            now = self._now()
            existing = session.scalar(select(DepositIntent).where(DepositIntent.user_id == user_id,
                DepositIntent.idempotency_key == idempotency_key))
            if existing:
                if existing.expected_amount != amount or existing.binding_version != expected_binding_version:
                    _fail('WALLET_IDEMPOTENCY_CONFLICT')
                if existing.status == 'OPEN' and now >= _utc(existing.expires_at):
                    self._close(session, existing, status='EXPIRED', actor_id=user_id, now=now)
                return self._result(existing)
            if state is None or not state.active_binding_id:
                _fail('WALLET_BINDING_REQUIRED')
            if state.pending_binding_id:
                _fail('WALLET_BINDING_PENDING')
            binding = session.get(WalletBinding, state.active_binding_id)
            if (binding is None or binding.user_id != user_id or binding.status != 'ACTIVE'
                    or binding.version != state.version or state.version != expected_binding_version
                    or binding.effective_from_block is None or binding.effective_to_block is not None):
                _fail('WALLET_BINDING_VERSION_CONFLICT')
            config = self.official_config
            try:
                if (not isinstance(config, OfficialFundingConfig) or not isinstance(config.version, str)
                        or not config.version.strip() or len(config.version) > 128):
                    raise ValueError('missing configuration')
                official_address = canonical_address(config.address)
            except (ValueError, TypeError):
                _fail('WALLET_OFFICIAL_CONFIG_UNAVAILABLE', 503)
            opened = session.scalar(select(DepositIntent).where(DepositIntent.user_id == user_id, DepositIntent.status == 'OPEN'))
            if opened:
                if now < _utc(opened.expires_at):
                    _fail('WALLET_DEPOSIT_INTENT_OPEN')
                self._close(session, opened, status='EXPIRED', actor_id=user_id, now=now)
                session.flush()
            row = DepositIntent(id=str(uuid4()), user_id=user_id, idempotency_key=idempotency_key,
                binding_id=binding.id, binding_version=binding.version, binding_effective_from_block=binding.effective_from_block,
                source_address=binding.address, official_address=official_address, official_config_version=config.version,
                network='tron-mainnet', expected_amount=amount,
                rules_snapshot={'version': 'DEPOSIT_INTENT_V1', 'minimum_amount': '10.000000', 'asset': 'USDT',
                    'precision': 6, 'finality_policy': 'TRONGRID_SINGLE_SOURCE_V1',
                    'expiry_microseconds': self.intent_ttl // timedelta(microseconds=1)},
                status='OPEN', created_at=now, expires_at=now + self.intent_ttl)
            session.add(row)
            audit_write(session, user_id, row.id, 'wallet.deposit_intent_created', 'WALLET_DEPOSIT_INTENT_CREATED')
            session.flush()
            return self._result(row)

    def recover(self, *, user_id, expected_amount, expected_binding_version, idempotency_key):
        """Read an existing user's intent; never expire it or create a replacement."""
        from app.modules.identity.wallet_access import require_wallet_actor
        if not isinstance(idempotency_key, str) or not idempotency_key.strip() or len(idempotency_key) > 128:
            _fail('WALLET_IDEMPOTENCY_REQUIRED', 400)
        with self.factory.begin() as session:
            self._lock(session, user_id)
            require_wallet_actor(session, user_id=user_id, clock=self.clock)
            row = session.scalar(select(DepositIntent).where(DepositIntent.user_id == user_id,
                DepositIntent.idempotency_key == idempotency_key))
            if row is None:
                return None
            if row.expected_amount != Decimal(expected_amount) or row.binding_version != expected_binding_version:
                _fail('WALLET_IDEMPOTENCY_CONFLICT')
            return self._result(row)

    def close_by_rebind(self, session, *, user_id, binding_id, binding_version, actor_id):
        """Call inside the activation transaction, after its standard wallet locks.

        Never commits; caller owns rollback and the binding change. Reacquiring
        the same reserve/control/state locks is safe under the shared lock order.
        """
        return close_deposit_intents_for_rebind(session, user_id=user_id,
            binding_id=binding_id, binding_version=binding_version,
            actor_id=actor_id, now=self._now())

    def status(self, *, user_id, intent_id):
        with self.factory.begin() as session:
            self._lock(session, user_id)
            row = session.scalar(select(DepositIntent).where(DepositIntent.id == intent_id, DepositIntent.user_id == user_id))
            if row is None:
                _fail('WALLET_DEPOSIT_INTENT_NOT_FOUND', 404)
            now = self._now()
            if row.status == 'OPEN' and now >= _utc(row.expires_at):
                self._close(session, row, status='EXPIRED', actor_id=user_id, now=now)
            return self._result(row)

    def current(self, *, user_id):
        """Recover a lost response without creating or changing an intent."""
        with self.factory() as session:
            row = session.scalar(select(DepositIntent).where(
                DepositIntent.user_id == user_id, DepositIntent.status == 'OPEN'))
            return self._result(row) if row is not None else None

    @staticmethod
    def _result(row):
        return {key: deepcopy(getattr(row, key)) for key in ('id', 'binding_id', 'binding_version', 'binding_effective_from_block',
            'source_address', 'official_address', 'official_config_version', 'network', 'rules_snapshot', 'status')} | {
                'expected_amount': format(row.expected_amount, '.6f'), 'created_at': _utc(row.created_at).isoformat(),
                'expires_at': _utc(row.expires_at).isoformat(),
                'closed_at': _utc(row.closed_at).isoformat() if row.closed_at else None}


def close_deposit_intents_for_rebind(session, *, user_id, binding_id, binding_version, actor_id, now):
    """Public activation hook; caller owns transaction and supplies its server time."""
    if not isinstance(now, datetime) or now.tzinfo is None or now.utcoffset() is None:
        raise ValueError('timezone-aware server clock required')
    DepositIntentService._lock(session, user_id)
    rows = session.scalars(select(DepositIntent).where(DepositIntent.user_id == user_id,
        DepositIntent.binding_id == binding_id, DepositIntent.binding_version == binding_version,
        DepositIntent.status == 'OPEN').with_for_update()).all()
    for row in rows:
        DepositIntentService._close(session, row, status='CLOSED_BY_REBIND', actor_id=actor_id, now=now)
    session.flush()
    return len(rows)
