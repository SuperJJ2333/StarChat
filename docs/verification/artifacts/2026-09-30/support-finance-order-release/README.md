# Controlled support finance release tooling

Status: package freeze and deployment are stopped pending final source merge and reviews. Read-only capture at 2026-09-30 06:37:48 UTC identifies API `902eaefc…`, Worker `90d7fb74…`, and published schema `0093_unbroadcast_payout_void`. Earlier baseline assumptions were stale and are superseded. No payload or production mutation has been executed.

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

The fenced API bridge keeps the exact startup command. Startup expands 0094 before serving; affected financial HTTP writes then return 503 using the stable error envelope. The original Worker only sees neutral expansion defaults until `activate-safe-worker` switches its safety code through the guard. `deploy` subsequently switches the candidate API and atomically replaces each static file. Every single-service switch still checks both image roles. The two API phases and Worker phase have separate image, Compose and schema checkpoints.

After the bridge, `python3 server_release.py rollback` activates the fenced API and safety Worker, restores static bytes and retains schema 0094 plus financial and audit history. The original unfenced API is rejected. A bridge failure before expansion completes requires separate reviewed recovery. Do not downgrade the schema or blindly restore the original API. Preserve attempt records and investigate before retrying.

Required remaining gates: source reconciliation and tooling review; actual immutable image builds, guards, clone and Worker outputs; strict TLS readiness, anonymous rejection, OpenAPI and static hashes from server and workstation; bounded log checks and unchanged other containers. Use `public_verify.py --socks5-hostname 127.0.0.1:<port>` through the approved temporary jumper tunnel on the workstation. Authorized staff and owner UI acceptance remains separate. Release checks do not authorize real payments or production financial writes.
