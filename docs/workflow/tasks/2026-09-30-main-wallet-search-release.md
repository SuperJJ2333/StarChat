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
|G1|Review branches, retain all useful changes in main, only main branch remains|Complete; local/remote main only|
|W1|No repeated green application link below wallet cards; top notice remains|Implemented, tested and released in Android2194|
|W2|Recharge form shows only latest order, history preserved elsewhere|Implemented, tested and released in Android2194|
|S1|Search room/contact labels show current remark/nickname, no raw room IDs|Implemented, tested and released in Android2194|
|S2|Multi-hit records and opened chat preserve correct remark/avatar and event routing|Implemented, tested and released in Android2194|
|A1|Rebuilt stable-signed Android released with update popup|Android2194 published; audited popup read back|
|I1|Updated iOS IPA delivered for user enterprise signing|Verified IPA2194 delivered for user enterprise signing; distribution awaits signed return|

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

## Final delivery gates and publication (2026-09-30 +08)

- Mobile frozen source05c05793, version0.4.25+2194. Android final APK SHA97d26386…aa8d6, 81,767,454bytes, stable signer75b31c66…ba61fff. Build finished20:17:53+08. Both HK immutable object and S3/CDN verified; only new exact CDN object authorized, old3 retained.
- Android standard metadata backup20:41 UTC12:41, network backup20:44, popup audit trace android-2194-popup-20260930T124500Z; server and workstation TLS HEAD/registry/page/hash readback PASS. iOS2189 and both minimum versions preserved. DownloadJS Windows CRLF vs server LF normalized-content-identical; record uses public-byte hashes.
- Backend initial full3979:3822passed/40failed/117conditional skips,2391.39s.40failures individually triaged;2fixture issues isolated;9reserve-proof failures reflect a real missing invalidation restored independently of global pause;29legacyauto-pause assertions aligned to approved alert-only ADR with administrator pause explicitly seeded. New3healthy→failedproof tests prove require_coverage拒绝新义务、无三项全局冻结。
- Incremental244passed86.07s; complete wallet+worker1445passed31conditional skips157.00s; startup/timeline142passed18.51s. Frontend519passed10.22s after live2194metadata copied back to source. No remaining scoped failures. Other full gates reused on unchanged mobile/infra inputs, not claimed rerun; verify.ps1 still blocked by local.env. Existing Starlette/httpx deprecation documented.
- Fresh spec review then quality/security review: startup header/canonical-slash P2 and reserve proof P1 fixed, final incremental review no newP0–P2. Protected financial formula/schema/auth and E2EE unchanged by these corrections.
- Every original branch head reachable from main; concurrent chat's recreateded0dbbc branch also already reachable. Final cleanup detached dirty worktree with identicalstatusbytes, deleted nonmain refs. All original WIP remains snapshotted plus root stash16018d5c; never blindly apply stale mobile WIP.
- iOS CI36712413903: simulator job10987840718520:07:53–20:41:07+08 success; build job10989013325820:41 onward success, IPA artifact11097116937created20:53:20+08. CI artifact ZIP SHA271394ad…5d1d17; local download then identity verification required before handoff.
- Final source corrections/publication metadata and documents are copied to root main with HEAD-baseline guards, explicitly staged only; historical artifact deletions remain user's original WIP. No backend production deployment or financial action by this task. Other authorized administrator task independently published API40ad213c, worker3efd5924 preserved.

Next executable step: finish verified CI IPA download and identity manifest, commit/push final main and documentation, deliver IPA for user enterprise signing. Signed return alone blocks iOS distribution, not Android completion.

## Verified iOS handoff

IPA `D:\pythonProject\outsource\StarChat\docs\verification\artifacts\2026-09-30\main-wallet-search\ios-release\ChatFlow-0.4.25-build2194-ios-candidate.ipa`, 61363376bytes, SHA256`a2f7db096df422c87ab472869909a073c38c8144729b2d1d049e7f7cca3ab6d1`. CI artifact ZIP SHA and local CRC/Info.plist/signed-entitlement checks PASS; strict deep codesign and native/simulator/SQLCipher gates passed on CI. Bundlecom.liuhetong.liuhetongMobile, productionAPNs, build2194. Only pending input is user enterprise-signed IPA, then payload comparison and final enterprise identity/device validation before distribution. Next executable step: receive signed return and validate against this immutable candidate; Android2194 is already published.
