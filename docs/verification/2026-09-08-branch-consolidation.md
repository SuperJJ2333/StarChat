# Branch consolidation — 2026-09-08

User authorized: save and organize uncommitted work, integrate valid fixes and iOS diagnostics, archive evidence, then clean redundant branches/worktrees.

## Preservation and scope

Initial main: `854ba4c0757d14d70718c422d5809e76aec3ffc1`. All 13 initial local topic branches were ancestors of main. The iOS diagnostic remote subsequently advanced to `4b405bff6d9926b6774a99ae267fc62449a4f4f2` during another active user task.

Local-only archive: `docs/verification/artifacts/2026-09-08/branch-consolidation/`. It is excluded via Git's local `info/exclude`; raw snapshots must not be pushed. `pre-cleanup.bundle` was verified successfully. Per-worktree manifests record original HEAD, binary staged/unstaged patches, exact source snapshots, and SHA-256 hashes. `RESTORE.md` documents recovery into a separate checkout.

The root snapshot contains 411 source/documentation files: 214 backend/wallet/auth, 41 mobile, 41 admin web, 97 documentation, and 18 contracts/infrastructure. No selected file changed while its bytes were being copied. This is a point-in-time backup; active source directories remain intact for subsequent changes.

Wallet/ledger/authentication WIP is preserved separately, not approved for integration by this cleanup. Current AGENTS prohibits CAIBI–USDT conversion, while pending ADRs describe conversion and changes to TOTP/operation-password policy. These protected changes require reconciliation with the current instructions and the required approval/review evidence. Shared application/config/OpenAPI files must not be copied wholesale over main.

Root `codex/wallet-safety-mi6` and the active `codex/ios-0353-background` worktree are retained. Their active user tasks were observed before cleanup. Remote `codex/ios-compatibility` is also retained for ongoing native tests.

## Reviewed integration

- Preserve canonical private-room identity on sync timeout rather than create/display a replacement room.
- Identify RIFF/WAVE bytes with the correct audio MIME type.
- Rename recognized MP4/QuickTime cache files to typed paths without a second retained payload; retain validation, quota and cleanup behavior.
- Integrate synthetic native audio/video and encrypted-persistence diagnostics from pinned revision `4b405bff`.
- Enable diagnostic CI on relevant main/PR changes and manual dispatch while retaining its existing branch trigger and read-only permissions.

Independent specification review approved these boundaries, followed by independent quality/security approval. A trailing blank line identified by quality review was removed. Diagnostic fixtures add approximately 749 KB to application assets.

## Fresh verification

- Main plus the new direct-room regression test: two intended failures, two safety recovery cases passed (`direct-red.log`).
- Integrated focused tests: 32 passed (`focused-green.log`).
- Entire Flutter test suite: 1,462 passed (`flutter-all.log`).
- Flutter analyzer: no issues (`flutter-analyze.log`).
- `git diff --cached --check`: passed after whitespace cleanup.
- Repository verification initially stopped because the new checkout lacked `.env`. A local copy of `.env.example` supplied synthetic render configuration; no production configuration was copied.

`scripts/verify.ps1` completed successfully after supplying example configuration: infra 17 passed, Getui 28 passed, Matrix Bot 9 passed, Business API/Worker 349 passed and 19 skipped, mobile boundary 66 passed. Migration heads/offline SQL, OpenAPI contract, UI contract and Docker Compose render all passed. Skips include tests requiring isolated PostgreSQL (`RUN_POSTGRES_TESTS=1`); this run does not claim live PostgreSQL coverage. Existing FastAPI/httpx and Pydantic deprecation warnings remain outside the changed source.

Native revision `4b405bff`, Actions run `34241630843`, failed at the Flutter loader despite 15 successful iOS 26 native assertions. The precise failure was custom-stream subscription `integration_test.VmServiceProxyGoldenFileComparator`, error `-32602`. Inspection of the exact Flutter 3.44.9 SDK confirmed that `--no-dds` bypasses the service that registers custom streams. Independent quality review approved removing that flag from both phases, retaining `--no-uninstall` and all assertions. Candidate `fc047fff` reruns native verification in Actions run `34244530760`. True-device APNs/VoIP/permissions are not implied by simulator results.

## Cleanup verification

Inactive worktree archives include checkout content and verification materials. Dependency/build caches are recorded as exclusions; directories named `build` inside decoded evidence are preserved in supplementary archives. Before removal, the recorded HEAD, archive hash and every archived source file are checked again, including detection of added/deleted files. Branches may be removed only after proving ancestry to final main; active or newly divergent branches are retained.

All 10 inactive worktrees were removed after verification, together with their branches; the already-merged local `codex/official-chat-update` ref was also removed. Total: 11 old local branches, 10 old worktrees. Obsolete R:/S: mappings to the deleted source checkouts were removed; active T:/U: mappings were retained.

Seven old remote refs were atomically deleted using explicit expected-OID leases: `codex/chat-room-flow-fixes`, `codex/image-layout-mi6`, `codex/ios-0353-testflight`, `codex/ios-build-preflight-20260907`, `codex/ios-secrets-check-20260907-151818`, `codex/ios-startup-repair-20260907`, `codex/official-chat-update`. Intermittent TLS failures required retries; no certificate validation was disabled. `remote-deletions.json` records the exact removed OIDs.

Archive coverage: 457,153 checkout/evidence files across 10 inactive directories. ZIPs total 7,834,857,845 bytes, including source and supplementary evidence archives. D: free space increased from 49,269,231,616 to 68,771,491,840 bytes at the recorded checkpoints. `archive-index.json` lists archive hashes; `cleanup-results.json` records 10 successful removals. Both pre- and post-cleanup Git bundles are retained locally.

Corrected candidate `fc047fff7487f650dafe096d155330e97246ca0a` passed native Actions run `34244530760`: both iPhone 15 / iOS 18 and iOS 26 jobs completed successfully, including native media and retained encrypted history in a new app process. Run URL: https://github.com/SuperJJ2333/StarChat/actions/runs/34244530760.

The active iOS task independently published equivalent DDS corrections as `f0e594525144a5f4f46379a7c86b13922ad00612`. Its history is incorporated; the workflow conflict was resolved by preserving main/PR/manual triggers and removing `--no-dds` and unnecessary `--verbose`. The temporary consolidation-branch trigger is removed after its successful verification. Application source, fixtures and tests are byte-identical to the verified candidate.

Final local/remote refs, promotion commit and remaining worktrees are captured in the local `final-state.json` after promotion. Retained work includes the active root wallet/auth WIP and active iOS checkout. No production deployment, APK/IPA publication, financial-policy activation or real-device push acceptance is performed by this task.

Promotion completed: local and remote main were verified at integration commit 73fedd8212aa5a88124c2df994093e3a84fc2ec2. The temporary codex/consolidate-20260908 ref was deleted locally and remotely after ancestry/expected-OID checks. Remaining local branches are main, codex/wallet-safety-mi6 and codex/ios-0353-background; remaining remote branches are main, codex/wallet-safety-mi6 and codex/ios-compatibility. The following documentation-only completion commit changes no tested application code.
