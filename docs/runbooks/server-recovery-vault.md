# Server-custodied Matrix recovery vault v1

This runbook implements the approved [custody ADR](../adr/2026-10-04-server-custodied-matrix-recovery.md).
Deployment remains disabled until independent domain/specification then quality/security
review, native Synapse/PostgreSQL, actual Dart Olm interoperability, Linux credential
permissions and isolated mixed-key disaster-recovery gates pass. Root release owner
performs all production operations. Task3A implementer never reads production keys.

## Contract and compatibility

The frozen executable wire schema is
[recovery-v1.schema.json](../../third_party/synapse/recovery-v1.schema.json).
It defines exact request/response fields, UUID operation IDs, CAS receipts, errors,
limits and continuation semantics. JSON strings use canonical unpadded standard
base64 for Curve25519 and encrypted backup data. An upload candidate is at most
16KiB including its wrapper; body is at most1MiB,80 candidates; query at most64 pairs,
16 returned candidates/page,1MiB response. Material response at most4KiB.
Enrollment/material descriptor `revision` is1; status/upload/query top-level revision
tracks the collection. Nested candidate/receipt revision is the per-session CAS
value. Compare immutable version/algorithm/public key/fingerprint binding, never
these different revision scopes. The schema's `x-semantics` freezes this distinction.

`Authorization: Bearer <Matrix access token>` and
`X-StarChat-Session: Bearer <current Business access token>` are both required.
Business receives only `matrix_user_id` and `matrix_device_id`, verifies current
mobile family/device and returns those plus `family_id`/`generation`. Staff roles
may use their own legitimate mobile credentials. Console/service sessions and
Matrix admin/appservice/guest/impersonated credentials are rejected.

The final authority decision happens after awaited reads, immediately before
commit/release. A later distributed revocation cannot retract already released
bytes. No positive authorization cache is maintained. An unavailable authority,
schema, keyring or corrupted envelope returns503, never an absent/replacement vault.

The vault has a separate namespace. Native room_keys/version, SSSS, cross-signing,
existing device policy and MobileLoginModule remain unchanged. Server code never
decrypts session archives, room messages or attachments. Custody means the operator
has the cryptographic ability to recover archived keys; do not describe it as a
server-blind recovery system. Missing historical keys cannot be reconstructed.

## Database and rollback

Apply `third_party/synapse/chatflow_recovery_migrate.py` explicitly using a dedicated
operator Python environment with psycopg3 and libpq service/password file outside
the repository. Never put a password/DSN in command arguments or output. The
versioned `recovery_migrations/001.sql` creates only namespaced tables, with a
transactional advisory lock7395186231001 and SHA256 migration ledger. It never
changes Synapse schema_version92 or applied media deltas. Existing migration hash
mismatch/unknown revision is fatal. Runtime never lazily creates tables.

Exact uniqueness: accounts(owner) primary key; versions(owner,version) primary key
and version unique; accounts(owner,active_version) composite FK; heads(owner,version,
room_id,session_id) primary key; sessions(owner,version,room_id,session_id,digest)
primary key plus unique candidate_revision in that same scope; operations(owner,
operation_id) primary key. Enrollment owner row lock, version/pointer/receipt/audit
commit atomically. Session uploads take that owner lock, precheck every CAS, append
all candidates and receipts or roll back all. Candidate metadata is an untrusted
ranking hint; the mobile consumer must perform genuine cryptographic validation.
Owner quotas are512MiB candidate bytes,100000 candidates and100000 committed
operations. A full operation journal rejects new writes atomically with507;
existing operation replay remains available. No recovery material is evicted.

Disable the module config/namespace and roll back to the frozen compatible image
if needed. Preserve every table, envelope, candidate, operation, audit record and
wrapping key; no downgrade/destructive migration exists. Restoring an older DB over
new custody is prohibited. No user-facing delete/reset/export operation exists.

## Primary systemd255 provider and main-only mount

Frozen primary encrypted credential:
`/etc/credstore.encrypted/chatflow-recovery-keyring.cred` (root:root0600; directory0700).
Install reviewed provider/crypto/store Python modules under `/opt/chatflow-recovery/`
root-owned and nonwritable by Synapse. Use a dedicated Python3.12 environment at
`/opt/chatflow-recovery/venv/bin/python`; both systemd and SSH helper invocations
use this exact interpreter. Install only the pinned
`third_party/synapse/recovery-provider-requirements.txt` into this environment.
Preflight Python3.12, cryptography43.0.3, PyNaCl1.5.0, cffi2.1.1, pycparser3.0,
psycopg3.2.10 and `pip check`; freeze the actual Linux package manifest/hash after
native systemd/crypto tests. Windows isolated tests verified that cffi/pycparser
pair; that alone is not the Linux gate. Never downgrade Business cryptography.
Install
`infra/synapse/recovery/chatflow-recovery-materialize.service` without starting it.
The unit uses `LoadCredentialEncrypted=chatflow-recovery-keyring:...`, decrypting
through the systemd credential facility. Its root materializer writes
`/run/chatflow-recovery/keyring.json` on tmpfs, owned991:991,0400, parent0711.
Actual inspected main process UID/GID is991; the worker's UID0 does **not** authorize
a master mount. Verify container mounts, not just Unix access from a root exec.

The recovery Compose overlay mounts only main's `/run/chatflow-recovery` read-only;
worker, Business and backup services get no mount. Main core dump limit0;
traceback-local capture/APM request/response bodies must remain disabled. Python
managed-memory reliable zeroization is not claimed. No secrets go in `.env`,
images, source, logs, release archives or database backups.

`RecoveryVaultModule` checks effective `worker_app` and returns before schema,
provider or resource access. Main-only module config is `enabled: false` until the
gate passes. Then install its explicit config in the existing shared modules list
beside MobileLoginModule; never replace that list. The dedicated Nginx include uses
the existing `synapse_upstream` main target, disables body/access logging/cache and
buffered proxy storage. Validate rendered Nginx and Compose with the actual existing
deployment, including inherited worker config. Public login/admin deny rules remain.
Workers inheriting that module declaration must have the module code/import
dependencies available too, so the early return can execute; they must receive no
credential mount. A main-only code overlay with a shared new module declaration
and an old worker image is not a valid deployment.
The module attaches a narrow filter to pinned Synapse's `synapse.storage.SQL` and
`synapse.storage.txn` loggers. Only its `chatflow_recovery-<hex>` transaction records
are suppressed, including DEBUG parameters and database exception values; other
transactions retain their existing logging. Never enable request/response tracing.
Unsupported verbs that enter a recovery location receive JSON405/no-store.
Nginx rejects TRACE before location selection: the approved R2 protocol exception
allows only its fixed, input-independent405 HTML response without a no-store header.
It must never reflect credentials/body, redirect, reach upstream or mutate state.

Include `infra/synapse/recovery/nginx-http.conf` once in **http context**, before
the affected server blocks. Its complementary maps depend only on request method,
never URI spelling. Then include `infra/synapse/recovery/nginx.conf` inside the
existing **Matrix server context**. The paired server access logs preserve the
frozen ordinary destination `/var/log/nginx/access.log` and `main` format for every
non-TRACE request. TRACE writes only time, constant method, status, bytes and Nginx's
generated request ID to that same destination. Do not retain a duplicate raw TRACE
logger. Keep `/ios-call/`'s existing location logging-off override. Preserve the
effective `/var/log/nginx/error.log notice`; never weaken it to warn or enable
DEBUG/body tracing. Root must freeze `nginx -T` again before integration and preserve
every actual destination/format/option/condition if production has changed.

R2 acceptance captures all access/error destinations independently: canonical,
encoded, normalized and double-slash public/private TRACE with separate query,
Matrix bearer, Business bearer and body sentinels must produce only safe metadata.
A non-TRACE control must retain the original main log format/destination. This
does not authorize global logging suppression or a server-wide405 rewrite.
The actual module registration is the private
`/_synapse/client/chatflow/recovery/v1` tree. The public prefix translates to it
exactly at the gateway (R1); direct public private paths stay403. This avoids the
native client router's leaf node without changing core code. Any query is rejected
at the gateway before upstream URI logs; oversize/upstream errors are fixed JSON
with no-store. Bare base404 does not redirect credentials.

## Every-key provisioning, confirmation and rotation

Commands below are operation names passed to the reviewed Python helper, not
permission to run production mutations from a task implementer. Initial `init KEYID`
requires no existing primary credential; it creates one inactive CSPRNG256bit key.
`prepare KEYID` appends a new inactive key or idempotently retains the existing same
ID. No command regenerates an existing key or repairs a missing credential by
silently initializing another ring.

For **every** initial/rotated ID:

1. Primary `init`/`prepare` creates `primary_inactive`. Old active key stays active.
2. Windows operator runs `scripts/recovery-vault-dr.ps1 -Action backup -KeyId ID
   -Python <dedicated Python>` under the intended persistent Windows account.
3. Helper generates ephemeral RAM RSA3072/OAEP-SHA256 receiver; strict existing
   SSH (`-J jumper -p23421`, host verification on) sends only its public key.
   Remote `seal` returns only RSA ciphertext. Local RAM decrypt is immediately
   CurrentUser DPAPI protected and atomically saved/read back; synthetic AES-GCM
   envelope confirms the recovered key. Only then a nonsecret HMAC readback proof
   is sent to `confirm` and primary state becomes
   `independent_protected_and_readback_confirmed`.
4. Primary `activate ID` refuses missing/wrong proof. Confirm activation durably,
   restart materializer, verify991 can read while the mount is read-only, then
   restart main as needed. Unknown/lost confirmation retries the same ID; do not
   generate a new ID as a retry. Retain all old IDs in both providers.
5. `rewrap OLD_ID` verifies current active proof and enters `bounded_rewrap` before
   one batch (at most40 envelopes) under row locks/revision CAS. Fresh96bit AES-GCM
   nonce and AAD wrap the **same** private key. Repeat bounded batches while count
   is nonzero, yielding operationally between batches. Do not delete old wrapping
   keys: historical database backups still depend on them.

Independent persistent destination is exactly
`%USERPROFILE%/.chatflow-recovery-vault/credentials/207.56.8.8/KEYID.dpapi`.
Protected ACL grants only the current SID and SYSTEM. It is separate from APK
signing credentials and outside repository/evidence folders. The supplied PowerShell
entry sets UTF8/BOM-free encodings; provider never emits plaintext key bytes or
exception locals. Unknown existing independent material fails rather than overwrites.

## Independent loss/restore rehearsal

Before activation, use synthetic keys and a dedicated PostgreSQL schema/database,
never production account material. Exercise failure before DPAPI save, after save
before ACK, before active switch, and during a rewrap transaction. Verify old active
persists, same ID retry, no replacement private material, and no secret logs.

Save an isolated actual database backup containing old/new key envelopes. Lose the
primary credential and host credential key in the isolated environment. On a fresh
replacement host with **no** primary credential, `restore-send ACTIVE_ID` on Windows
opens strictSSH `restore-receive ACTIVE_ID`. Receiver creates ephemeral RAM RSA key,
sender DPAPI-unprotects every retained ID and sends RSA sealed records only. Receiver
recreates the systemd encrypted ring and readback-verifies it. No plaintext key enters
an argv/stdout/artifact. Restore the isolated database backup; verify original private
material/public bindings and actual SDK archive recovery. Both providers lost remains
unrecoverable. OS codec tests do not substitute for this full isolated loss rehearsal.

## Gates and release ownership

Task3A evidence explicitly labels real PostgreSQL16.9 versus SQLite, real Windows
DPAPI versus model tests, native Synapse versus synthetic Business network authority,
and Python/Dart crypto versus full mobile restore. Review ordered domain/spec then
security; use actual output hashes, exit codes, timings and frozen source inputs.
Root owns production release and must re-read live images/config/schema before
minimal overlays; preserve published token-refresh protocol, S3/media/Getui and
wallet boundaries. Rollback disables custody while retaining its data/providers.
When restoring a pre-vault image, restore its frozen config/remove only the new
module stanza as well, so a missing new Python module cannot prevent startup.
