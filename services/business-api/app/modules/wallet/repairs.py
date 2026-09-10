"""Explicit owner-reviewed credits, preserving original order and receipt facts.

Network proofs are fetched before locks; all credit, obligation, command, audit
and outbox writes share the existing wallet/ledger transaction boundary.
"""
from dataclasses import asdict
from datetime import timedelta
from decimal import Decimal, localcontext
import hashlib
import json
import re
from uuid import uuid4

from sqlalchemy import select
from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.audit.writer import AuditWriter
from app.integrations.tron.finality import NETWORK, POLICY, SOURCE_ID, TransactionEvidence, transaction_evidence_fresh, TronEvidenceUnavailable
from app.integrations.tron.reader import USDT_CONTRACT
from app.modules.identity.models import User, AccountStatus
from app.modules.identity.wallet_access import require_wallet_actor
from app.modules.ledger.reserve import lock_budget, require_coverage
from app.modules.ledger.wallet_obligations import transfer_pending_to_credit
from app.modules.wallet.binding_models import WalletBinding, WalletBindingState, WalletAddressOwner
from app.modules.wallet.funding_models import DepositIntent
from app.modules.wallet.models import WalletControl, WalletSafetyState, Deposit
from app.modules.wallet.receipt_models import DepositReceipt, DepositReceiptAnomaly
from app.modules.wallet.receipts import utc
from app.modules.wallet.repair_models import RepairPreview, RepairCommand
from app.modules.wallet.safety import audit_write


REASONS = {'CLOCK_ORDERING_REVIEW': '时序偏差复核', 'EXPIRED_INTENT_REVIEW': '过期订单复核',
    'ATTRIBUTION_CORRECTION': '归属纠错', 'PAYMENT_BEFORE_ORDER': '先付款后下单人工确认', 'OTHER': '其他'}


def fail(code, status=409):
    raise AppError(code=code, message=code, status_code=status)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), default=str).encode()).hexdigest()


class DepositRepairService:
    def __init__(self, factory, *, receipts, owner_admin_id, clock_trusted):
        self.factory, self.receipts = factory, receipts
        self.owner_admin_id, self.clock_trusted = owner_admin_id, clock_trusted
        self.clock = receipts.clock

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
            proof = self.receipts.adapter.transaction_evidence(txid)
        except TronEvidenceUnavailable:
            fail('EVIDENCE_EXPIRED')
        if not isinstance(proof, TransactionEvidence) or proof.txid != txid:
            fail('EVIDENCE_CONFLICT')
        return proof

    def _facts_valid(self, row, proof):
        if (not isinstance(proof, TransactionEvidence) or proof.txid != row.txid
                or proof.network != NETWORK or proof.contract != USDT_CONTRACT
                or proof.policy != POLICY or proof.source_id != SOURCE_ID
                or proof.solid_head.network != NETWORK or proof.solid_head.policy != POLICY
                or proof.solid_head.source_id != SOURCE_ID or proof.block_number > proof.solid_head.height):
            return False
        matches = [t for t in proof.transfers if t.log_index == row.log_index and t.contract == row.contract]
        if len(matches) != 1:
            return False
        transfer = matches[0]
        facts = {'transfer': asdict(transfer), 'network': proof.network, 'policy': proof.policy,
            'source': proof.source_id, 'block': proof.block_id, 'height': proof.block_number,
            'time': proof.timestamp_ms, 'contract': proof.contract}
        # Match the existing ingestion digest exactly, including its separators.
        expected = hashlib.sha256(json.dumps(facts, sort_keys=True).encode()).hexdigest()
        return (expected == row.facts_digest and transfer.txid == row.txid
            and transfer.block_number == proof.block_number and transfer.block_id == proof.block_id
            and transfer.timestamp_ms == proof.timestamp_ms)

    @staticmethod
    def _binding_valid(binding, intent, row):
        return bool(binding and binding.status in {'ACTIVE', 'RETIRED'}
            and binding.user_id == intent.user_id and binding.address == row.source_address
            and binding.version == intent.binding_version
            and binding.effective_from_block == intent.binding_effective_from_block
            and binding.effective_from_block is not None and binding.effective_from_block <= row.block_number
            and (binding.effective_to_block is None or row.block_number < binding.effective_to_block))

    def _snapshot(self, session, row, intent, proof=None, *, payment_attestation=False, reason_code=None):
        binding = session.get(WalletBinding, intent.binding_id)
        user = session.get(User, intent.user_id)
        owner = session.get(WalletAddressOwner, row.source_address)
        control = session.get(WalletControl, 'global')
        blockers = []
        if row.official_address != self.receipts.official_config.address or row.source_address == row.official_address:
            blockers.append('DIRECTION_MISMATCH')
        if row.status == 'CREDITED' or row.ledger_transaction_id or not row.pending_obligation:
            blockers.append('RECEIPT_ALREADY_CREDITED')
        if row.network != NETWORK or row.contract != USDT_CONTRACT or row.amount is None or row.amount < 10:
            blockers.append('EVIDENCE_CONFLICT')
        if (intent.source_address != row.source_address or intent.official_address != row.official_address
                or intent.network != row.network or intent.official_config_version != row.official_config_version
                or row.official_config_version != self.receipts.official_config.version):
            blockers.append('ADDRESS_NETWORK_MISMATCH')
        if intent.expected_amount != row.amount:
            blockers.append('AMOUNT_MISMATCH')
        if not self._binding_valid(binding, intent, row) or owner is None or owner.user_id != intent.user_id:
            blockers.append('BINDING_NOT_EFFECTIVE')
        historical_bindings = list(session.scalars(select(WalletBinding.id).where(
            WalletBinding.address == row.source_address, WalletBinding.effective_from_block <= row.block_number,
            (WalletBinding.effective_to_block.is_(None)) | (WalletBinding.effective_to_block > row.block_number),
            WalletBinding.status.in_(['ACTIVE', 'RETIRED']))))
        if historical_bindings != [intent.binding_id]:
            blockers.append('ATTRIBUTION_AMBIGUOUS')
        if intent.status not in {'OPEN', 'EXPIRED'}:
            blockers.append('ORDER_ALREADY_CONSUMED' if intent.status == 'FULFILLED' else 'ORDER_CLOSED_BY_REBIND')
        if utc(intent.created_at) > self.clock():
            blockers.append('FUTURE_ORDER_RECORD')
        before_order = timedelta(0) < utc(intent.created_at)-utc(row.block_time) <= timedelta(minutes=5)
        permitted_exception = before_order and payment_attestation is True and reason_code == 'PAYMENT_BEFORE_ORDER'
        if not utc(intent.created_at) <= utc(row.block_time) < utc(intent.expires_at) and not permitted_exception:
            blockers.append('TEMPORAL_EVIDENCE_REQUIRED')
        if (row.block_number <= self.receipts.activation_baseline_height
                or utc(row.block_time) < self.receipts.activation_baseline_time):
            blockers.append('PRE_ACTIVATION_BASELINE')
        if session.scalar(select(DepositReceipt.id).where(DepositReceipt.intent_id == intent.id)) is not None:
            blockers.append('ORDER_ALREADY_CONSUMED')
        if session.scalar(select(Deposit.id).where(Deposit.txid == row.txid)) is not None:
            blockers.append('EVIDENCE_CONFLICT')
        if session.scalar(select(DepositReceiptAnomaly.id).join(DepositReceipt,
                DepositReceipt.id == DepositReceiptAnomaly.receipt_id).where(DepositReceipt.txid == row.txid)) is not None:
            blockers.append('EVIDENCE_CONFLICT')
        if user is None or user.status != AccountStatus.ACTIVE:
            blockers.append('USER_UNAVAILABLE')
        risks = [session.get(WalletSafetyState, key) for key in ('global', intent.user_id)]
        if control is None or control.withdrawals_paused or any(r and r.restricted for r in risks):
            blockers.append('FUNDS_CONTROL_BLOCKED')
        if self.clock_trusted() is not True:
            blockers.append('CLOCK_UNTRUSTED')
        reserve = lock_budget(session)
        if reserve is None or not timedelta(0) <= self.clock()-utc(reserve.observed_at) <= timedelta(seconds=120):
            blockers.append('RESERVE_UNAVAILABLE')
        else:
            try:
                require_coverage(session, reserve, policy=self.receipts.reserve_policy)
            except ValueError:
                blockers.append('RESERVE_UNAVAILABLE')
        possible = list(session.scalars(select(DepositIntent).where(DepositIntent.source_address == row.source_address,
            DepositIntent.official_address == row.official_address, DepositIntent.expected_amount == row.amount,
            DepositIntent.network == row.network)))
        eligible = [p.id for p in possible if p.official_config_version == row.official_config_version
            and utc(p.created_at)-timedelta(minutes=5) <= utc(row.block_time) < utc(p.expires_at)
            and self._binding_valid(session.get(WalletBinding, p.binding_id), p, row)]
        if len(eligible) != 1 or eligible[0] != intent.id:
            blockers.append('ATTRIBUTION_AMBIGUOUS')
        if proof is not None:
            if not transaction_evidence_fresh(proof, self.clock()):
                blockers.append('EVIDENCE_EXPIRED')
            if not self._facts_valid(row, proof):
                blockers.append('EVIDENCE_CONFLICT')
            recorded = list(session.scalars(select(DepositReceipt).where(DepositReceipt.txid == row.txid)))
            if any(not self._facts_valid(record, proof) for record in recorded):
                blockers.append('EVIDENCE_CONFLICT')
            same = [t for t in proof.transfers if t.from_address == row.source_address
                and t.to_address == row.official_address and str(t.amount_units) == row.amount_units and t.contract == row.contract]
            if len(same) != 1:
                blockers.append('ATTRIBUTION_AMBIGUOUS')
        snapshot = dict(receipt_id=row.id, intent_id=intent.id, user_id=intent.user_id,
            username=user.username if user else None, nickname=user.nickname if user else None,
            account_status=str(user.status) if user else None,
            receipt_status=row.status, receipt_reason_code=row.reason_code, facts_digest=row.facts_digest,
            amount=str(row.amount), expected_amount=str(intent.expected_amount), asset='USDT', network=row.network,
            contract=row.contract, txid=row.txid, log_index=row.log_index, source_address=row.source_address,
            official_address=row.official_address, official_config_version=row.official_config_version,
            intent_status=intent.status, created_at=utc(intent.created_at).isoformat(), expires_at=utc(intent.expires_at).isoformat(),
            closed_at=utc(intent.closed_at).isoformat() if intent.closed_at else None,
            block_number=row.block_number, block_time=utc(row.block_time).isoformat(),
            binding_id=intent.binding_id, binding_version=intent.binding_version,
            binding_status=binding.status if binding else None,
            binding_activated_at=utc(binding.activated_at).isoformat() if binding and binding.activated_at else None,
            effective_from_block=binding.effective_from_block if binding else None,
            effective_to_block=binding.effective_to_block if binding else None,
            risk_versions=[r.epoch if r else 0 for r in risks], exception_required=intent.status == 'EXPIRED' or before_order,
            payment_before_order_seconds=str((utc(intent.created_at)-utc(row.block_time)).total_seconds()) if before_order else None,
            payment_attestation=payment_attestation,
            blockers=sorted(set(blockers)))
        return snapshot

    def candidates(self, *, actor_id, txid, log_index, authorize, query=None):
        if re.fullmatch('[a-f0-9]{64}', txid) is None or type(log_index) is not int or log_index < 0:
            fail('REPAIR_QUERY_INVALID', 422)
        proof = self._proof(txid)
        with self.factory.begin() as session:
            lock_budget(session)
            fresh = self._authorize(session, actor_id, authorize)
            row = session.scalar(select(DepositReceipt).where(DepositReceipt.txid == txid, DepositReceipt.log_index == log_index,
                DepositReceipt.network == NETWORK, DepositReceipt.contract == USDT_CONTRACT))
            if row is None:
                fail('RECEIPT_NOT_FOUND', 404)
            statement = select(DepositIntent).where(DepositIntent.source_address == row.source_address)
            if query:
                needle = query.strip()
                statement = statement.join(User, User.id == DepositIntent.user_id).where(
                    (DepositIntent.id == needle) | (User.username == needle) | (User.nickname == needle)
                    | (DepositIntent.expected_amount == Decimal(needle) if re.fullmatch(r'\d+(\.\d{1,6})?', needle) else False))
            intents = list(session.scalars(statement.order_by(DepositIntent.created_at.desc(), DepositIntent.id).limit(101)))
            items = [self._snapshot(session, row, intent, proof) for intent in intents[:100]]
            audit_write(session, actor_id, row.id, 'wallet.deposit_repair.candidates_viewed', 'DEPOSIT_REPAIR_READ')
            fresh()
            return dict(receipt_id=row.id, txid=txid, log_index=log_index, items=items, has_more=len(intents)>100,
                reasons=REASONS, evidence_observed_at=utc(proof.observed_at).isoformat())

    def preview(self, *, actor_id, receipt_id, intent_id, reason_code, reason_detail, authorize, payment_attestation=False):
        if reason_code not in REASONS or not isinstance(reason_detail, str) or not 1 <= len(reason_detail.strip()) <= 500:
            fail('REPAIR_REASON_INVALID', 422)
        with self.factory() as session:
            row = session.get(DepositReceipt, receipt_id)
            if row is None:
                fail('RECEIPT_NOT_FOUND', 404)
            txid = row.txid
        proof = self._proof(txid)
        with self.factory.begin() as session:
            lock_budget(session)
            fresh = self._authorize(session, actor_id, authorize)
            row, intent = session.get(DepositReceipt, receipt_id), session.get(DepositIntent, intent_id)
            if row is None or intent is None:
                fail('REPAIR_TARGET_NOT_FOUND', 404)
            snapshot = self._snapshot(session, row, intent, proof, payment_attestation=payment_attestation, reason_code=reason_code)
            snapshot.update(reason_code=reason_code, reason_detail=reason_detail.strip())
            now = self.clock()
            preview = RepairPreview(id=str(uuid4()), actor_id=actor_id, kind='DEPOSIT', digest=digest(snapshot),
                snapshot=snapshot, created_at=now, expires_at=now+timedelta(seconds=90))
            session.add(preview)
            audit_write(session, actor_id, preview.id, 'wallet.deposit_repair.previewed', reason_code)
            fresh()
            return dict(preview_id=preview.id, digest=preview.digest, expires_at=preview.expires_at.isoformat(),
                expected_version=1, blockers=snapshot['blockers'], confirmation=snapshot,
                status='REVIEW_REQUIRED' if snapshot['blockers'] else 'VALIDATED')

    def status(self, *, actor_id, operation_id, authorize):
        with self.factory.begin() as session:
            lock_budget(session)
            fresh = self._authorize(session, actor_id, authorize)
            row = session.get(RepairCommand, operation_id)
            if row is None or row.actor_id != actor_id or row.receipt_id is None:
                fail('REPAIR_OPERATION_NOT_FOUND', 404)
            fresh()
            return row.result

    def execute(self, *, actor_id, preview_id, digest, expected_version, operation_id, idempotency_key, authorize):
        if (not isinstance(idempotency_key, str) or not 1 <= len(idempotency_key.strip()) <= 128
                or not isinstance(operation_id, str) or re.fullmatch('[A-Za-z0-9-]{1,36}', operation_id) is None):
            fail('REPAIR_COMMAND_INVALID', 422)
        payload = dict(preview_id=preview_id, digest=digest, expected_version=expected_version, operation_id=operation_id)
        payload_digest = globals()['digest'](payload)
        # A completed retry requires authorization but no renewed chain request.
        with self.factory.begin() as session:
            lock_budget(session)
            fresh = self._authorize(session, actor_id, authorize)
            replay = session.scalar(select(RepairCommand).where(RepairCommand.actor_id == actor_id,
                RepairCommand.idempotency_key == idempotency_key))
            if replay:
                if replay.payload_digest != payload_digest or replay.receipt_id is None:
                    fail('IDEMPOTENCY_CONFLICT')
                fresh()
                return replay.result
            preview = session.get(RepairPreview, preview_id)
            if preview is None or preview.actor_id != actor_id or preview.kind != 'DEPOSIT':
                fail('REPAIR_PREVIEW_NOT_FOUND', 404)
            txid = preview.snapshot['txid']
        proof = self._proof(txid)
        with self.factory.begin() as session, localcontext() as context:
            context.prec = 40
            lock_budget(session)
            session.get(WalletControl, 'global', with_for_update=True)
            fresh = self._authorize(session, actor_id, authorize)
            replay = session.scalar(select(RepairCommand).where(RepairCommand.actor_id == actor_id,
                RepairCommand.idempotency_key == idempotency_key))
            if replay:
                if replay.payload_digest != payload_digest or replay.receipt_id is None:
                    fail('IDEMPOTENCY_CONFLICT')
                fresh()
                return replay.result
            if session.get(RepairCommand, operation_id) is not None:
                fail('IDEMPOTENCY_CONFLICT')
            preview = session.get(RepairPreview, preview_id)
            if expected_version != 1 or digest != preview.digest:
                fail('VERSION_CONFLICT')
            if not utc(preview.created_at) <= self.clock() < utc(preview.expires_at):
                fail('EVIDENCE_EXPIRED')
            row = session.get(DepositReceipt, preview.snapshot['receipt_id'], with_for_update=True)
            intent = session.get(DepositIntent, preview.snapshot['intent_id'], with_for_update=True)
            session.get(WalletBindingState, intent.user_id, with_for_update=True)
            session.get(WalletBinding, intent.binding_id, with_for_update=True)
            for key in ('global', intent.user_id):
                session.get(WalletSafetyState, key, with_for_update=True)
            require_wallet_actor(session, user_id=intent.user_id, clock=self.clock)
            snapshot = self._snapshot(session, row, intent, proof,
                payment_attestation=preview.snapshot['payment_attestation'], reason_code=preview.snapshot['reason_code'])
            snapshot.update(reason_code=preview.snapshot['reason_code'], reason_detail=preview.snapshot['reason_detail'])
            if snapshot['blockers']:
                fail(snapshot['blockers'][0])
            if globals()['digest'](snapshot) != preview.digest:
                fail('VERSION_CONFLICT')
            now = self.clock()
            fresh()
            reserve = lock_budget(session)
            reserve_observed_at = utc(reserve.observed_at)
            transfer_pending_to_credit(session, amount=row.amount, now=now, policy=self.receipts.reserve_policy)
            transaction = self.receipts.wallet_ledger.post(entries={intent.user_id: row.amount, 'PLATFORM_CUSTODY': -row.amount},
                actor_id=actor_id, reason_code='MANUAL_DEPOSIT_REPAIR', idempotency_key='receipt:'+row.id,
                scope='wallet.deposit.receipt', session=session)
            row.status, row.pending_obligation = 'CREDITED', False
            row.intent_id, row.user_id, row.ledger_transaction_id = intent.id, intent.user_id, transaction.id
            # A still-open intent closes normally; an expired snapshot remains expired.
            if intent.status == 'OPEN':
                intent.status, intent.closed_at = 'FULFILLED', now
            result = dict(operation_id=operation_id, case_id=preview.id, status='EXECUTED', receipt_id=row.id,
                intent_id=intent.id, user_id=intent.user_id, amount=str(row.amount), ledger_transaction_id=transaction.id)
            session.add(RepairCommand(operation_id=operation_id, actor_id=actor_id, idempotency_key=idempotency_key,
                payload_digest=payload_digest, preview_id=preview.id, receipt_id=row.id, intent_id=intent.id,
                result=result, created_at=now))
            audit_write(session, actor_id, operation_id, 'wallet.deposit_repair.executed', snapshot['reason_code'])
            metadata = dict(result, preview_digest=preview.digest, payload_digest=payload_digest,
                reason_detail_digest=globals()['digest'](snapshot['reason_detail']),
                idempotency_key_digest=globals()['digest'](idempotency_key), reason_code=snapshot['reason_code'],
                original_intent_status=snapshot['intent_status'], original_receipt_reason=snapshot['receipt_reason_code'],
                payment_attestation=snapshot['payment_attestation'], authorization='VALID_WALLET_GRANT')
            AuditWriter(self.factory, now_factory=self.clock).record_in_session(session, actor_id=actor_id,
                subject_type='wallet_repair', subject_id=operation_id, action='wallet.deposit_repair.evidence_linked',
                result='SUCCESS', reason_code=snapshot['reason_code'], trace_id=operation_id, after=metadata)
            OutboxPublisher.enqueue(session, topic='wallet', event_type='wallet.deposit_repair.evidence_linked',
                aggregate_type='wallet_repair', aggregate_id=operation_id, payload=metadata, now=now)
            session.flush()
            fresh()
            if self.clock_trusted() is not True:
                fail('CLOCK_UNTRUSTED')
            if not transaction_evidence_fresh(proof, self.clock()) or self.clock() >= utc(preview.expires_at):
                fail('EVIDENCE_EXPIRED')
            if not timedelta(0) <= self.clock()-reserve_observed_at <= timedelta(seconds=120):
                fail('RESERVE_UNAVAILABLE')
            return result
