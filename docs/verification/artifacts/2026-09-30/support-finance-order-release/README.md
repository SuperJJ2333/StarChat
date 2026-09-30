# Controlled support finance release tooling

Status: the product manifest and payload were frozen from reviewed c204 sources by the release operator. Private backups were prepared on the server. The first build stopped before creating an image/context because an assumed Alembic startup did not match actual Uvicorn. This tooling revision preserves the payload and private backups. The second build created three immutable images and passed Python inventory checks, then stopped at exact merged Compose validation because both original role files contained both services. No images.json or production service/schema switch was created. Existing images, contexts and private evidence are retained. Baseline is API `902eaefc…`, Worker `90d7fb74…`, schema `0093_unbroadcast_payout_void`.

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

Derived role Compose now contains only its own service and all original top-level sections. Own-service roundtrip/frozen comparison is exact against that role's frozen slice. The existing merged comparison remains exact against both candidate images and the unchanged full baseline. Bridge and rollback use the same role slicing.

For the already built images, replace the `build` step with the reviewed immutable reuse command:

```
python3 server_release.py resume-build --candidate-api sha256:27028fd50a570aae2ad8022119d4df04318be101692610b499ef95c00aab7b41 --candidate-worker sha256:7a0046de5404a0711532ec156433a04ef2d88b685fab8b580e6d578830d72e9f --rollback-api sha256:913e6b79acb564d441a81bec15f8b4741161d226339518a75c3cc158715b33a6
```

Resume requires the unchanged prepared baseline and absence of image-finalization or production-attempt records. It binds deterministic build tags to those explicit IDs, rechecks complete Python inventories and every image runtime Config field against the frozen base, checks payload hashes, and reconstructs the fenced factory intent from the immutable base. It never rebuilds or deletes contexts. Original derived Compose files are moved into a unique private 0700 attempt directory with their SHA evidence. Fresh role slices must pass exact merged checks, then both role guards and compatible image archive complete. Attempt/result/failure records remain private; an interrupted later finalization needs separately reviewed recovery.

`prepare` privately backs up static bytes, actual Compose and container configuration, the database and original images. `build` overlays only allowlisted files, validates complete Python inventories and builds a fenced compatibility API. Rollback retains the candidate's safety Worker. A separate offline archive preserves those compatible images. Candidate and rollback images must pass both roles of the installed refresh guard.

The restored clone has network `none`, no published ports and no host data mounts. Probe containers share only its network namespace and run with a synthetic test configuration, a read-only root, dropped capabilities and no permission to gain privileges. `probe-clone` expands restored 0093 to 0094, verifies existing financial fingerprints, starts both API images and exercises the real ASGI fence against synthetic staged, started and takeover states. `probe-worker` reproduces the original installed Worker's domain failure and verifies the safety image against random owned schemas. It checks six installed domain module hashes, the updated publication task and unchanged manual wallet task hashes without `PYTHONPATH`. Cleanup proves that the clone and its anonymous volume are removed.

The approved actual startup is `uvicorn app.main:create_default_app --factory --host 0.0.0.0 --port 8082 --workers 2`, with a null Entrypoint. The build gate checks that exact array. Every image and guarded Compose retains it. Uvicorn workers never migrate automatically.

`bridge-expand` takes an exclusive nonblocking host lock and first guard-switches only the fenced API while schema remains 0093. It proves the actual container's readiness JSON and anonymous payout adjustment, admin void and recharge mutation responses are 503 with the stable envelope and no-store. The `bridge-fenced.json` checkpoint binds the actual container ID/image, guarded Compose SHA and schema. It rechecks the same ID/image and 0093 immediately before a single `docker exec` targeting that immutable ID: `PGOPTIONS=-c lock_timeout=5000 -c statement_timeout=120000`, GNU timeout 150 seconds with TERM then KILL after 10 seconds, and `python -m alembic upgrade 0094_support_finance_order_recovery`. The Docker client timeout is 180 seconds. GNU timeout availability is checked in the actual container. This keeps writes fenced throughout migration without two Uvicorn workers racing DDL.

Only after exact 0094 and healthy unchanged bridge identities does it write `bridge-result.json`. The original Worker sees neutral expansion defaults until `activate-safe-worker` switches its safety code through the guard. `deploy` then switches candidate API and replaces static files atomically. Each phase checks both image roles and freezes intentional new container identities. The two API switches and Worker switch remain separate checkpoints.

After a completed expansion, `python3 server_release.py rollback` activates the fenced API and safety Worker, restores static bytes and retains schema 0094 plus financial and audit history. The original unfenced API is rejected. A guard, health, fence or migration failure writes `bridge-failure.json`; a partial guard failure may have no returned snapshot, so inspect actual containers first. A failed/uncertain migration retains the fenced bridge, attempt records and private migration log. Confirm the actual head and absence of a migration process before a separately reviewed recovery. No automatic retry, schema downgrade, Worker activation or final API switch is allowed without a successful bridge result. Recovery before expansion needs separate review; the post-expansion rollback command requires 0094.

Tooling-only server replacement is limited to `server_release.py` and this README, with old/new byte hashes and versioned backups recorded by the operator. Do not re-freeze or replace the product manifest, payload, probes, guards or private backups.

Required remaining gates: source reconciliation and tooling review; actual immutable image builds, guards, clone and Worker outputs; strict TLS readiness, anonymous rejection, OpenAPI and static hashes from server and workstation; bounded log checks and unchanged other containers. Use `public_verify.py --socks5-hostname 127.0.0.1:<port>` through the approved temporary jumper tunnel on the workstation. Authorized staff and owner UI acceptance remains separate. Release checks do not authorize real payments or production financial writes.


## Failed fixture clone recovery

The first actual clone probe reached 0094 but failed its synthetic fixture on `ck_manual_payout_claim`; it has no compatibility proof or saved before-fingerprint. It must never be counted as a successful migration rehearsal. Fixed fixture commit c315c4f5 passed real PostgreSQL 0094 and actual ASGI checks locally. Each order has its own quote, UNKNOWN original payer/claim time, valid staged/evidence/recharge leases and synthetic users with owned FK references.

After independent review, version-back up and replace only the probe, add `clone_recovery.py`, and preserve the operator's raw old probe copy inside this release directory. The helper copies current private failure logs before any subprocess can overwrite stderr. Run:

```
python3 clone_recovery.py amend-probe --old-manifest-sha <actual-old-manifest-SHA> --old-baseline-sha <actual-private-baseline-SHA> --old-probe-sha 2bfc24cbf3355a6f6113d8ab9682e58f655e869542c0d371cb8305b1aaa20877 --new-probe-sha 5c9ab84727b0a44acda65752a3afb081e8809104a07417039d85485f8cbf9b84 --old-probe-file <versioned-old-probe-file-inside-this-release>
python3 clone_recovery.py recover-clone --volume b4b77e146cd41cc80502d0e847e89c66c5b3aa82fb388300bb5440d1a2159308
python3 server_release.py probe-clone
python3 server_release.py probe-worker
python3 server_release.py restore-finalize
```

Amendment archives exact old/new manifest, baseline and probe bytes plus hashes. The manifest changes only `wallet_probe_sha256`; private baseline changes only its `manifest_sha256` binding. Payload, source identity, image IDs and other proofs remain exact. A partially completed two-file binding update blocks ordinary gates; preserve its intent/byte archives and obtain reviewed recovery before proceeding.

Recovery requires no completed clone proof or production attempt. It verifies recorded generated clone name/ID, pinned Postgres image, network none, no host binds/published ports, exactly the explicitly named anonymous local data volume and no other container using it. It removes only the immutable recorded container ID with its anonymous volume and proves both absent. Original restore record and failed logs are retained under a unique private attempt. A fresh 0093 clone must restore from the same dump SHA; then 0093→0094, financial fingerprints and fixed ASGI probe run afresh. Never download private evidence or run these helpers against production database/containers.


## Obsolete v1 baseline cleanup only

A separately published Worker mail fix changed live Worker90d→00c. The v1 amendment stopped before any binding change or clone cleanup. V1 is now abandoned due to live baseline drift; original manifest42ad9a8e… and private baselined74a565c… remain intact. Production services were not changed by v1.

After independent review, update only clone_recovery.py and run from the v1 server directory:

```
python3 clone_recovery.py cleanup-only --volume b4b77e146cd41cc80502d0e847e89c66c5b3aa82fb388300bb5440d1a2159308
```

This mode validates the original private manifest/backup/restore/image-record binding and all owned clone/volume restrictions. It intentionally does not apply the obsolete live-production identity gate to nonproduction cleanup. It archives failure logs and restore record, removes only recorded immutable cloneID9bffedb2… and its anonymous volume, proves both absent, and stops. It never amends bindings, restores another clone, switches production, or edits payload/static/database state. V1 evidence remains server-private. A separate v2 directory must bind the new00c Worker and current Compose/runtime with fresh snapshot, manifest, backups and builds.
