"""Trusted solidified receipt ingestion, separate from any client money claim."""
from collections import Counter
from dataclasses import asdict
from datetime import datetime, timezone
from decimal import Decimal, DecimalException, localcontext
import hashlib
import json
import re
from uuid import uuid4

from sqlalchemy import select
from app.integrations.tron.finality import TransactionEvidence, POLICY, SOURCE_ID, NETWORK, transaction_evidence_fresh, TronEvidenceUnavailable
from app.integrations.tron.reader import USDT_CONTRACT
from app.integrations.tron.message_signature import canonical_address
from app.modules.identity.models import User, AccountStatus
from app.modules.ledger.reserve import lock_budget
from app.modules.ledger.wallet_obligations import synchronize_wallet_liability, transfer_pending_to_credit, invalidate_wallet_reserve
from app.modules.wallet.binding_models import WalletBinding, WalletBindingState
from app.modules.wallet.funding_models import DepositIntent
from app.modules.wallet.models import WalletControl, Deposit, WalletSafetyState
from app.modules.wallet.receipt_models import DepositReceipt, DepositReceiptAnomaly
from app.modules.wallet.safety import audit_write, usdt_liability
from app.modules.wallet.service import WalletLedger


def utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


class DepositReceiptService:
    reserve_policy = 'full_backing'
    def __init__(self, session_factory, *, finality_adapter, official_config,
                 activation_baseline_time, activation_baseline_height, clock, wallet_ledger=None):
        if (official_config is None or not isinstance(official_config.version, str)
                or not 1 <= len(official_config.version) <= 128):
            raise ValueError('official funding configuration required')
        canonical_address(official_config.address)
        if (not isinstance(activation_baseline_time, datetime) or activation_baseline_time.tzinfo is None
                or type(activation_baseline_height) is not int or activation_baseline_height < 0):
            raise ValueError('explicit activation baseline required')
        self.factory, self.adapter, self.official_config = session_factory, finality_adapter, official_config
        self.activation_baseline_time, self.activation_baseline_height = activation_baseline_time, activation_baseline_height
        self.clock = clock
        self.wallet_ledger = wallet_ledger or WalletLedger(session_factory)

    @staticmethod
    def _result(row, quarantined=False):
        return {'id': row.id, 'status': 'QUARANTINED' if quarantined else row.status,
                'reason_code': 'EVIDENCE_CONFLICT' if quarantined else row.reason_code,
                'amount': str(row.amount) if row.amount is not None else None}

    @staticmethod
    def _conflict(session, row, *, digest, actor_id, now):
        if session.scalar(select(DepositReceiptAnomaly).where(
                DepositReceiptAnomaly.receipt_id == row.id,
                DepositReceiptAnomaly.observed_digest == digest)) is None:
            session.add(DepositReceiptAnomaly(id=str(uuid4()), receipt_id=row.id,
                observed_digest=digest, reason_code='EVIDENCE_CONFLICT', observed_at=now))
            invalidate_wallet_reserve(session)
            audit_write(session, actor_id, row.id, 'wallet.deposit_receipt_conflict', 'EVIDENCE_CONFLICT')
            session.flush()

    def _match(self, session, row, *, reevaluate=False):
        if row.reason_code != 'UNMATCHED' and not (reevaluate and row.reason_code in {
                'DEFERRED_RESERVE_CHECK', 'RESERVE_UNAVAILABLE', 'MULTIPLE_MATCHING_LOGS'}):
            return None, row.reason_code
        if row.amount < 10:
            return None, 'BELOW_MINIMUM'
        if row.block_number <= self.activation_baseline_height or utc(row.block_time) < self.activation_baseline_time:
            return None, 'PRE_ACTIVATION_BASELINE'
        candidates = list(session.scalars(select(DepositIntent).where(
            DepositIntent.source_address == row.source_address,
            DepositIntent.official_address == row.official_address,
            DepositIntent.official_config_version == row.official_config_version,
            DepositIntent.network == row.network, DepositIntent.expected_amount == row.amount)))
        matching = []
        for intent in candidates:
            if not utc(intent.created_at) <= utc(row.block_time) < utc(intent.expires_at):
                continue
            binding = session.get(WalletBinding, intent.binding_id)
            if (binding is None or binding.user_id != intent.user_id or binding.address != row.source_address
                    or binding.version != intent.binding_version or binding.effective_from_block is None
                    or binding.effective_from_block != intent.binding_effective_from_block
                    or not binding.effective_from_block <= row.block_number
                    or binding.effective_to_block is not None and row.block_number >= binding.effective_to_block):
                continue
            matching.append(intent)
        if len(matching) != 1:
            return None, 'NO_UNIQUE_INTENT'
        intent = matching[0]
        if session.get(WalletBindingState, intent.user_id, with_for_update=True) is None:
            return None, 'BINDING_STATE_UNAVAILABLE'
        if intent.status != 'OPEN':
            return None, 'INTENT_' + intent.status
        user = session.get(User, intent.user_id)
        risk = session.get(WalletSafetyState, intent.user_id)
        if user is None or user.status != AccountStatus.ACTIVE or risk is not None and risk.restricted:
            return None, 'USER_UNAVAILABLE'
        return intent, 'MATCHED'

    def ingest(self, txid, *, actor_id, defer_credit=False):
        if type(defer_credit) is not bool:
            raise ValueError('explicit deferred credit flag required')
        return self._ingest(txid, actor_id=actor_id, defer_credit=defer_credit)

    def retry_credit(self, receipt_id, *, actor_id):
        """Reverify the complete transaction before retrying one reserved credit."""
        if not isinstance(receipt_id, str) or not receipt_id or len(receipt_id) > 36 or not actor_id:
            raise ValueError('receipt identity and actor required')
        with self.factory() as session:
            row = session.get(DepositReceipt, receipt_id)
            if row is None:
                raise ValueError('deposit receipt not found')
            quarantined = session.scalar(select(DepositReceiptAnomaly.id).where(
                DepositReceiptAnomaly.receipt_id == row.id).limit(1)) is not None
            if quarantined or row.status != 'REVIEW' or row.reason_code not in {'DEFERRED_RESERVE_CHECK', 'RESERVE_UNAVAILABLE'}:
                return self._result(row, quarantined)
            txid = row.txid
        results = self._ingest(txid, actor_id=actor_id, retry_receipt_id=receipt_id)
        return next(result for result in results if result['id'] == receipt_id)

    def _ingest(self, txid, *, actor_id, defer_credit=False, retry_receipt_id=None):
        if not isinstance(txid, str) or re.fullmatch('[0-9a-f]{64}', txid) is None or not actor_id:
            raise ValueError('canonical transaction id and actor required')
        # Network I/O finishes before any database locks or financial transaction.
        evidence = self.adapter.transaction_evidence(txid)
        if not isinstance(evidence, TransactionEvidence) or evidence.txid != txid:
            raise ValueError('trusted transaction evidence required')
        if retry_receipt_id is not None and (evidence.block_number > evidence.solid_head.height
                or evidence.solid_head.network != NETWORK or evidence.solid_head.policy != POLICY
                or evidence.solid_head.source_id != SOURCE_ID):
            raise ValueError('trusted solidification proof required')
        now = self.clock()
        if not isinstance(now, datetime) or now.tzinfo is None:
            raise ValueError('aware clock required')
        with self.factory.begin() as session:
            lock_budget(session)
            if session.get(WalletControl, 'global', with_for_update=True) is None:
                raise ValueError('wallet control unavailable')
            # Reserve freshness must include any wait for the shared locks.
            now = self.clock()
            if not isinstance(now, datetime) or now.tzinfo is None or now.utcoffset() is None:
                raise ValueError('aware clock required')
            if not transaction_evidence_fresh(evidence, now):
                raise TronEvidenceUnavailable('TRON evidence expired before receipt processing')
            legacy = session.scalar(select(Deposit).where(Deposit.txid == txid))
            recorded = list(session.scalars(select(DepositReceipt).where(DepositReceipt.txid == txid)))
            observed_keys = set()
            rows, candidates, results, matching_intents = [], [], [], []
            for transfer in evidence.transfers:
                observed_keys.add((evidence.network, transfer.contract, transfer.log_index))
                facts = {'transfer': asdict(transfer), 'network': evidence.network,
                         'policy': evidence.policy, 'source': evidence.source_id,
                         'block': evidence.block_id, 'height': evidence.block_number,
                         'time': evidence.timestamp_ms, 'contract': evidence.contract}
                digest = hashlib.sha256(json.dumps(facts, sort_keys=True).encode()).hexdigest()
                row = session.scalar(select(DepositReceipt).where(DepositReceipt.network == evidence.network,
                    DepositReceipt.contract == transfer.contract, DepositReceipt.txid == txid,
                    DepositReceipt.log_index == transfer.log_index))
                if row is not None:
                    conflict = row.facts_digest != digest
                    if conflict:
                        self._conflict(session, row, digest=digest, actor_id=actor_id, now=now)
                    quarantined = conflict or session.scalar(select(DepositReceiptAnomaly.id).where(
                        DepositReceiptAnomaly.receipt_id == row.id).limit(1)) is not None
                    if not quarantined and row.status == 'REVIEW':
                        candidate, reason = self._match(session, row, reevaluate=True)
                        if candidate is not None:
                            matching_intents.append(candidate.id)
                        if row.id == retry_receipt_id and row.reason_code in {'DEFERRED_RESERVE_CHECK', 'RESERVE_UNAVAILABLE'}:
                            row.reason_code = reason
                            rows.append(row)
                            candidates.append(candidate)
                            continue
                    results.append(self._result(row, quarantined))
                    continue
                if transfer.to_address != self.official_config.address:
                    continue
                amount = None
                if type(transfer.amount_units) is int and 0 <= transfer.amount_units < 10**30:
                    with localcontext() as context:
                        context.prec = 40
                        amount = (Decimal(transfer.amount_units) / Decimal(1000000)).quantize(Decimal('0.000001'))
                valid = (evidence.network == NETWORK and evidence.contract == USDT_CONTRACT
                         and transfer.contract == USDT_CONTRACT and evidence.policy == POLICY
                         and evidence.source_id == SOURCE_ID)
                consistent = (transfer.txid == txid and transfer.block_number == evidence.block_number
                              and transfer.block_id == evidence.block_id and transfer.timestamp_ms == evidence.timestamp_ms
                              and evidence.block_number <= evidence.solid_head.height)
                reason = ('INVALID_ASSET_EVIDENCE' if not valid else 'INCONSISTENT_EVIDENCE' if not consistent
                          else 'SELF_TRANSFER' if transfer.from_address == transfer.to_address
                          else 'AMOUNT_UNREPRESENTABLE' if amount is None
                          else 'LEGACY_TXID_OVERLAP' if legacy is not None else 'UNMATCHED')
                row = DepositReceipt(id=str(uuid4()), network=evidence.network, contract=transfer.contract,
                    txid=txid, log_index=transfer.log_index, source_address=transfer.from_address,
                    official_address=transfer.to_address, official_config_version=self.official_config.version,
                    amount_units=str(transfer.amount_units), amount=amount, block_number=transfer.block_number,
                    block_id=transfer.block_id, block_time=datetime.fromtimestamp(transfer.timestamp_ms/1000, timezone.utc),
                    evidence_policy=evidence.policy, evidence_source=evidence.source_id, observed_at=evidence.observed_at,
                    facts_digest=digest, status='REVIEW', reason_code=reason,
                    # Legacy rows have no log identity: conservatively retain all
                    # incoming obligations until a reviewed reconciliation maps them.
                    pending_obligation=valid and transfer.from_address != transfer.to_address and amount is not None)
                candidate, row.reason_code = self._match(session, row)
                rows.append(row)
                candidates.append(candidate)
                if candidate is not None:
                    matching_intents.append(candidate.id)
                session.add(row)
                session.flush()
            # The trusted adapter returns the complete transaction, so absence of
            # a previously recorded log is evidence conflict, not a scan cursor.
            for row in recorded:
                if (row.network, row.contract, row.log_index) not in observed_keys:
                    missing = {'kind': 'RECORDED_LOG_MISSING', 'txid': txid,
                        'network': evidence.network, 'contract': evidence.contract,
                        'policy': evidence.policy, 'source': evidence.source_id,
                        'block': evidence.block_id, 'height': evidence.block_number,
                        'time': evidence.timestamp_ms, 'missing_receipt': row.id,
                        'observed_keys': sorted(observed_keys)}
                    digest = hashlib.sha256(json.dumps(missing, sort_keys=True).encode()).hexdigest()
                    self._conflict(session, row, digest=digest, actor_id=actor_id, now=now)
                    results.append(self._result(row, True))
            if retry_receipt_id is not None:
                conflicts = list(session.scalars(select(DepositReceiptAnomaly.observed_digest)
                    .join(DepositReceipt, DepositReceipt.id == DepositReceiptAnomaly.receipt_id)
                    .where(DepositReceipt.txid == txid)))
                if conflicts:
                    # A known contradiction elsewhere in the complete transaction
                    # cannot disappear merely because reserve evidence is refreshed.
                    for index, row in enumerate(rows):
                        if row.id == retry_receipt_id:
                            digest = hashlib.sha256(json.dumps({'kind':'TRANSACTION_EVIDENCE_CONFLICT',
                                'txid':txid,'conflicts':sorted(conflicts)},sort_keys=True).encode()).hexdigest()
                            self._conflict(session,row,digest=digest,actor_id=actor_id,now=now)
                            row.reason_code = 'EVIDENCE_CONFLICT'
                            results.append(self._result(row,True))
                            rows.pop(index)
                            candidates.pop(index)
                            break
            counts = Counter(matching_intents)
            if rows:
                synchronize_wallet_liability(session, total=usdt_liability(session))
            if any(row.reason_code in {'PRE_ACTIVATION_BASELINE', 'AMOUNT_UNREPRESENTABLE', 'INCONSISTENT_EVIDENCE'} for row in rows):
                invalidate_wallet_reserve(session)
            for row, candidate in zip(rows, candidates):
                # Matching may wait for a binding lock after the initial budget
                # lock check. Recheck the complete evidence at each consumption.
                now = self.clock()
                if not transaction_evidence_fresh(evidence, now):
                    raise TronEvidenceUnavailable('TRON evidence expired before credit')
                if candidate is not None and counts[candidate.id] > 1:
                    row.reason_code = 'MULTIPLE_MATCHING_LOGS'
                if candidate is not None and counts[candidate.id] == 1:
                    if defer_credit or retry_receipt_id is not None and row.id != retry_receipt_id:
                        row.reason_code = 'DEFERRED_RESERVE_CHECK'
                        audit_write(session, actor_id, row.id, 'wallet.deposit_receipt_recorded', 'TRON_RECEIPT_REVIEW')
                        results.append(self._result(row))
                        continue
                    try:
                        # The shared ledger also adds the credit back into the
                        # reserve total. Cover both sides of that conversion and
                        # coverage checks with enough precision for Numeric(30,6).
                        with localcontext() as context:
                            context.prec = max(40, context.prec)
                            with session.begin_nested():
                                transfer_pending_to_credit(session, amount=row.amount, now=now, policy=self.reserve_policy)
                                transaction = self.wallet_ledger.post(entries={candidate.user_id:row.amount, 'PLATFORM_CUSTODY':-row.amount},
                                    actor_id=actor_id, reason_code='TRON_DEPOSIT_CREDIT', idempotency_key='receipt:'+row.id,
                                    scope='wallet.deposit.receipt', session=session)
                                row.status, row.pending_obligation = 'CREDITED', False
                                row.reason_code = 'TRON_DEPOSIT_CREDIT'
                                row.intent_id, row.user_id, row.ledger_transaction_id = candidate.id, candidate.user_id, transaction.id
                                candidate.status, candidate.closed_at = 'FULFILLED', now
                                session.flush()
                    except DecimalException:
                        # The public ledger may not support all Numeric(30,6)
                        # magnitudes. Roll back only the financial savepoint;
                        # keep the exact receipt obligation for reviewed handling.
                        row.reason_code = 'LEDGER_PRECISION_UNSUPPORTED'
                        invalidate_wallet_reserve(session)
                    except ValueError as error:
                        if str(error) not in {'reserve evidence missing','reserve evidence stale','insufficient reserve coverage',
                                              'reserve issuance blocked during unresolved payouts','pending obligation not reconciled'}:
                            raise
                        row.reason_code = 'RESERVE_UNAVAILABLE'
                audit_write(session, actor_id, row.id, 'wallet.deposit_receipt_recorded', 'TRON_RECEIPT_' + row.status)
                results.append(self._result(row))
            session.flush()
            return results
