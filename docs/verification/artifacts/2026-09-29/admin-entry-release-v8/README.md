# Admin entry v8 release publisher

**Status: locally frozen; server operations await separate review.** The v4
archive remains the earlier readiness-proof audit. v5 stopped at read-only
preflight because the running API points to a guarded two-service Compose
source. v6 passed preflight, private backup, candidate/compatible rollback
build and dual-role image gates, then failed before its four PostgreSQL races:
the probe tried to create all registered models in a synthetic schema, and the
unrelated `red_packets.fee_exempt` model has an integer default for a Boolean
column. Its isolated clone was removed by exact ID; production remained at
0091 with the original API and Worker. Preserve v5 and v6 as immutable audit
records. v7 passed preflight, private backup and dual-role image gates, then
its clone restore raced PostgreSQL initialization: `pg_isready` returned
success before the target `clone` database existed. The exception path removed
that clone; production remained at 0091 with the original images. Preserve v7
as failed audit evidence. This package uses the distinct release ID
`admin-entry-merge-20260929-v8` and a new backup and clone.

The production baseline reported after the separate identity/Moments r2 release
is API `sha256:8015e9637fb33c3cf07995612ba1680dbdd3acec4705dee062803517d4bd26d3`,
Worker `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`,
and Alembic `0091_moment_video_posters`. A fresh v8 read through the jumper
found all 21 API and 18 static before targets matched, including eight
verified absent paths. API Compose SHA was
`3aad8e267b27dc278e8baa880586d5479b7b634f8d3e2757b6dc3fd65f5c3181`;
Worker Compose SHA was
`ef55565cd973a538e4d572e3cf05cfcb32fa58c20627239237cf587fa39a0f29`.
The local v8 `live-baseline-readonly.json` records exact per-file SHA and
absence. The API container's guarded Compose source has both API and Worker
services; the running Worker points to its older Worker-only source. The two
sources' complete Worker service dictionaries are equal. Read-only normalized
rendering and the absence of a third service are recorded without environment
values in `compose-baseline-readonly.json`. **Server preflight must recheck
every identity again before any write.**

## Intended scope

The 21 API paths are `app/api/admin.py`, `admin_report_contracts.py`,
`admin_session_boundary.py`, `admin_wallet_owner_transfers.py`,
`admin_wallet_repairs.py`, `identity.py`, `manual_wallet_handover.py`,
`manual_wallet_operations.py`; `app/main.py`;
`app/modules/admin/service.py`, `user_directory.py`;
`app/modules/identity/models.py`, `recovery.py`, `staff_activation.py`,
`staff_password.py`, `tokens.py`, `wallet_access.py`, `wallet_grant.py`;
`app/modules/ledger/service.py`, `app/modules/support/service.py`; and
`migrations/versions/0092_admin_session_entry_mode.py`. Paths are relative to
`services/business-api/`. The unrelated `app/modules/audit/writer.py`
production difference is expressly excluded. API inventory checks cover the
complete `/opt/business-api/app` and `/opt/business-api/migrations` Python
trees, so an unintended candidate file change fails the build.

Worker overlay: **zero**; the current immutable Worker image is checked by the
role-aware protocol guard at candidate and rollback. The 18 static targets are
`admin.html` and `src/admin-login.js`, `src/styles/admin-login.css`,
`src/admin-staff-activation-dialog.js`, `src/admin-staff-password-dialog.js`,
`src/admin-session.js`, `src/admin-dashboard.js`, `src/admin-home.js`,
`src/admin-user-directory.js`, `src/admin-api.js`, `src/admin-wallet-access.js`,
`src/admin-manual-wallet-panel.js`, `src/admin-chain-panel.js`,
`src/admin-wallet-repair-dialog.js`, `src/admin-manual-deposit-case.js`,
`src/admin-login-scene.js`, `src/admin-loading.js`, and `src/styles/tokens.css`.
The tokens payload must come only from the reviewed baseline-plus-58-variable
`admin-entry-release/static-overlay/src/styles/tokens.css` with SHA
`39bebda4b6b18452f79da5fc758bedc20a8b8bb453ff02ad489dfc88046e1853`.
`download.html`, iOS assets, byte-identical paths, and unrelated source
differences are excluded.

## State machine for final review

`manifest.json` pins the reviewed guard/probe and PG probe hashes with
`frozen=true`. `release.py stage` copies
only the manifest paths after checking every source SHA. The archive must be
checked independently before server upload. Any source or live before-state
drift requires a new release freeze; never edit the frozen package in place.
Read-only `live-baseline-readonly.json`, `compose-baseline-readonly.json`, and
local tests are verification evidence, not part of the upload archive.

The reviewed operator sequence after a separate deployment decision is:

```sh
cd /opt/starchat/releases/admin-entry-merge-20260929-v8
python3 server_release.py preflight
python3 server_release.py prepare
python3 server_release.py build
python3 server_release.py restore
python3 server_release.py migrate-clone
python3 server_release.py run-pg-probe
python3 server_release.py restore-finalize
python3 server_release.py migrate-production
python3 server_release.py deploy
python3 server_release.py verify
python3 public_verify.py
```

`prepare` creates a 0700 private directory with 0600 PostgreSQL dump,
container/Compose snapshots, static originals, and original image archive.
Static originals copied with `copy2` are explicitly chmodded to 0600.
`preflight` checks both actual Compose source SHA values, the running image and
environment of every included service, exact API/Worker source consistency,
and the final merge in guard order (`-f api -f worker`). `prepare` freezes that
complete merged configuration privately. Candidate and rollback Compose files
are rendered in the same order and must match the frozen configuration with
only the two explicitly pinned role images changed. An extra service, Worker
image override, or non-image configuration drift blocks the image guard and
every production mutation.
`build` uses the current immutable API base twice: a candidate image with the
exact 21 files, and a rollback-compatible API image with **only the reviewed
0092 migration**. Both complete Python inventories are compared against the
base. Final candidate and rollback API 9/9 and Worker 8/8 checks remain
mandatory. A raw r2 API image cannot be restarted against a 0092 database:
its entrypoint runs Alembic head without the 0092 revision.

`restore` waits up to 60 seconds for a real SQL query against the target
`clone` database over container loopback TCP, then loads the dump through that
same TCP endpoint into a pinned PostgreSQL image with `--network none`. A
temporary Unix socket or generic `pg_isready` response cannot admit restore.
On timeout or restore error, only the exact new clone is removed and the
write-once successful restore record is absent.
`migrate-clone` runs the reviewed 0092 revision through the candidate image,
checks the nullable column, constraint, legacy NULL rows, and table/constraint
counts, then runs the compatible rollback image against that clone: after its
`alembic upgrade head`, a `TestClient` GET of `/api/v1/health/ready` must return
HTTP 200 with `ok=true` and `database=ready`. This is an actual 0092 clone DB
read through the rollback image. The
four synthetic PostgreSQL concurrency cases run only against this isolated
clone. The probe registers the real candidate application models, then creates
only its 15 reviewed Identity, support-profile, audit, and Outbox tables in a
random synthetic schema. It rejects a missing table or a foreign key outside
the reviewed set; `red_packets` and financial tables stay out of its DDL. The
read-only table and foreign-key inventory is in `pg-probe-table-scope-readonly.json`.
The probe requires `host(inet_server_addr())=127.0.0.1`, database
`clone`, and head 0092; it uses no production environment file or credentials.
`restore-finalize` removes the clone and records bounded proof.

`migrate-production` is the first production database write: it rechecks the
0091 baseline, backup, clone proof, both Compose roles, exact candidate and
compatible rollback images, final role-aware guard, and sole API ingress. It
writes an attempt marker before `alembic upgrade 0092_admin_session_entry_mode`
with bounded lock and statement timeouts. The nullable expand migration is
**never downgraded**. A failed attempt is write-once and requires an operator
to inspect private evidence and the live schema before any continuation.

`deploy` requires 0092 schema and a matching production migration proof before
the guarded API switch. The Worker is retained. It verifies health, then
preflights all 18 static sources and targets before replacing any file,
publishing `admin.html` last. On a switch or static error, automatic rollback
prechecks both roles and every static target, accepts the managed API whether
healthy or already exited, stops it if still running, transactionally revokes
the active refresh families of `identity_admin_sessions`, restores the static
targets, and switches to the 0092-compatible API image. This revocation logs
administrators out. No production database restore or downgrade occurs. The
brief stopped-API interval affects all Business API traffic until the
compatible image is healthy. Any later image or static drift blocks rollback.

Final verification must include strict TLS public JSON readiness, expected
401s, static byte hashes through the server and workstation jumper, selected
health/restart/log checks, and an explicit note that anonymous probes do not
prove a real administrator session. Do not print private Compose environment,
database rows, or credentials. Publicly report only hashes, image IDs,
aggregate counts, exit codes, and evidence paths.

Local focused check: `python -m unittest -q test_v8_safety test_release`.
The scripts and tests are a review candidate; successful local tests do not
replace isolated clone, final image guard, or production verification evidence.
