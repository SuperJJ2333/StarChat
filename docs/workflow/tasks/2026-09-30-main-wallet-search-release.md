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

Next: complete unique branch audit and test-first wallet/search fixes, then source gates and platform builds. No new production writes yet.
