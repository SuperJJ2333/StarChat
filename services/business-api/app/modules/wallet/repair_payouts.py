"""Review an existing outgoing payment; never create or sign a transfer."""
from datetime import timedelta
from dataclasses import asdict
import re
from uuid import uuid4
from sqlalchemy import select
from app.integrations.tron.finality import transaction_evidence_fresh
from app.modules.ledger.reserve import lock_budget
from app.modules.wallet.manual_payout_models import ManualPayoutOrder, ManualPayoutQuote, ManualPayoutEvent
from app.modules.wallet.repair_models import RepairPreview, RepairCommand
from app.modules.wallet.repairs import digest, fail
from app.modules.wallet.receipts import utc
from app.modules.wallet.safety import audit_write


class PayoutReconciliationService:
    def __init__(self, factory, *, payouts, deposits):
        self.factory, self.payouts, self.deposits = factory, payouts, deposits
        self.clock = deposits.clock

    def _snapshot(self, session, order_id, txid, log_index, proof):
        row = session.get(ManualPayoutOrder, order_id)
        if row is None:
            fail('WALLET_PAYOUT_NOT_FOUND', 404)
        quote = session.get(ManualPayoutQuote, row.quote_id)
        blockers = []
        if row.status not in {'CLAIMED', 'UNKNOWN'} or row.claimed_by != self.deposits.owner_admin_id:
            blockers.append('WALLET_PAYOUT_CLAIM_UNAVAILABLE')
        if row.candidate_txid not in {None, txid}:
            blockers.append('WALLET_PAYOUT_TXID_CONFLICT')
        if self.deposits.clock_trusted() is not True:
            blockers.append('CLOCK_UNTRUSTED')
        if not transaction_evidence_fresh(proof, self.clock()):
            blockers.append('EVIDENCE_EXPIRED')
        matches = self.payouts._matches(proof, row, quote, txid) if row.claimed_at else []
        if len(matches) != 1 or matches[0].log_index != log_index:
            blockers.append('DIRECTION_OR_PAYOUT_EVIDENCE_MISMATCH')
        if session.scalar(select(ManualPayoutEvent.id).where(ManualPayoutEvent.txid == txid,
                ManualPayoutEvent.log_index == log_index)):
            blockers.append('EVENT_ALREADY_ALLOCATED')
        return dict(order_id=row.id, user_id=row.user_id, order_digest=row.digest, order_status=row.status,
            txid=txid, log_index=log_index, amount=str(row.amount), network=quote.snapshot['network'],
            official_address=quote.snapshot['official_address'], target_address=quote.snapshot['target_address'],
            candidate_txid=row.candidate_txid,
            evidence_digest=digest(dict(txid=proof.txid, block_number=proof.block_number, block_id=proof.block_id,
                timestamp_ms=proof.timestamp_ms, network=proof.network, contract=proof.contract,
                policy=proof.policy, source=proof.source_id, transfers=[asdict(t) for t in proof.transfers])) if proof else None,
            blockers=sorted(set(blockers)))

    def preview(self, *, actor_id, order_id, txid, log_index, reason_detail, authorize):
        if re.fullmatch('[a-f0-9]{64}', txid) is None or type(log_index) is not int or log_index < 0:
            fail('REPAIR_QUERY_INVALID', 422)
        if not isinstance(reason_detail, str) or not 1 <= len(reason_detail.strip()) <= 500:
            fail('REPAIR_REASON_INVALID', 422)
        proof = self.deposits._proof(txid)
        with self.factory.begin() as session:
            lock_budget(session)
            fresh = self.deposits._authorize(session, actor_id, authorize)
            snapshot = self._snapshot(session, order_id, txid, log_index, proof)
            snapshot['reason_detail'] = reason_detail.strip()
            now = self.clock()
            row = RepairPreview(id=str(uuid4()), actor_id=actor_id, kind='PAYOUT', digest=digest(snapshot),
                snapshot=snapshot, created_at=now, expires_at=now+timedelta(seconds=90))
            session.add(row)
            audit_write(session, actor_id, row.id, 'wallet.payout_reconciliation.previewed', 'MANUAL_PAYOUT_RECONCILIATION')
            fresh()
            return dict(preview_id=row.id, digest=row.digest, expires_at=row.expires_at.isoformat(), expected_version=1,
                blockers=snapshot['blockers'], confirmation=snapshot, status='REVIEW_REQUIRED' if snapshot['blockers'] else 'VALIDATED')

    def status(self, *, actor_id, operation_id, authorize):
        with self.factory.begin() as session:
            lock_budget(session)
            fresh = self.deposits._authorize(session, actor_id, authorize)
            command = session.get(RepairCommand, operation_id)
            if command is None or command.actor_id != actor_id or command.receipt_id is not None:
                fail('REPAIR_OPERATION_NOT_FOUND', 404)
            row = session.get(ManualPayoutOrder, command.result['order_id'])
            fresh()
            return dict(command.result, status='EXECUTED' if row.status == 'SETTLED' else 'SUBMITTED',
                payout_status=row.status, review_reason=row.review_reason)

    def execute(self, *, actor_id, preview_id, digest, expected_version, operation_id, idempotency_key, authorize):
        if (not isinstance(idempotency_key, str) or not 1 <= len(idempotency_key.strip()) <= 128
                or not isinstance(operation_id, str) or re.fullmatch('[A-Za-z0-9-]{1,36}', operation_id) is None):
            fail('REPAIR_COMMAND_INVALID', 422)
        payload_digest = globals()['digest'](dict(preview_id=preview_id, digest=digest,
            expected_version=expected_version, operation_id=operation_id))
        with self.factory.begin() as session:
            lock_budget(session)
            fresh = self.deposits._authorize(session, actor_id, authorize)
            replay = session.scalar(select(RepairCommand).where(RepairCommand.actor_id == actor_id,
                RepairCommand.idempotency_key == idempotency_key))
            if replay:
                if replay.payload_digest != payload_digest or replay.receipt_id is not None:
                    fail('IDEMPOTENCY_CONFLICT')
                fresh()
                return replay.result
            preview = session.get(RepairPreview, preview_id)
            if preview is None or preview.actor_id != actor_id or preview.kind != 'PAYOUT':
                fail('REPAIR_PREVIEW_NOT_FOUND', 404)
            txid, order_id = preview.snapshot['txid'], preview.snapshot['order_id']
            accepted = dict(operation_id=operation_id, case_id=preview_id, order_id=order_id, status='SUBMITTED',
                txid=txid, log_index=preview.snapshot['log_index'])
        proof = self.deposits._proof(txid)

        def reviewed_authorization(session):
            fresh = self.deposits._authorize(session, actor_id, authorize)
            replay = session.scalar(select(RepairCommand).where(RepairCommand.actor_id == actor_id,
                RepairCommand.idempotency_key == idempotency_key))
            if replay:
                if replay.payload_digest != payload_digest or replay.receipt_id is not None:
                    fail('IDEMPOTENCY_CONFLICT')
                return fresh
            if session.get(RepairCommand, operation_id):
                fail('IDEMPOTENCY_CONFLICT')
            preview = session.get(RepairPreview, preview_id)
            if expected_version != 1 or digest != preview.digest:
                fail('VERSION_CONFLICT')
            if not utc(preview.created_at) <= self.clock() < utc(preview.expires_at):
                fail('EVIDENCE_EXPIRED')
            snapshot = self._snapshot(session, order_id, txid, preview.snapshot['log_index'], proof)
            snapshot['reason_detail'] = preview.snapshot['reason_detail']
            if snapshot['blockers']:
                fail(snapshot['blockers'][0])
            if globals()['digest'](snapshot) != preview.digest:
                fail('VERSION_CONFLICT')
            result = dict(operation_id=operation_id, case_id=preview_id, order_id=order_id, status='SUBMITTED',
                txid=txid, log_index=snapshot['log_index'])
            session.add(RepairCommand(operation_id=operation_id, actor_id=actor_id, idempotency_key=idempotency_key,
                payload_digest=payload_digest, preview_id=preview_id, result=result, created_at=self.clock()))
            audit_write(session, actor_id, operation_id, 'wallet.payout_reconciliation.submitted', 'MANUAL_PAYOUT_RECONCILIATION')

            def final_check():
                fresh()
                if self.deposits.clock_trusted() is not True:
                    fail('CLOCK_UNTRUSTED')
                if not transaction_evidence_fresh(proof, self.clock()) or self.clock() >= utc(preview.expires_at):
                    fail('EVIDENCE_EXPIRED')
            return final_check

        # Candidate and review command commit atomically inside the established
        # public payout method. The existing reconciler performs settlement.
        self.payouts.submit_txid(admin_id=actor_id, order_id=order_id, txid=txid,
            idempotency_key='repair:'+operation_id, authorize=reviewed_authorization)
        return accepted
