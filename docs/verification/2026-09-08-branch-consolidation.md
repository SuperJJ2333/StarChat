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

Native diagnostic source revision `4b405bff` is running in GitHub Actions run `34241630843`. Native execution and true-device APNs/VoIP/permissions are not implied by the local tests. The iOS task owns completion of those diagnostics.

## Cleanup verification

Inactive worktree archives include checkout content and verification materials. Dependency/build caches are recorded as exclusions; directories named `build` inside decoded evidence are preserved in supplementary archives. Before removal, the recorded HEAD, archive hash and every archived source file are checked again, including detection of added/deleted files. Branches may be removed only after proving ancestry to final main; active or newly divergent branches are retained.

Final repository-gate results and exact cleanup outcomes are recorded below after execution.
