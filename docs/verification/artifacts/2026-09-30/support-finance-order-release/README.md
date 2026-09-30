# Controlled support finance release tooling

Status: the product manifest and payload were frozen from reviewed c204 sources by the release operator. Private backups were prepared on the server. The first build stopped before creating an image/context because an assumed Alembic startup did not match actual Uvicorn. This tooling revision preserves the payload and private backups. No production service or schema change has occurred at this checkpoint. Baseline is API `902eaefc…`, Worker `90d7fb74…`, schema `0093_unbroadcast_payout_void`.

The exact allowlist contains 20 API Python targets including migration 0094; six reviewed domain modules in both Worker package mirrors, migration 0094 and `tasks/internal_publication.py`, totaling 14 Worker targets; and four existing admin static files. Manual wallet task code stays unchanged. Existing unbroadcast void behavior and schema must be retained. The Worker publication task overlay adds missing financial event contracts and must be SHA-bound by the installed probe. Already published recharge gates must remain exact.

`server_release.py` adapts the audited r3 snapshot, inventory, Compose, guard and cleanup helpers. The copied r3 modules refuse direct execution. The dedicated server directory is `/opt/starchat/releases/support-finance-order-recovery-20260930-v1`. Keep that directory and its private snapshots at 0700/0600. Do not download production database, configuration or private snapshots.

After source reconciliation and review, refresh the read-only snapshot through the jumper and freeze exact Git blob bytes:

```
py -3.12 freeze_package.py --snapshot baseline.snapshot.json --repo <reviewed-worktree> --source-commit <final40hex> --live-deltas-reconciled
```

The flag records the operator's reconciliation assertion; it is not automated proof. Freeze does not rewrite line endings. Every payload file has a SHA in the manifest. Server preflight compares live images, source files, Compose, schema, guards and static bytes again. Any drift stops the release. Build a reviewed archive without tests, logs or `__pycache__`; verify its SHA and payload hashes after extraction. Installed guards are checked, never replaced.

Execute these operations in order from the dedicated server directory after security review:

```
python3 server_release.py preflight
python3 server_release.py prepare
python3 server_release.py build
python3 server_release.py restore
python3 server_release.py probe-clone
python3 server_release.py probe-worker
python3 server_release.py restore-finalize
python3 server_release.py bridge-expand
python3 server_release.py activate-safe-worker
python3 server_release.py deploy
python3 server_release.py verify
python3 public_verify.py
```

`prepare` privately backs up static bytes, actual Compose and container configuration, the database and original images. `build` overlays only allowlisted files, validates complete Python inventories and builds a fenced compatibility API. Rollback retains the candidate's safety Worker. A separate offline archive preserves those compatible images. Candidate and rollback images must pass both roles of the installed refresh guard.

The restored clone has network `none`, no published ports and no host data mounts. Probe containers share only its network namespace and run with a synthetic test configuration, a read-only root, dropped capabilities and no permission to gain privileges. `probe-clone` expands restored 0093 to 0094, verifies existing financial fingerprints, starts both API images and exercises the real ASGI fence against synthetic staged, started and takeover states. `probe-worker` reproduces the original installed Worker's domain failure and verifies the safety image against random owned schemas. It checks six installed domain module hashes, the updated publication task and unchanged manual wallet task hashes without `PYTHONPATH`. Cleanup proves that the clone and its anonymous volume are removed.

The approved actual startup is `uvicorn app.main:create_default_app --factory --host 0.0.0.0 --port 8082 --workers 2`, with a null Entrypoint. The build gate checks that exact array. Every image and guarded Compose retains it. Uvicorn workers never migrate automatically.

`bridge-expand` takes an exclusive nonblocking host lock and first guard-switches only the fenced API while schema remains 0093. It proves the actual container's readiness JSON and anonymous payout adjustment, admin void and recharge mutation responses are 503 with the stable envelope and no-store. The `bridge-fenced.json` checkpoint binds the actual container ID/image, guarded Compose SHA and schema. It rechecks the same ID/image and 0093 immediately before a single `docker exec` targeting that immutable ID: `PGOPTIONS=-c lock_timeout=5000 -c statement_timeout=120000`, GNU timeout 150 seconds with TERM then KILL after 10 seconds, and `python -m alembic upgrade 0094_support_finance_order_recovery`. The Docker client timeout is 180 seconds. GNU timeout availability is checked in the actual container. This keeps writes fenced throughout migration without two Uvicorn workers racing DDL.

Only after exact 0094 and healthy unchanged bridge identities does it write `bridge-result.json`. The original Worker sees neutral expansion defaults until `activate-safe-worker` switches its safety code through the guard. `deploy` then switches candidate API and replaces static files atomically. Each phase checks both image roles and freezes intentional new container identities. The two API switches and Worker switch remain separate checkpoints.

After a completed expansion, `python3 server_release.py rollback` activates the fenced API and safety Worker, restores static bytes and retains schema 0094 plus financial and audit history. The original unfenced API is rejected. A guard, health, fence or migration failure writes `bridge-failure.json`; a partial guard failure may have no returned snapshot, so inspect actual containers first. A failed/uncertain migration retains the fenced bridge, attempt records and private migration log. Confirm the actual head and absence of a migration process before a separately reviewed recovery. No automatic retry, schema downgrade, Worker activation or final API switch is allowed without a successful bridge result. Recovery before expansion needs separate review; the post-expansion rollback command requires 0094.

Tooling-only server replacement is limited to `server_release.py` and this README, with old/new byte hashes and versioned backups recorded by the operator. Do not re-freeze or replace the product manifest, payload, probes, guards or private backups.

Required remaining gates: source reconciliation and tooling review; actual immutable image builds, guards, clone and Worker outputs; strict TLS readiness, anonymous rejection, OpenAPI and static hashes from server and workstation; bounded log checks and unchanged other containers. Use `public_verify.py --socks5-hostname 127.0.0.1:<port>` through the approved temporary jumper tunnel on the workstation. Authorized staff and owner UI acceptance remains separate. Release checks do not authorize real payments or production financial writes.
