import hashlib
import hmac
import json
from dataclasses import dataclass
from decimal import Decimal
from contextlib import contextmanager
from functools import wraps
from pathlib import Path
import sqlite3
from threading import RLock


def persisted(method):
    @wraps(method)
    def wrapped(self, *args, **kwargs):
        with self._transaction():
            return method(self, *args, **kwargs)
    return wrapped

@dataclass(frozen=True)
class SandboxWebhook:
    payload: dict
    signature: str

class SandboxCustodyProvider:
    def __init__(self, *, secret: str, store_path: str | None = None):
        self.secret = secret.encode()
        self.withdrawals = {}
        self.deposits = {}
        self._balance = Decimal("0")
        self._store_path = store_path
        self._lock = RLock()
        self._in_transaction = False
        if store_path:
            Path(store_path).parent.mkdir(parents=True, exist_ok=True)
            with sqlite3.connect(store_path) as db:
                db.execute('CREATE TABLE IF NOT EXISTS sandbox_external_state (id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL)')

    @contextmanager
    def _transaction(self):
        # A separate durable OFFLINE simulation database, never a claim of
        # real custody durability or an independent production intent log.
        with self._lock:
            if self._in_transaction or not self._store_path:
                yield
                return
            with sqlite3.connect(self._store_path, timeout=30) as db:
                db.execute('PRAGMA synchronous=FULL')
                db.execute('BEGIN IMMEDIATE')
                row = db.execute('SELECT payload FROM sandbox_external_state WHERE id=1').fetchone()
                if row:
                    state = json.loads(row[0])
                    self.withdrawals, self.deposits, self._balance = state['withdrawals'], state['deposits'], Decimal(state['balance'])
                self._in_transaction = True
                try:
                    yield
                    payload = json.dumps({'withdrawals': self.withdrawals, 'deposits': self.deposits, 'balance': str(self._balance)}, sort_keys=True)
                    db.execute('INSERT INTO sandbox_external_state(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload', (payload,))
                finally:
                    self._in_transaction = False

    @property
    def custody_balance(self):
        with self._transaction():
            return self._balance

    @custody_balance.setter
    def custody_balance(self, value):
        with self._transaction():
            amount = Decimal(value)
            if not amount.is_finite() or amount < 0:
                raise ValueError('invalid sandbox external balance')
            self._balance = amount

    def create_deposit_address(self, user_id: str) -> str:
        return f"T_SANDBOX_{user_id[:16]}_{hashlib.sha256(user_id.encode()).hexdigest()[:16]}"

    @persisted
    def submit_withdrawal(self, *, client_order_id: str, address: str, amount: Decimal) -> str:
        existing = self.withdrawals.get(client_order_id)
        if existing:
            if existing['address'] != address or Decimal(existing['amount']) != Decimal(amount):
                raise ValueError('custody idempotency payload conflict')
            return existing['txid']
        txid = f"sandbox-tx-{client_order_id}"
        self.withdrawals[client_order_id] = {"client_order_id": client_order_id, "txid": txid, "status": "SUBMITTED", "address": address, "amount": str(amount)}
        return txid

    @persisted
    def get_withdrawal(self, client_order_id: str) -> dict:
        return dict(self.withdrawals.get(client_order_id, {"client_order_id": client_order_id, "status": "UNKNOWN"}))

    @persisted
    def enumerate_withdrawals(self):
        return [dict(row) for row in self.withdrawals.values()]

    @persisted
    def deposit_evidence(self, txid):
        return dict(self.deposits.get(txid, {}))

    @staticmethod
    def verify_finality(evidence, *, threshold):
        return bool(evidence.get('network') == 'TRC20' and evidence.get('contract') == 'SANDBOX_USDT_CONTRACT'
            and evidence.get('execution_success') is True and evidence.get('transfer_valid') is True
            and evidence.get('solidified') is True and evidence.get('sources') == ['offline-node-a', 'offline-node-b']
            and evidence.get('source_blocks') == ['offline-solid-block', 'offline-solid-block']
            and evidence.get('confirmations', 0) >= max(20, threshold))

    @staticmethod
    def _evidence(confirmations):
        return {'network': 'TRC20', 'contract': 'SANDBOX_USDT_CONTRACT', 'execution_success': True,
            'transfer_valid': True, 'solidified': confirmations >= 20,
            'sources': ['offline-node-a', 'offline-node-b'], 'source_blocks': ['offline-solid-block', 'offline-solid-block'],
            'confirmations': confirmations}

    @persisted
    def withdrawal_event(self, *, client_order_id: str, status: str, confirmations: int, event_id: str) -> SandboxWebhook:
        row = self.withdrawals.get(client_order_id, {})
        # Explicit test fixture injection updates the simulated provider query;
        # a separately signed arbitrary callback cannot create this evidence.
        if row and row.get('status') not in {'CHAIN_CONFIRMED', 'FAILED'}:
            row.update(self._evidence(confirmations))
            if status == 'FAILED':
                row.update(status=status, terminal_non_execution=True, independent_no_transfer=True)
            elif status == 'CHAIN_CONFIRMED' and confirmations >= 20:
                row['status'] = status
                self.custody_balance -= Decimal(row['amount'])
        payload = {"event_id": event_id, "type": "WITHDRAWAL_STATUS", "asset": "USDT-TRC20", "client_order_id": client_order_id, "txid": row.get("txid", f"sandbox-tx-{client_order_id}"), "status": status, "confirmations": confirmations}
        return SandboxWebhook(payload, self.sign(payload))

    @persisted
    def deposit_event(self, *, user_id: str, amount: Decimal, confirmations: int, event_id: str) -> SandboxWebhook:
        payload = {"event_id": event_id, "type": "DEPOSIT_CONFIRMED", "asset": "USDT-TRC20", "user_id": user_id, "amount": str(Decimal(amount).quantize(Decimal("0.000001"))), "confirmations": confirmations, "txid": f"sandbox-deposit-{event_id}"}
        existing = self.deposits.get(payload['txid'])
        evidence = {**payload, **self._evidence(confirmations)}
        self.deposits[payload['txid']] = evidence
        if confirmations >= 20 and not (existing and existing.get('solidified')):
            self.custody_balance += Decimal(amount)
        return SandboxWebhook(payload, self.sign(payload))

    def sign(self, payload: dict) -> str:
        raw = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        return hmac.new(self.secret, raw, hashlib.sha256).hexdigest()
