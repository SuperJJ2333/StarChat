# Main integration, wallet and search delivery plan

> For agentic workers: execute inline with executing-plans; use a fresh final reviewer. User pre-approved plans/ADRs and autonomous release on 2026-09-30.

**Goal:** Preserve all branch changes in main, remove duplicate wallet notifications, show only the latest recharge order, and display current contact remarks/avatars in search, then publish Android and deliver an iOS candidate for user enterprise signing.

**Architecture:** Financial data remains business-API authoritative. Search is device-side and resolves indexed identifiers through the current account's room/contact projection at paint time. Superseded branch history is merged only after identifying its replacement; unique changes are retained.

**Tech Stack:** Flutter/Dart, Git, PowerShell 7, existing Android rebuilt signing pipeline, GitHub Actions iOS.

**Spec:** User's five requirements in this session; existing product modernization specification and mobile-delivery workflow.

## Constraints and review focus

- Keep account scoping, E2EE, payment permissions, stable idempotency keys and existing financial ADRs.
- Top notification bars remain; cancelled/older recharge records stay in transaction history, not the recharge form.
- Display the latest server order by creation time, including unsorted histories and stale local operations; never alter financial orders to change visibility.
- Prefer current contact remark/avatar over old indexed names. Retain exact event/source room navigation across merged conversations.
- Preserve dirty historical worktrees through snapshots and detached references; branch cleanup must not discard uncommitted changes.
- Android signing must remain 75b31c66…ba61fff. iOS candidate waits for the user's enterprise re-signing before distribution.

## Tasks

1. [x] Snapshot branch/worktree inputs, audit unique commits, integrate latest published sources and unique changes, record every supersession and conflict decision. Verify every branch head is an ancestor of the final candidate.
2. [x] Add widget regressions: overview has no redundant green application links; recharge page contains latest order only, with cancelled/current/draft cases. Watch RED, remove duplicate button and limit rendered history, watch GREEN.
3. [x] Add widget regressions with raw Matrix room ID and stale sender name, current remark/avatar, multiple hits and exact event navigation. Watch RED; pass current room/contact/avatar projections into result rows and records page; watch GREEN.
4. [x] Run focused wallet/search tests, full Flutter suite, analyze, impacted frontend/mobile/backend gates and verify.ps1 after environment preflight. Record real failures and evidence scope. Perform specification review before security/quality review.
5. [x] Freeze next free version/build after reading live settings and CI. Build Android ARM64, rebuild with Apktool 2.12.1, align and stable-sign, verify manifest/DEX/assets. Build matching iOS via established signed compatibility Action and deliver IPA labelled pending user enterprise signing.
6. [x] Publish Android immutable package, download metadata and update popup with audited settings and rollback. Check public TLS HEAD/metadata/platform isolation. Merge/push main and remove all merged local/remote non-main branches after preserving dirty worktrees. Update task/current-state with remaining iOS handoff.

## Execution status

Source integration, mobile fixes, required scoped gates, Android stable rebuild and audited publication completed. iOS CI candidate succeeds; local IPA identity and immutable handoff verified. iOS enterprise signing/distribution intentionally depends on the user returning the signed candidate. The full verify environment limitation and initial-backend red→green accounting are recorded in the task/verification.
