"""Synchronous PostgreSQL transaction callbacks; no network or secrets in receipts."""
import hashlib
import json
from chatflow_recovery_crypto import canonical


class VaultError(Exception):
    def __init__(self, status, code, details=None):
        super().__init__('Recovery request could not complete')
        self.status, self.code, self.details = status, code, details or {}


def descriptor(envelope, revision=1):
    return {**{key: envelope[key] for key in ('version', 'algorithm', 'public_key', 'public_fingerprint')},
            'revision': revision}


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


class VaultStore:
    MAX_BYTES = 512 * 1024 * 1024
    MAX_CANDIDATES = 100000
    MAX_OPERATIONS = 100000

    def check_schema(self, txn):
        txn.execute('SELECT revision FROM chatflow_recovery_migrations ORDER BY revision')
        if txn.fetchall() != [(1,)]:
            raise VaultError(503, 'M_VAULT_UNAVAILABLE')

    def audit(self, txn, owner, version, device, generation, operation, action):
        txn.execute('INSERT INTO chatflow_recovery_audit '
            '(owner,version,actor_device,authority_generation,operation_id,action) VALUES (?,?,?,?,?,?)',
            (owner, version, device, generation, operation, action))

    def replay(self, txn, owner, operation, request_digest):
        txn.execute('SELECT request_digest,receipt FROM chatflow_recovery_operations '
                    'WHERE owner=? AND operation_id=?', (owner, operation))
        row = txn.fetchone()
        if row:
            if row[0] != request_digest:
                raise VaultError(409, 'M_IDEMPOTENCY_CONFLICT')
            return json.loads(row[1])

    def receipt(self, txn, owner, operation, request_digest, result):
        # Candidate deduplication must not allow unbounded fresh operation IDs.
        # This runs under the owner lock; rejection rolls back the whole upload.
        txn.execute('SELECT COUNT(*) FROM chatflow_recovery_operations WHERE owner=?', (owner,))
        if txn.fetchone()[0] >= self.MAX_OPERATIONS:
            raise VaultError(507, 'M_VAULT_QUOTA_EXCEEDED')
        txn.execute('INSERT INTO chatflow_recovery_operations VALUES (?,?,?,?)',
                    (owner, operation, request_digest, canonical(result).decode()))

    def enroll(self, txn, owner, device, generation, operation, request_digest, envelope):
        self.check_schema(txn)
        txn.execute('INSERT INTO chatflow_recovery_accounts(owner) VALUES (?) ON CONFLICT DO NOTHING', (owner,))
        txn.execute('SELECT active_version FROM chatflow_recovery_accounts WHERE owner=? FOR UPDATE', (owner,))
        active = txn.fetchone()[0]
        previous = self.replay(txn, owner, operation, request_digest)
        if previous is not None:
            return 200, previous
        if active is not None:
            raise VaultError(409, 'M_VAULT_EXISTS')
        if envelope['owner'] != owner:
            raise VaultError(503, 'M_VAULT_UNAVAILABLE')
        version = envelope['version']
        txn.execute('INSERT INTO chatflow_recovery_versions(owner,version,envelope) VALUES (?,?,?)',
                    (owner, version, canonical(envelope).decode()))
        txn.execute('UPDATE chatflow_recovery_accounts SET active_version=?,revision=1 WHERE owner=?', (version, owner))
        result = descriptor(envelope)
        self.receipt(txn, owner, operation, request_digest, result)
        self.audit(txn, owner, version, device, generation, operation, 'ENROLL')
        return 201, result

    def material(self, txn, owner, version):
        self.check_schema(txn)
        txn.execute('SELECT envelope FROM chatflow_recovery_versions WHERE owner=? AND version=?', (owner, version))
        row = txn.fetchone()
        if not row:
            raise VaultError(404, 'M_NOT_FOUND')
        envelope = json.loads(row[0])
        if envelope['owner'] != owner or envelope['version'] != version:
            raise VaultError(503, 'M_VAULT_UNAVAILABLE')
        return envelope

    def status(self, txn, owner):
        self.check_schema(txn)
        txn.execute('SELECT active_version,revision FROM chatflow_recovery_accounts WHERE owner=?', (owner,))
        row = txn.fetchone()
        if row is None:
            return {'state': 'absent', 'collection': None}
        if row[0] is None:
            raise VaultError(503, 'M_VAULT_UNAVAILABLE')
        return {'state': 'available', 'collection': descriptor(self.material(txn, owner, row[0]), row[1])}

    def upload(self, txn, owner, device, generation, version, operation, request_digest, body):
        self.check_schema(txn)
        txn.execute('SELECT active_version,revision,stored_bytes,candidate_count FROM chatflow_recovery_accounts '
                    'WHERE owner=? FOR UPDATE', (owner,))
        account = txn.fetchone()
        if not account or account[0] != version:
            raise VaultError(404, 'M_NOT_FOUND')
        envelope = self.material(txn, owner, version)
        if body['algorithm'] != envelope['algorithm'] or body['public_key'] != envelope['public_key']:
            raise VaultError(409, 'M_VAULT_BINDING_MISMATCH')
        previous = self.replay(txn, owner, operation, request_digest)
        if previous is not None:
            return previous
        staged, conflicts = [], []
        total_bytes = 0
        for entry in body['sessions']:
            scope = (owner, version, entry['room_id'], entry['session_id'])
            txn.execute('SELECT revision,best_digest FROM chatflow_recovery_heads '
                        'WHERE owner=? AND version=? AND room_id=? AND session_id=?', scope)
            head = txn.fetchone()
            revision = head[0] if head else 0
            if revision != entry['expected_revision']:
                conflicts.append({'room_id': entry['room_id'], 'session_id': entry['session_id'], 'revision': revision})
                continue
            candidate = {key: value for key, value in entry.items() if key != 'expected_revision'}
            fingerprint = digest([*scope, candidate])
            txn.execute('SELECT candidate_revision FROM chatflow_recovery_sessions '
                        'WHERE owner=? AND version=? AND room_id=? AND session_id=? AND digest=?', (*scope, fingerprint))
            existing = txn.fetchone()
            encoded = canonical(candidate).decode()
            total_bytes += 0 if existing else len(encoded.encode())
            staged.append((scope, candidate, fingerprint, encoded, revision, existing))
        if conflicts:
            raise VaultError(409, 'M_REVISION_CONFLICT', {'conflicts': conflicts})
        added = sum(item[5] is None for item in staged)
        if account[2] + total_bytes > self.MAX_BYTES or account[3] + added > self.MAX_CANDIDATES:
            raise VaultError(507, 'M_VAULT_QUOTA_EXCEEDED')
        receipts = []
        for scope, candidate, fingerprint, encoded, revision, existing in staged:
            if not existing:
                revision += 1
                txn.execute('INSERT INTO chatflow_recovery_sessions VALUES (?,?,?,?,?,?,?,?,?)',
                    (*scope, fingerprint, revision, candidate['first_message_index'], candidate['forwarded_count'], encoded))
                txn.execute('SELECT digest FROM chatflow_recovery_sessions WHERE owner=? AND version=? AND room_id=? AND session_id=? '
                    'ORDER BY first_message_index,forwarded_count,digest LIMIT 1', scope)
                best = txn.fetchone()[0]
                txn.execute('INSERT INTO chatflow_recovery_heads VALUES (?,?,?,?,?,?) ON CONFLICT(owner,version,room_id,session_id) '
                    'DO UPDATE SET revision=excluded.revision,best_digest=excluded.best_digest', (*scope, revision, best))
            receipts.append({'room_id': scope[2], 'session_id': scope[3], 'revision': revision,
                             'candidate_revision': existing[0] if existing else revision, 'digest': fingerprint})
        new_revision = account[1] + (1 if added else 0)
        txn.execute('UPDATE chatflow_recovery_accounts SET revision=?,stored_bytes=stored_bytes+?,candidate_count=candidate_count+? '
                    'WHERE owner=?', (new_revision, total_bytes, added, owner))
        result = {'version': version, 'revision': new_revision, 'receipts': receipts}
        self.receipt(txn, owner, operation, request_digest, result)
        self.audit(txn, owner, version, device, generation, operation, 'UPLOAD')
        return result

    def query(self, txn, owner, version, pairs, cursor=None):
        self.material(txn, owner, version)
        # One repeatable decision under the same owner lock as writes, no network.
        txn.execute('SELECT revision FROM chatflow_recovery_accounts WHERE owner=? FOR SHARE', (owner,))
        revision = txn.fetchone()[0]
        position, offset = (0, 0) if cursor is None else (cursor['position'], cursor['offset'])
        if cursor and cursor['revision'] != revision:
            raise VaultError(409, 'M_QUERY_CHANGED')
        result = {'version': version, 'revision': revision, 'candidates': [], 'missing': [], 'continuation': None}
        while position < len(pairs):
            room, session = pairs[position]['room_id'], pairs[position]['session_id']
            txn.execute('SELECT revision FROM chatflow_recovery_heads WHERE owner=? AND version=? AND room_id=? AND session_id=?',
                        (owner, version, room, session))
            head = txn.fetchone()
            if not head:
                result['missing'].append(pairs[position])
                position, offset = position + 1, 0
                continue
            remaining = 16 - len(result['candidates'])
            txn.execute('SELECT candidate,candidate_revision,digest FROM chatflow_recovery_sessions '
                'WHERE owner=? AND version=? AND room_id=? AND session_id=? '
                'ORDER BY first_message_index,forwarded_count,digest LIMIT ? OFFSET ?',
                (owner, version, room, session, remaining + 1, offset))
            rows = txn.fetchall()
            for raw, candidate_revision, fingerprint in rows[:remaining]:
                result['candidates'].append({**json.loads(raw), 'revision': head[0],
                    'candidate_revision': candidate_revision, 'digest': fingerprint})
            if len(rows) > remaining:
                offset += remaining
                break
            position, offset = position + 1, 0
            if len(result['candidates']) == 16:
                break
        if position < len(pairs):
            result['continuation'] = {'position': position, 'offset': offset, 'revision': revision}
        return result

    def rewrap_batch(self, txn, old_key_id, new_key_id, keys, limit=40):
        from chatflow_recovery_crypto import rewrap
        if not 1 <= limit <= 80:
            raise ValueError('Invalid batch')
        # Envelope key id is inside authenticated JSON; scan bounded owner/version cursor externally.
        txn.execute('SELECT owner,version,envelope,envelope_revision FROM chatflow_recovery_versions '
                    'WHERE envelope::jsonb->>\'key_id\'=? ORDER BY owner,version LIMIT ? FOR UPDATE SKIP LOCKED',
                    (old_key_id, limit))
        rows = txn.fetchall()
        for owner, version, raw, revision in rows:
            changed = rewrap(json.loads(raw), keys, new_key_id, keys[new_key_id])
            txn.execute('UPDATE chatflow_recovery_versions SET envelope=?,envelope_revision=envelope_revision+1 '
                        'WHERE owner=? AND version=? AND envelope_revision=?',
                        (canonical(changed).decode(), owner, version, revision))
            if txn.rowcount != 1:
                raise VaultError(409, 'M_REVISION_CONFLICT')
            self.audit(txn, owner, version, 'maintenance', 0, None, 'REWRAP')
        return len(rows)
