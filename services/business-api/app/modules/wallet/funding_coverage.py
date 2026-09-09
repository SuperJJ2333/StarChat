"""Observer discovery is not finality. Verify complete transactions separately."""
from dataclasses import asdict
from datetime import datetime, timezone
import hashlib
import json
import re
from uuid import uuid4

from sqlalchemy import or_, select

from app.integrations.tron.finality import NETWORK, POLICY, SOURCE_ID, USDT_CONTRACT, TransactionEvidence, SolidHead
from app.integrations.tron.message_signature import canonical_address
from app.modules.ledger.reserve import lock_budget
from app.modules.ledger.wallet_obligations import invalidate_wallet_reserve
from app.modules.wallet.funding_coverage_models import WalletFundingCoverageEvent as Coverage
from app.modules.wallet.models import WalletControl
from app.modules.wallet.receipt_models import DepositReceipt, DepositReceiptAnomaly
from app.modules.wallet.safety import audit_write


def _aware(value):
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise ValueError('aware funding coverage clock required')
    return value.astimezone(timezone.utc)


def _utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def _facts(event):
    return dict(txid=event.txid, log_index=event.log_index, amount_units=str(event.amount_units),
                from_address=event.from_address, to_address=event.to_address,
                block_number=event.block_number, timestamp_ms=event.timestamp_ms)


def _conflict(session, rows, actor_id, now):
    for row in rows:
        if row.status != 'CONFLICT':
            row.status, row.conflict_at = 'CONFLICT', now
            invalidate_wallet_reserve(session)
            audit_write(session, actor_id, row.id, 'wallet.coverage.conflict', 'SOURCE_FACTS_CONFLICT')


def _result(rows, status=None):
    return dict(status=status or ('CONFLICT' if any(r.status == 'CONFLICT' for r in rows) else
                'VERIFIED' if rows and all(r.status == 'VERIFIED' for r in rows) else 'PENDING'),
                total=len(rows), verified=sum(r.status == 'VERIFIED' for r in rows),
                conflicts=sum(r.status == 'CONFLICT' for r in rows))


def discover(session, *, source_identity, events, actor_id, now):
    """Caller owns reserve → control → scan locks and baseline filtering."""
    now = _aware(now)
    if not actor_id or not isinstance(source_identity, str) or not re.fullmatch('[0-9a-f]{64}', source_identity):
        raise ValueError('invalid funding coverage identity')
    events = tuple(events)
    if len(events) > 100:
        raise ValueError('funding coverage batch too large')
    rows = []
    for item in events:
        if (not isinstance(item.txid, str) or not re.fullmatch('[0-9a-f]{64}', item.txid)
                or any(type(v) is not int or not 0 <= v <= 2**63-1
                       for v in (item.rowid, item.log_index, item.block_number, item.timestamp_ms))
                or item.rowid == 0 or type(item.amount_units) is not int
                or not 0 <= item.amount_units < 2**256):
            raise ValueError('invalid funding coverage facts')
        canonical_address(item.from_address)
        canonical_address(item.to_address)
        facts = _facts(item)
        found = session.scalars(select(Coverage).where(Coverage.source_identity == source_identity,
            or_(Coverage.source_rowid == item.rowid,
                (Coverage.txid == item.txid) & (Coverage.log_index == item.log_index)))).all()
        if found:
            if any(r.source_rowid != item.rowid or r.facts_digest != _digest(facts) for r in found):
                _conflict(session, found, actor_id, now)
            rows.extend(found)
        else:
            row = Coverage(id=str(uuid4()), source_identity=source_identity, source_rowid=item.rowid,
                **facts, facts_digest=_digest(facts), status='PENDING', created_at=now)
            session.add(row)
            invalidate_wallet_reserve(session)
            audit_write(session, actor_id, row.id, 'wallet.coverage.discovered', 'SOURCE_LOG_DISCOVERED')
            rows.append(row)
        session.flush()
    return _result(rows)


class FundingCoverageService:
    def __init__(self, session_factory, *, finality_adapter, official_config, clock):
        canonical_address(official_config.address)
        if not official_config.version or not callable(clock):
            raise ValueError('funding coverage configuration required')
        self.factory, self.adapter, self.config, self.clock = session_factory, finality_adapter, official_config, clock
        self.source_identity = hashlib.sha256(('tron-mainnet-usdt:'+official_config.address).encode()).hexdigest()

    def _rows(self, session, txid):
        return session.scalars(select(Coverage).where(Coverage.source_identity == self.source_identity,
            Coverage.txid == txid).order_by(Coverage.source_rowid)).all()

    def verify_transaction(self, txid, *, actor_id):
        if not actor_id or not isinstance(txid, str) or not re.fullmatch('[0-9a-f]{64}', txid):
            raise ValueError('invalid funding coverage request')
        with self.factory() as session:
            rows = self._rows(session, txid)
            before = {(r.id, r.facts_digest) for r in rows}
            if not rows or any(r.status == 'CONFLICT' for r in rows):
                return _result(rows)
        try:
            evidence = self.adapter.transaction_evidence(txid)
        except Exception:
            return _result(rows, 'UNAVAILABLE')
        with self.factory.begin() as session:
            lock_budget(session)
            control = session.get(WalletControl, 'global', with_for_update=True)
            rows = self._rows(session, txid)
            if control is None:
                return _result(rows, 'UNAVAILABLE')
            if any(r.status == 'CONFLICT' for r in rows):
                return _result(rows)
            if before != {(r.id, r.facts_digest) for r in rows}:
                return _result(rows, 'PENDING')
            now = _aware(self.clock())
            if not self._valid(evidence, txid, now):
                return _result(rows, 'UNAVAILABLE')
            stable = dict(network=evidence.network, contract=evidence.contract, policy=evidence.policy,
                          source_id=evidence.source_id, block_id=evidence.block_id)
            if any(r.proof is not None and any(r.proof.get(key) != value for key, value in stable.items())
                   for r in rows):
                _conflict(session, rows, actor_id, now)
                return _result(rows)
            relevant = [t for t in evidence.transfers if self.config.address in (t.from_address, t.to_address)]
            transaction_digest = _digest(sorted((_facts(t) for t in relevant), key=lambda facts: facts['log_index']))
            prior_proofs = [r.proof for r in rows if r.proof is not None]
            if any(not p.get('transaction_facts_digest') for p in prior_proofs):
                # Historical proof is immutable and cannot be silently upgraded.
                invalidate_wallet_reserve(session)
                return _result(rows, 'UNAVAILABLE')
            if any(p['transaction_facts_digest'] != transaction_digest for p in prior_proofs):
                _conflict(session, rows, actor_id, now)
                return _result(rows)
            by_log = {t.log_index: t for t in relevant}
            if len(by_log) != len(relevant) or any(r.log_index not in by_log or
                    r.facts_digest != _digest(_facts(by_log[r.log_index])) for r in rows):
                _conflict(session, rows, actor_id, now)
                return _result(rows)
            if set(by_log) != {r.log_index for r in rows}:
                return _result(rows, 'PENDING')
            if any(not self._liability(session, evidence, t) for t in relevant):
                invalidate_wallet_reserve(session)
                if prior_proofs and any(self._incoming_anomaly(session, t) for t in relevant):
                    _conflict(session, rows, actor_id, now)
                    return _result(rows)
                return _result(rows, 'PENDING')
            proof = dict(network=evidence.network, contract=evidence.contract, policy=evidence.policy,
                source_id=evidence.source_id, block_id=evidence.block_id,
                solid_height=evidence.solid_head.height, solid_block_id=evidence.solid_head.block_id,
                evidence_observed_at=evidence.observed_at.isoformat(),
                transaction_facts_digest=transaction_digest)
            for row in rows:
                if row.status == 'PENDING':
                    row.status, row.proof, row.verified_at = 'VERIFIED', proof, now
                    audit_write(session, actor_id, row.id, 'wallet.coverage.verified', 'FULL_TRANSACTION_VERIFIED')
            return _result(rows)

    @staticmethod
    def _valid(e, txid, now):
        try:
            if not isinstance(e, TransactionEvidence) or not isinstance(e.solid_head, SolidHead):
                return False
            head = e.solid_head
            if (e.txid != txid or e.network != NETWORK or e.contract != USDT_CONTRACT
                    or e.policy != POLICY or e.source_id != SOURCE_ID or head.network != NETWORK
                    or head.policy != POLICY or head.source_id != SOURCE_ID
                    or type(e.block_number) is not int or not 0 <= e.block_number <= head.height
                    or not re.fullmatch('[0-9a-f]{64}', e.block_id)
                    or not re.fullmatch('[0-9a-f]{64}', head.block_id)):
                return False
            if any(not 0 <= (now-_aware(t)).total_seconds() <= 120 for t in (e.observed_at, head.observed_at)):
                return False
            return all(t.txid == txid and t.contract == USDT_CONTRACT and t.block_id == e.block_id
                and t.block_number == e.block_number and t.timestamp_ms == e.timestamp_ms
                and type(t.amount_units) is int and 0 <= t.amount_units < 2**256
                and type(t.log_index) is int and t.log_index >= 0 for t in e.transfers)
        except (AttributeError, TypeError, ValueError):
            return False

    def _incoming_anomaly(self, session, transfer):
        if transfer.to_address != self.config.address or transfer.from_address == transfer.to_address:
            return False
        return session.scalar(select(DepositReceiptAnomaly.id).join(DepositReceipt,
            DepositReceiptAnomaly.receipt_id == DepositReceipt.id).where(
                DepositReceipt.network == NETWORK, DepositReceipt.contract == USDT_CONTRACT,
                DepositReceipt.txid == transfer.txid, DepositReceipt.log_index == transfer.log_index)) is not None

    def _liability(self, session, evidence, transfer):
        if transfer.to_address != self.config.address or transfer.from_address == transfer.to_address:
            return True
        row = session.scalar(select(DepositReceipt).where(DepositReceipt.network == NETWORK,
            DepositReceipt.contract == USDT_CONTRACT, DepositReceipt.txid == transfer.txid,
            DepositReceipt.log_index == transfer.log_index))
        if row is None:
            return False
        digest = _digest(dict(transfer=asdict(transfer), network=evidence.network, policy=evidence.policy,
            source=evidence.source_id, block=evidence.block_id, height=evidence.block_number,
            time=evidence.timestamp_ms, contract=evidence.contract))
        return (row.facts_digest == digest and row.official_config_version == self.config.version
            and row.source_address == transfer.from_address and row.official_address == transfer.to_address
            and row.amount_units == str(transfer.amount_units) and row.amount is not None
            and (row.status == 'CREDITED' or (row.status == 'REVIEW' and row.pending_obligation))
            and session.scalar(select(DepositReceiptAnomaly.id).where(DepositReceiptAnomaly.receipt_id == row.id)) is None)
