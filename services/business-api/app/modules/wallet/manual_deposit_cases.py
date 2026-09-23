"""Owner-approved allocation of a solid receipt that has no ordinary intent."""
from datetime import timedelta
from decimal import localcontext
import re
from uuid import uuid4

from sqlalchemy import select

from app.core.outbox import OutboxPublisher
from app.modules.audit.writer import AuditWriter
from app.modules.identity.models import AccountStatus, User
from app.modules.identity.wallet_access import require_wallet_actor
from app.modules.ledger.reserve import lock_budget, require_coverage
from app.modules.ledger.wallet_obligations import transfer_pending_to_credit
from app.modules.wallet.binding_models import WalletBinding, WalletBindingState
from app.modules.wallet.funding_models import DepositIntent
from app.modules.wallet.models import Deposit, WalletControl, WalletSafetyState
from app.modules.wallet.receipt_models import DepositReceipt, DepositReceiptAnomaly
from app.modules.wallet.repair_models import ManualDepositCase, ManualDepositDecision, RepairCommand, RepairPreview
from app.modules.wallet.repairs import DepositRepairService, digest, fail
from app.modules.wallet.receipts import utc
from app.modules.wallet.safety import audit_write
from app.integrations.tron.finality import NETWORK, transaction_evidence_fresh
from app.integrations.tron.reader import USDT_CONTRACT


class ManualDepositCaseService:
    def __init__(self, factory, *, receipts, owner_admin_id, clock_trusted):
        self.factory, self.receipts = factory, receipts
        self.owner_admin_id, self.clock_trusted, self.clock = owner_admin_id, clock_trusted, receipts.clock
        self._guard = DepositRepairService(factory, receipts=receipts, owner_admin_id=owner_admin_id, clock_trusted=clock_trusted)

    def _authorize(self, session, actor_id, authorize):
        return self._guard._authorize(session, actor_id, authorize)

    def _proof(self, txid):
        return self._guard._proof(txid)

    def _binding(self, session, row):
        bindings = list(session.scalars(select(WalletBinding).where(WalletBinding.address == row.source_address,
            WalletBinding.status.in_(['ACTIVE', 'RETIRED']), WalletBinding.effective_from_block <= row.block_number,
            (WalletBinding.effective_to_block.is_(None)) | (WalletBinding.effective_to_block > row.block_number))))
        return bindings[0] if len(bindings) == 1 else None

    def _ordinary_available(self, session, row):
        candidates = session.scalars(select(DepositIntent).where(DepositIntent.source_address == row.source_address,
            DepositIntent.official_address == row.official_address, DepositIntent.expected_amount == row.amount,
            DepositIntent.network == row.network, DepositIntent.official_config_version == row.official_config_version,
            DepositIntent.status.in_(['OPEN', 'EXPIRED']))).all()
        return any(utc(intent.created_at) - timedelta(minutes=5) <= utc(row.block_time) < utc(intent.expires_at)
                   and (binding := session.get(WalletBinding, intent.binding_id)) is not None
                   and binding.user_id == intent.user_id and binding.version == intent.binding_version
                   and binding.effective_from_block == intent.binding_effective_from_block
                   and binding.effective_from_block <= row.block_number
                   and (binding.effective_to_block is None or row.block_number < binding.effective_to_block)
                   and session.scalar(select(DepositReceipt.id).where(DepositReceipt.intent_id == intent.id)) is None
                   for intent in candidates)

    def _snapshot(self, session, row, case, proof):
        binding = self._binding(session, row)
        user_id = case.user_id if case is not None else (binding.user_id if binding is not None else None)
        user = session.get(User, user_id) if user_id is not None else None
        decision = (session.scalar(select(ManualDepositDecision).where(ManualDepositDecision.case_id == case.id))
                    if case is not None else None)
        blockers = []
        from app.modules.wallet.recharge_receipts import reserved_for_recharge
        if reserved_for_recharge(session, row.id):
            blockers.append('SUPPORT_RECHARGE_RESERVED')
        if row.status != 'REVIEW' or not row.pending_obligation or row.ledger_transaction_id or row.intent_id or row.manual_case_id:
            blockers.append('RECEIPT_ALREADY_CREDITED')
        if binding is None:
            blockers.append('HISTORICAL_BINDING_UNAVAILABLE')
        elif case is not None and (binding.id, binding.user_id, binding.version, binding.effective_from_block,
                                   binding.effective_to_block) != (case.binding_id, case.user_id, case.binding_version,
                                   case.binding_effective_from_block, case.binding_effective_to_block):
            blockers.append('HISTORICAL_BINDING_UNAVAILABLE')
        if row.official_address != self.receipts.official_config.address or row.source_address == row.official_address:
            blockers.append('DIRECTION_MISMATCH')
        if row.network != NETWORK or row.contract != USDT_CONTRACT or row.amount is None or row.amount < 10:
            blockers.append('EVIDENCE_CONFLICT')
        if row.official_config_version != self.receipts.official_config.version:
            blockers.append('EVIDENCE_CONFLICT')
        if row.block_number <= self.receipts.activation_baseline_height or utc(row.block_time) < self.receipts.activation_baseline_time:
            blockers.append('PRE_ACTIVATION_BASELINE')
        if case is not None and case.facts_digest != row.facts_digest:
            blockers.append('EVIDENCE_CONFLICT')
        if user is None or user.status != AccountStatus.ACTIVE:
            blockers.append('USER_UNAVAILABLE')
        if case is not None and (decision is None or decision.decision != 'APPROVED'):
            blockers.append('MANUAL_CASE_NOT_APPROVED')
        if self._ordinary_available(session, row):
            blockers.append('ORDINARY_INTENT_AVAILABLE')
        if not self._guard._facts_valid(row, proof):
            blockers.append('EVIDENCE_CONFLICT')
        elif not transaction_evidence_fresh(proof, self.clock()):
            blockers.append('EVIDENCE_EXPIRED')
        elif not self.clock_trusted():
            blockers.append('CLOCK_UNTRUSTED')
        recorded = list(session.scalars(select(DepositReceipt).where(DepositReceipt.txid == row.txid)))
        if any(session.scalar(select(DepositReceiptAnomaly.id).where(
                DepositReceiptAnomaly.receipt_id == item.id)) is not None for item in recorded):
            blockers.append('EVIDENCE_CONFLICT')
        if any(not self._guard._facts_valid(other, proof) for other in recorded):
            blockers.append('EVIDENCE_CONFLICT')
        same = [transfer for transfer in proof.transfers if transfer.from_address == row.source_address and transfer.to_address == row.official_address and transfer.contract == row.contract and str(transfer.amount_units) == row.amount_units]
        if len(same) != 1:
            blockers.append('ATTRIBUTION_AMBIGUOUS')
        if session.scalar(select(Deposit.id).where(Deposit.txid == row.txid)) is not None:
            blockers.append('EVIDENCE_CONFLICT')
        control = session.get(WalletControl, 'global')
        risks = [session.get(WalletSafetyState, key) for key in ('global', user_id) if key is not None]
        if control is None or control.withdrawals_paused or any(r and r.restricted for r in risks):
            blockers.append('FUNDS_CONTROL_BLOCKED')
        reserve = lock_budget(session)
        if reserve is None or not timedelta(0) <= self.clock() - utc(reserve.observed_at) <= timedelta(seconds=120):
            blockers.append('RESERVE_UNAVAILABLE')
        else:
            try:
                require_coverage(session, reserve, policy=self.receipts.reserve_policy)
            except ValueError:
                blockers.append('RESERVE_UNAVAILABLE')
        return dict(case_id=case.id if case is not None else None, receipt_id=row.id, user_id=user_id,
            username=user.username if user else None, nickname=user.nickname if user else None,
            account_status=str(user.status) if user else None, txid=row.txid, log_index=row.log_index,
            receipt_status=row.status, receipt_reason_code=row.reason_code, source_address=row.source_address,
            official_address=row.official_address, official_config_version=row.official_config_version,
            amount=str(row.amount), asset='USDT', network=row.network, contract=row.contract, block_number=row.block_number,
            block_time=utc(row.block_time).isoformat(), facts_digest=row.facts_digest,
            binding_id=case.binding_id if case is not None else (binding.id if binding else None),
            binding_version=case.binding_version if case is not None else (binding.version if binding else None),
            effective_from_block=case.binding_effective_from_block if case is not None else (binding.effective_from_block if binding else None),
            effective_to_block=case.binding_effective_to_block if case is not None else (binding.effective_to_block if binding else None),
            ordinary_intent_available=self._ordinary_available(session, row),
            decision=decision.decision if decision else None,
            blockers=sorted(set(blockers)))

    def context(self, *, actor_id, txid, log_index, authorize):
        with self.factory.begin() as session:
            lock_budget(session); fresh = self._authorize(session, actor_id, authorize)
            row = session.scalar(select(DepositReceipt).where(DepositReceipt.txid == txid, DepositReceipt.log_index == log_index))
            if row is None: fail('RECEIPT_NOT_FOUND', 404)
            receipt_id, receipt_txid = row.id, row.txid
            fresh()
        proof = self._proof(receipt_txid)
        with self.factory.begin() as session, localcontext() as context:
            context.prec = 40
            lock_budget(session); fresh = self._authorize(session, actor_id, authorize)
            row = session.get(DepositReceipt, receipt_id)
            if row is None: fail('RECEIPT_NOT_FOUND', 404)
            snapshot = self._snapshot(session, row, None, proof)
            fresh()
            return dict(**snapshot, cases=[self._case_view(session, item) for item in session.scalars(
                select(ManualDepositCase).where(ManualDepositCase.receipt_id == row.id))])

    def create(self, *, actor_id, receipt_id, user_id, reason_detail, ownership_attestation, idempotency_key, authorize):
        if not ownership_attestation or not isinstance(reason_detail, str) or not 1 <= len(reason_detail.strip()) <= 500:
            fail('MANUAL_CASE_INVALID', 422)
        payload = dict(receipt_id=receipt_id, user_id=user_id, reason_detail=reason_detail.strip(), ownership_attestation=True)
        with self.factory.begin() as session:
            lock_budget(session); fresh = self._authorize(session, actor_id, authorize)
            existing = session.scalar(select(ManualDepositCase).where(ManualDepositCase.actor_id == actor_id,
                ManualDepositCase.idempotency_key == idempotency_key))
            if existing is not None:
                if existing.payload_digest != digest(payload): fail('IDEMPOTENCY_CONFLICT')
                fresh(); return self._case_view(session, existing)
            receipt = session.get(DepositReceipt, receipt_id)
            if receipt is None: fail('RECEIPT_NOT_FOUND', 404)
            txid = receipt.txid
            fresh()
        proof = self._proof(txid)
        with self.factory.begin() as session, localcontext() as context:
            context.prec = 40
            lock_budget(session); fresh = self._authorize(session, actor_id, authorize)
            existing = session.scalar(select(ManualDepositCase).where(ManualDepositCase.actor_id == actor_id, ManualDepositCase.idempotency_key == idempotency_key))
            if existing:
                if existing.payload_digest != digest(payload): fail('IDEMPOTENCY_CONFLICT')
                fresh(); return self._case_view(session, existing)
            row = session.get(DepositReceipt, receipt_id, with_for_update=True)
            if row is None: fail('RECEIPT_NOT_FOUND', 404)
            binding = self._binding(session, row)
            if binding is None: fail('HISTORICAL_BINDING_UNAVAILABLE')
            if binding.user_id != user_id: fail('USER_MISMATCH')
            snapshot = self._snapshot(session, row, None, proof)
            if snapshot['blockers']: fail(snapshot['blockers'][0])
            now = self.clock(); case = ManualDepositCase(id=str(uuid4()), receipt_id=row.id, user_id=user_id, binding_id=binding.id,
                binding_version=binding.version, binding_effective_from_block=binding.effective_from_block,
                binding_effective_to_block=binding.effective_to_block, facts_digest=row.facts_digest, actor_id=actor_id,
                idempotency_key=idempotency_key, payload_digest=digest(payload), reason_detail_digest=digest(reason_detail.strip()),
                reason_detail=reason_detail.strip(), ownership_attestation=True, created_at=now)
            session.add(case); audit_write(session, actor_id, case.id, 'wallet.manual_deposit_case.created', 'MANUAL_DEPOSIT_CASE')
            OutboxPublisher.enqueue(session, topic='wallet', event_type='wallet.manual_deposit_case.created', aggregate_type='wallet_manual_deposit_case', aggregate_id=case.id, payload={'receipt_id':row.id,'user_id':user_id}, now=now)
            fresh(); return self._case_view(session, case)

    def _case_view(self, session, case):
        decision = session.scalar(select(ManualDepositDecision).where(ManualDepositDecision.case_id == case.id))
        receipt = session.get(DepositReceipt, case.receipt_id)
        user = session.get(User, case.user_id)
        status = 'EXECUTED' if receipt and receipt.manual_case_id == case.id else decision.decision if decision else 'PENDING_DECISION'
        return dict(case_id=case.id, status=status, receipt_id=case.receipt_id, user_id=case.user_id, actor_id=case.actor_id,
            reason_detail=case.reason_detail, reason_detail_digest=case.reason_detail_digest, ownership_attestation=case.ownership_attestation,
            created_at=utc(case.created_at).isoformat(), binding_id=case.binding_id, binding_version=case.binding_version,
            effective_from_block=case.binding_effective_from_block, effective_to_block=case.binding_effective_to_block,
            facts_digest=case.facts_digest, username=user.username if user else None, nickname=user.nickname if user else None,
            txid=receipt.txid if receipt else None, log_index=receipt.log_index if receipt else None,
            source_address=receipt.source_address if receipt else None, official_address=receipt.official_address if receipt else None,
            official_config_version=receipt.official_config_version if receipt else None, amount=str(receipt.amount) if receipt else None,
            asset='USDT', network=receipt.network if receipt else None, contract=receipt.contract if receipt else None,
            block_number=receipt.block_number if receipt else None, block_time=utc(receipt.block_time).isoformat() if receipt else None,
            ledger_transaction_id=receipt.ledger_transaction_id if status == 'EXECUTED' else None,
            decision=None if decision is None else dict(decision=decision.decision, actor_id=decision.actor_id, created_at=utc(decision.created_at).isoformat(), reason_detail=decision.reason_detail, reason_detail_digest=decision.reason_detail_digest))

    def get(self, *, actor_id, case_id, authorize):
        with self.factory.begin() as session:
            lock_budget(session); fresh=self._authorize(session,actor_id,authorize); case=session.get(ManualDepositCase,case_id)
            if case is None: fail('MANUAL_CASE_NOT_FOUND',404)
            fresh(); return self._case_view(session,case)

    def decide(self, *, actor_id, case_id, decision, reason_detail, confirmed, idempotency_key, authorize):
        if decision not in {'APPROVED','REJECTED'} or confirmed is not True or not isinstance(reason_detail,str) or not reason_detail.strip(): fail('MANUAL_CASE_INVALID',422)
        payload=dict(case_id=case_id,decision=decision,reason_detail=reason_detail.strip())
        with self.factory.begin() as session:
            lock_budget(session); fresh=self._authorize(session,actor_id,authorize); case=session.get(ManualDepositCase,case_id,with_for_update=True)
            if case is None: fail('MANUAL_CASE_NOT_FOUND',404)
            replay = session.scalar(select(ManualDepositDecision).where(ManualDepositDecision.actor_id == actor_id, ManualDepositDecision.idempotency_key == idempotency_key))
            if replay is not None:
                if replay.payload_digest != globals()['digest'](payload): fail('IDEMPOTENCY_CONFLICT')
                fresh(); return self._case_view(session, case)
            prior=session.scalar(select(ManualDepositDecision).where(ManualDepositDecision.case_id==case_id))
            if prior is not None: fail('MANUAL_CASE_ALREADY_DECIDED')
            now=self.clock(); row=ManualDepositDecision(id=str(uuid4()),case_id=case_id,actor_id=actor_id,decision=decision,idempotency_key=idempotency_key,payload_digest=digest(payload),reason_detail_digest=digest(reason_detail.strip()),reason_detail=reason_detail.strip(),created_at=now)
            session.add(row); audit_write(session,actor_id,row.id,'wallet.manual_deposit_case.decided','MANUAL_DEPOSIT_'+decision)
            OutboxPublisher.enqueue(session,topic='wallet',event_type='wallet.manual_deposit_case.decided',aggregate_type='wallet_manual_deposit_case',aggregate_id=case_id,payload={'decision':decision},now=now)
            session.flush(); fresh(); return self._case_view(session,case)

    def preview(self, *, actor_id, case_id, authorize):
        with self.factory.begin() as session:
            lock_budget(session); fresh = self._authorize(session, actor_id, authorize)
            case=session.get(ManualDepositCase,case_id)
            if case is None: fail('MANUAL_CASE_NOT_FOUND',404)
            txid=session.get(DepositReceipt,case.receipt_id).txid
            fresh()
        proof=self._proof(txid)
        with self.factory.begin() as session, localcontext() as context:
            context.prec = 40
            lock_budget(session); fresh=self._authorize(session,actor_id,authorize); case=session.get(ManualDepositCase,case_id); row=session.get(DepositReceipt,case.receipt_id)
            snapshot=self._snapshot(session,row,case,proof); now=self.clock(); preview=RepairPreview(id=str(uuid4()),actor_id=actor_id,kind='MANUAL_DEPOSIT',digest=digest(snapshot),snapshot=snapshot,created_at=now,expires_at=now+timedelta(seconds=90))
            session.add(preview); audit_write(session,actor_id,preview.id,'wallet.manual_deposit_case.previewed','MANUAL_DEPOSIT_CASE'); fresh()
            return dict(preview_id=preview.id,digest=preview.digest,expires_at=preview.expires_at.isoformat(),expected_version=1,blockers=snapshot['blockers'],confirmation=snapshot,status='REVIEW_REQUIRED' if snapshot['blockers'] else 'VALIDATED')

    def execute(self, *, actor_id, case_id, preview_id, digest: str, expected_version, operation_id, idempotency_key, authorize):
        payload=dict(case_id=case_id,preview_id=preview_id,digest=digest,expected_version=expected_version,operation_id=operation_id)
        if (not isinstance(idempotency_key, str) or not 1 <= len(idempotency_key.strip()) <= 128
                or not isinstance(operation_id, str) or re.fullmatch('[A-Za-z0-9-]{1,36}', operation_id) is None):
            fail('REPAIR_COMMAND_INVALID', 422)
        payload_digest = globals()['digest'](payload)
        # A completed command must be recoverable even while the evidence provider is unavailable.
        with self.factory.begin() as session:
            lock_budget(session); fresh = self._authorize(session, actor_id, authorize)
            replay = session.scalar(select(RepairCommand).where(RepairCommand.actor_id == actor_id, RepairCommand.idempotency_key == idempotency_key))
            if replay:
                prior = session.get(RepairPreview, replay.preview_id)
                if replay.payload_digest != payload_digest or prior is None or prior.kind != 'MANUAL_DEPOSIT': fail('IDEMPOTENCY_CONFLICT')
                fresh(); return replay.result
            if session.get(RepairCommand, operation_id) is not None:
                fail('IDEMPOTENCY_CONFLICT')
        with self.factory() as session:
            preview=session.get(RepairPreview,preview_id)
            if preview is None or preview.kind!='MANUAL_DEPOSIT' or preview.snapshot.get('case_id')!=case_id: fail('REPAIR_PREVIEW_NOT_FOUND',404)
            txid=preview.snapshot['txid']
        proof=self._proof(txid)
        with self.factory.begin() as session, localcontext() as context:
            context.prec = 40
            lock_budget(session); session.get(WalletControl,'global',with_for_update=True); fresh=self._authorize(session,actor_id,authorize)
            replay=session.scalar(select(RepairCommand).where(RepairCommand.actor_id==actor_id,RepairCommand.idempotency_key==idempotency_key))
            if replay:
                prior=session.get(RepairPreview,replay.preview_id)
                if replay.payload_digest != payload_digest or prior is None or prior.kind!='MANUAL_DEPOSIT': fail('IDEMPOTENCY_CONFLICT')
                fresh(); return replay.result
            if session.get(RepairCommand, operation_id) is not None:
                fail('IDEMPOTENCY_CONFLICT')
            preview=session.get(RepairPreview,preview_id)
            if preview is None or preview.actor_id!=actor_id or preview.kind!='MANUAL_DEPOSIT' or expected_version!=1 or digest!=preview.digest or not utc(preview.created_at)<=self.clock()<utc(preview.expires_at): fail('VERSION_CONFLICT')
            case=session.get(ManualDepositCase,case_id,with_for_update=True); row=session.get(DepositReceipt,case.receipt_id,with_for_update=True)
            session.get(WalletBindingState,case.user_id,with_for_update=True); session.get(WalletBinding,case.binding_id,with_for_update=True)
            for key in ('global',case.user_id): session.get(WalletSafetyState,key,with_for_update=True)
            require_wallet_actor(session,user_id=case.user_id,clock=self.clock)
            snapshot=self._snapshot(session,row,case,proof)
            if snapshot['blockers'] or globals()['digest'](snapshot)!=preview.digest: fail(snapshot['blockers'][0] if snapshot['blockers'] else 'VERSION_CONFLICT')
            now=self.clock(); fresh(); transfer_pending_to_credit(session,amount=row.amount,now=now,policy=self.receipts.reserve_policy)
            transaction=self.receipts.wallet_ledger.post(entries={case.user_id:row.amount,'PLATFORM_CUSTODY':-row.amount},actor_id=actor_id,reason_code='MANUAL_LATE_DEPOSIT_ALLOCATION',idempotency_key='receipt:'+row.id,scope='wallet.deposit.receipt',session=session)
            row.status,row.pending_obligation,row.manual_case_id,row.user_id,row.ledger_transaction_id='CREDITED',False,case.id,case.user_id,transaction.id
            conversion = None
            if self.receipts.deposit_auto_conversion_enabled:
                from app.modules.wallet.deposit_conversion import convert_credited_receipt
                conversion = convert_credited_receipt(session, self.factory, receipt_id=row.id,
                    actor_id=actor_id, enabled=True, reserve_policy=self.receipts.reserve_policy)
            result=dict(operation_id=operation_id,case_id=case.id,status='EXECUTED',receipt_id=row.id,user_id=case.user_id,amount=str(row.amount),ledger_transaction_id=transaction.id,
                **({'conversion': conversion} if conversion else {}))
            session.add(RepairCommand(operation_id=operation_id,actor_id=actor_id,idempotency_key=idempotency_key,payload_digest=payload_digest,preview_id=preview.id,receipt_id=row.id,intent_id=None,result=result,created_at=now))
            audit_write(session,actor_id,operation_id,'wallet.manual_deposit_case.executed','MANUAL_LATE_DEPOSIT_ALLOCATION')
            AuditWriter(self.factory, now_factory=self.clock).record_in_session(session, actor_id=actor_id,
                subject_type='wallet_manual_deposit_case', subject_id=case.id,
                action='wallet.manual_deposit_case.evidence_linked', result='SUCCESS',
                reason_code='MANUAL_LATE_DEPOSIT_ALLOCATION', trace_id=operation_id,
                after={'case_id':case.id, 'decision':'APPROVED', 'preview_digest':preview.digest,
                       'idempotency_key_digest':globals()['digest'](idempotency_key),
                       'reason_detail_digest':case.reason_detail_digest})
            OutboxPublisher.enqueue(session,topic='wallet',event_type='wallet.manual_deposit_case.executed',aggregate_type='wallet_manual_deposit_case',aggregate_id=case.id,payload=result,now=now)
            session.flush(); fresh()
            if self.clock_trusted() is not True or not transaction_evidence_fresh(proof, self.clock()) or self.clock() >= utc(preview.expires_at):
                fail('EVIDENCE_EXPIRED')
            reserve = lock_budget(session)
            if reserve is None or not timedelta(0) <= self.clock() - utc(reserve.observed_at) <= timedelta(seconds=120):
                fail('RESERVE_UNAVAILABLE')
            return result

    def status(self, *, actor_id, operation_id, authorize):
        with self.factory.begin() as session:
            lock_budget(session); fresh=self._authorize(session,actor_id,authorize); command=session.get(RepairCommand,operation_id)
            preview=session.get(RepairPreview,command.preview_id) if command else None
            if command is None or command.actor_id!=actor_id or preview is None or preview.kind!='MANUAL_DEPOSIT': fail('REPAIR_OPERATION_NOT_FOUND',404)
            fresh(); return command.result
