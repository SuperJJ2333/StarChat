# Main consolidation, wallet/search fixes and mobile release

## Recovery

- Authorization: user 2026-09-30 asks to inspect/merge every Git branch to main and retain one branch, fix three UI issues, publish Android update/popup, deliver iOS IPA for user enterprise signing and subsequent return/distribution. User pre-approves needed plans/ADRs and autonomous decisions.
- Plan: ../../superpowers/plans/2026-09-30-main-wallet-search-release.md.
- Started 2026-09-30 19:02 +08 (first precise task timing unavailable; do not infer exact time).
- Worktree: C:/Users/Administrator/.codex/worktrees/main-wallet-search-20260930/StarChat, native detached checkout; root main b9eca8a4, origin/main971fb50d, initial candidate526e81e2.
- Owns manual_wallet_page.dart, global_search_page.dart and their tests, this task/plan/evidence, integration resolutions/version/release metadata.
- Snapshot: root docs/verification/artifacts/2026-09-30/main-wallet-search/snapshot/inventory.json; all existing worktree tracked source patches and non-sensitive untracked source/documentation preserved. Generated artifacts/runtime data/credentials excluded.

## Acceptance

|ID|Expected|State|
|---|---|---|
|G1|Review branches, retain all useful changes in main, only main branch remains|Integrating|
|W1|No repeated green application link below wallet cards; top notice remains|Root cause found|
|W2|Recharge form shows only latest order, history preserved elsewhere|Root cause found|
|S1|Search room/contact labels show current remark/nickname, no raw room IDs|Root cause found|
|S2|Multi-hit records and opened chat preserve correct remark/avatar and event routing|Root cause found|
|A1|Rebuilt stable-signed Android released with update popup|Pending|
|I1|Updated iOS IPA delivered for user enterprise signing|Pending candidate; distribution depends on signed return|

## Decisions and evidence

- 47f6d792 merges Android2193 branch with latest finance recovery: current-state keeps both task summaries; download keeps latest Android2193; frontend attributes combine byte-preservation paths; diagnostics tests retain latest full server acceptance coverage.
- Installer branch is based on pre-2193 mobile source (151 differing mobile files, most older). Straight merge produced extensive old-source conflicts; aborted before modifications. Review unique increments before selective integration and history merge.
- Root cause W1: manual-recharge-history-open still renders below wallet summary despite top notice implementation. W2: manualRechargeFields iterates all rechargeHistory. S1/S2: conversation title uses indexed roomName; multi-hit page does not receive ProfileRepository or AvatarMediaCapability and sender rows use only stored name.

## Stage ledger

|Stage|Start +08|End|Outcome|
|---|---|---|---|
|Inventory/snapshot|19:02 approximate|19:09 approximate|19 branches; 45 worktrees scanned; snapshot complete|
|Integration and root cause|19:09 approximate|Active|Candidate47f6d792; fresh read-only reviewer dispatched by executing-plans final-review requirement|

## Source integration and gates (2026-09-30 20:00 +08)

- Wallet/search changes committed at 380758d0. Four original regressions RED to GREEN; reviewer requested two legal group-prefix regressions, RED to GREEN. Focused final Flutter: 40 passed. Full Flutter: 5136 passed, 9 platform/conditional skips, exit 0; incremental reviewer cases cover the subsequent small title fix. Analyze exit 0, no issues. Version 0.4.25+2194; live platforms 2193/2189 and recent CI checked for occupancy.
- Fresh specification review preceded quality/security review. P2 group-prefix and expired-login preview findings fixed with regression coverage; no financial command is sent by the latter read. Existing financial ADRs and append-only reversal workflow retained; this task changes no new financial formula, custody/auth contract or E2EE boundary.
- Latest released mobile source wins superseded copies. Installer unique commits 1740b378/adadcdf3 cherry-picked (8fdc9182/27c112e7); regional TCP/HTTPS hardening retained; iOS native-test workflow retained. Wallet alert-only observer and UNKNOWN never-broadcast void UI/API preserve grant, proof, preview, idempotency and modal credential clearing; worker/infra focused 53 passed.
- Root dirty additions preserved: startup diagnostics receiver/admission/tracing, account credential demos and SMS worker wiring, S3 provider/backfill/lifecycle and regional installer/edge tooling, their tests and historical plans/task records. Root tracked frontend increments applied as three-way changes against their original base, preserving newer group/search/interaction demos. Token layer combines origin/main's current mobile tokens and latest admin login/wallet palette. UI contract: 33 components, 518 screens, PASS.
- Frontend final 519 passed, 0 failed; mobile/infra final 1217 passed, 1 conditional skip, 0 failed. Expanded API/worker suite running independently. verify.ps1 repository/deployment/template gates passed but stops at missing local .env; no production credentials copied to this isolated worktree. The environment limitation remains recorded, not reported as a passing full gate.
- All original worktree source patches/untracked files remain in the snapshot and original worktrees. After unique integration, superseded branch heads will be joined using history-only merges; no older source snapshot may overwrite the tested final tree. Final ancestry is checked before branch deletion.

Next: freeze source, build rebuilt/stable-signed ARM64 2194, push main for iOS CI, publish Android metadata/popup after package checks. iOS candidate goes to the user for enterprise signing; distribution waits for the signed return. No new production writes yet.
