"""Declare an already-executed owner transfer; never create, sign or amend a payment.

ADR-0071. The declaration records an immutable, covered fact for an on-chain
outflow the official wallet owner made outside the payout order flow, so the
manual-wallet monitor can explain the movement while every other check stays
intact. Corrections require appended reversals, never mutation.
"""
import hashlib
import json
import re
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, localcontext
from uuid import uuid4

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.integrations.tron.finality import TransactionEvidence, TronEvidenceUnavailable, transaction_evidence_fresh
from app.modules.identity.wallet_access import require_wallet_actor
from app.modules.ledger.reserve import lock_budget
from app.modules.wallet.funding_coverage_models import WalletFundingCoverageEvent as Coverage
from app.modules.wallet.manual_payout_models import ManualPayoutEvent
from app.modules.wallet.owner_transfer_models import WalletManualOwnerTransfer
from app.modules.wallet.repairs import fail
from app.modules.wallet.safety import audit_write

TXID_PATTERN = re.compile(r'^[a-f0-9]{64}$')
REASON_PATTERN = re.compile(r'^[A-Z][A-Z0-9_]{2,99}$')


def _units(value):
    try:
        return str(int(str(value)))
    except (ValueError, TypeError):
        return None


def _exact_amount(value):
    try:
        with localcontext() as context:
            context.prec = 100
            return Decimal(str(value)) / Decimal(1000000)
    except (InvalidOperation, ValueError, TypeError):
        return None


def _aware(value):
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise ValueError('trusted aware clock required')
    return value.astimezone(timezone.utc)


class OwnerTransferService:
    def __init__(self, factory, *, ledger, finality_adapter, official_config, owner_admin_id,
                 clock_trusted, clock):
        self.factory, self.ledger, self.adapter = factory, ledger, finality_adapter
        self.official_config, self.owner_admin_id = official_config, owner_admin_id
        self.clock_trusted, self.clock = clock_trusted, clock
        self.source_identity = hashlib.sha256(
            ('tron-mainnet-usdt:' + official_config.address).encode()).hexdigest()

    def _authorize(self, session, actor_id, authorize):
        if not self.owner_admin_id or actor_id != self.owner_admin_id or not callable(authorize):
            fail('PERMISSION_DENIED', 403)
        require_wallet_actor(session, user_id=actor_id, clock=self.clock, administrator=True)
        fresh = authorize(session)
        if not callable(fresh):
            fail('WALLET_VERIFICATION_REQUIRED', 403)
        fresh()
        return fresh

    def _proof(self, txid):
        try:
            proof = self.adapter.transaction_evidence(txid)
        except TronEvidenceUnavailable:
            fail('EVIDENCE_EXPIRED', 503)
        if not isinstance(proof, TransactionEvidence) or proof.txid != txid:
            fail('EVIDENCE_CONFLICT', 409)
        return proof

    def _validate(self, txid, log_index, reason_code, reason_detail, ownership_attested, idempotency_key=None):
        if TXID_PATTERN.fullmatch(txid or '') is None:
            fail('REPAIR_QUERY_INVALID', 422)
        if type(log_index) is not int or log_index < 0:
            fail('REPAIR_QUERY_INVALID', 422)
        if REASON_PATTERN.fullmatch(reason_code or '') is None:
            fail('REPAIR_REASON_INVALID', 422)
        if not isinstance(reason_detail, str) or not 1 <= len(reason_detail.strip()) <= 500:
            fail('REPAIR_REASON_INVALID', 422)
        if ownership_attested is not True:
            fail('OWNERSHIP_ATTESTATION_REQUIRED', 422)
        if idempotency_key is not None and (not isinstance(idempotency_key, str) or not 1 <= len(idempotency_key) <= 128):
            fail('REPAIR_IDEMPOTENCY_INVALID', 422)

    def _snapshot(self, session, *, actor_id, txid, log_index, reason_code, reason_detail, authorize):
        if self.clock_trusted() is not True:
            fail('CLOCK_UNTRUSTED', 503)
        self._authorize(session, actor_id, authorize)
        proof = self._proof(txid)
        if not transaction_evidence_fresh(proof, _aware(self.clock())):
            fail('EVIDENCE_EXPIRED', 503)
        at_index = [transfer for transfer in proof.transfers if transfer.log_index == log_index]
        transfer = at_index[0] if len(at_index) == 1 else None
        blockers = []
        if transfer is None:
            blockers.append('TRANSFER_NOT_FOUND')
        elif transfer.from_address != self.official_config.address:
            blockers.append('TRANSFER_NOT_OUTFLOW')
        fact = session.scalar(select(Coverage).where(Coverage.source_identity == self.source_identity,
            Coverage.txid == txid, Coverage.log_index == log_index))
        if fact is None or fact.status != 'VERIFIED':
            blockers.append('COVERAGE_FACT_MISSING')
        elif transfer is not None and (fact.to_address != transfer.to_address
                or _units(fact.amount_units) != _units(transfer.amount_units)):
            blockers.append('COVERAGE_FACT_CONFLICT')
        if session.scalar(select(ManualPayoutEvent.id).where(ManualPayoutEvent.txid == txid,
                ManualPayoutEvent.log_index == log_index)):
            blockers.append('EVENT_ALREADY_ALLOCATED')
        if session.scalar(select(WalletManualOwnerTransfer.id).where(
                WalletManualOwnerTransfer.txid == txid,
                WalletManualOwnerTransfer.log_index == log_index)):
            blockers.append('ALREADY_DECLARED')
        return dict(txid=txid, log_index=log_index,
            to_address=transfer.to_address if transfer is not None else None,
            amount_units=_units(transfer.amount_units) if transfer is not None else None,
            reason_code=reason_code, reason_detail=reason_detail.strip(), declared_by=actor_id,
            blockers=sorted(set(blockers)))

    def preview(self, *, actor_id, txid, log_index, reason_code, reason_detail, ownership_attested, authorize):
        self._validate(txid, log_index, reason_code, reason_detail, ownership_attested)
        with self.factory.begin() as session:
            lock_budget(session)
            snapshot = self._snapshot(session, actor_id=actor_id, txid=txid, log_index=log_index,
                reason_code=reason_code, reason_detail=reason_detail, authorize=authorize)
        snapshot['declared'] = 'ALREADY_DECLARED' in snapshot['blockers']
        return snapshot

    def execute(self, *, actor_id, txid, log_index, reason_code, reason_detail,
                ownership_attested, authorize, idempotency_key):
        self._validate(txid, log_index, reason_code, reason_detail, ownership_attested, idempotency_key)
        payload = dict(txid=txid, log_index=log_index, reason_code=reason_code,
            reason_detail=reason_detail.strip())
        record_digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
        with self.factory() as session:
            existing = session.scalar(select(WalletManualOwnerTransfer).where(
                WalletManualOwnerTransfer.txid == txid, WalletManualOwnerTransfer.log_index == log_index))
        if existing is not None:
            return self._replay(existing, record_digest, actor_id)
        try:
            with self.factory.begin() as session:
                lock_budget(session)
                snapshot = self._snapshot(session, actor_id=actor_id, txid=txid, log_index=log_index,
                    reason_code=reason_code, reason_detail=reason_detail, authorize=authorize)
                if snapshot['blockers']:
                    fail(snapshot['blockers'][0], 409)
                amount = _exact_amount(snapshot['amount_units'])
                if amount is None:
                    fail('AMOUNT_MALFORMED', 409)
                record = WalletManualOwnerTransfer(id=str(uuid4()), txid=txid, log_index=log_index,
                    to_address=snapshot['to_address'], amount=amount, amount_units=snapshot['amount_units'],
                    reason_code=reason_code, reason_detail=reason_detail.strip(), declared_by=actor_id,
                    digest=record_digest, created_at=_aware(self.clock()))
                session.add(record)
                session.flush()
                self.ledger.post(entries={'PLATFORM_CUSTODY': amount, 'PLATFORM_OWNER_DRAWING': -amount},
                    actor_id=actor_id, reason_code=reason_code,
                    idempotency_key=f'owner-transfer:{txid}:{log_index}',
                    scope='wallet.manual.owner-transfer', session=session)
                audit_write(session, actor_id, record.id, 'wallet.owner_transfer_declared', reason_code)
                return self._view(record, replayed=False)
        except IntegrityError:
            with self.factory() as session:
                existing = session.scalar(select(WalletManualOwnerTransfer).where(
                    WalletManualOwnerTransfer.txid == txid, WalletManualOwnerTransfer.log_index == log_index))
            if existing is not None:
                return self._replay(existing, record_digest, actor_id)
            fail('IDEMPOTENCY_CONFLICT', 409)

    def _replay(self, record, record_digest, actor_id):
        if record.digest != record_digest or record.declared_by != actor_id:
            fail('IDEMPOTENCY_CONFLICT', 409)
        return self._view(record, replayed=True)

    @staticmethod
    def _view(record, *, replayed):
        return dict(id=record.id, txid=record.txid, log_index=record.log_index,
            to_address=record.to_address, amount=str(record.amount), amount_units=record.amount_units,
            reason_code=record.reason_code, reason_detail=record.reason_detail,
            declared_by=record.declared_by, status='DECLARED', replayed=replayed,
            created_at=record.created_at.isoformat())

    def status(self, *, actor_id, txid, authorize):
        if actor_id != self.owner_admin_id:
            fail('PERMISSION_DENIED', 403)
        with self.factory.begin() as session:
            self._authorize(session, actor_id, authorize)
            rows = session.scalars(select(WalletManualOwnerTransfer).where(
                WalletManualOwnerTransfer.txid == txid).order_by(WalletManualOwnerTransfer.log_index)).all()
        return dict(txid=txid, transfers=[self._view(row, replayed=False) for row in rows])
