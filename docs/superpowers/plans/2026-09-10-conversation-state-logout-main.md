# Conversation state, logout and main consolidation

> Execute bounded tasks with test-first regressions and specification review followed by quality/security review.

Authorization: user explicitly requested all changes, conflict resolution, push main and deletion of unnecessary merged branches. Preserve active dirty worktrees. Base includes debug 2080 account-login repair (10316dda / 5fbb2953), previous 2077 and 2079 work.

Architecture: maintain immediate account-scoped conversation preferences, reconcile server acknowledgement without stale sync rollback, persist pin timestamp and manual unread. Latest pin sorts first. Use one vertical top-menu presenter, retain grid bubble menus. Logout uses existing authentication and local-clear public APIs after original confirmation and explicit save/delete choice; save is default. Long press uses platform haptic plus 300ms animation and shared unread clearing independent of active tab.

- [ ] Pin/unread: tests for immediate update within 300ms with pending network, persisted preference, reversed pin ordering, direct/group background, cancel pin, unread until room open. Own conversation preferences, Matrix capability, matrix home and related tests.
- [ ] Bottom Messages long press: haptic/300ms animation and all-room manual/remote unread clear while another tab is visible. Coordinate app_home ownership with logout task, public Matrix read-state interface with pin task.
- [ ] Logout: retain original confirm then non-destructive-default save/delete popup; bold red confirm-delete; both choices invoke existing logout, errors do not leave busy UI stuck. Own app_home/auth UI plus focused tests; review existing local erase scope and document limitations, no crypto protocol change.
- [ ] Top menu: common vertical four items in order 发起群聊 / 添加朋友 / 扫一扫 / 外观, equal rows/dividers/anchors on Messages, Contacts, Discovery. Parent owns component, contacts/discovery, docs/HTML/token registry; matrix home integration coordinated with pin owner.
- [ ] Branch audit: compare every local/remote branch to main, preserve reachable history, merge unmerged committed work with conflict review; retain checked-out active/dirty branches. No force push. Delete only verified merged and unneeded refs.
- [ ] Validate merged 2080 client regression, all focused tests, complete Flutter tests/analyze, frontend/UI contracts, repository verify, compile source arm64 debug. If installing as continued Redmi delivery, increment from 2080 to 2081 and follow APK rebuild/fixed signer runbook.
- [ ] Record results in docs/verification; artifact logs only docs/verification/artifacts/2026-09-10/conversation-state-main/. Commit, push main, verify remote hash, clean merged refs. No production deployment.

Approved behavior choices are taken directly from the user's request. Save/delete is an explicit choice with Save focused/default; cancelling the dialog cancels logout rather than deleting. The existing initial logout confirmation remains because the user explicitly requested an additional confirmation. Remote Figma unavailable: update local contract ledger and mark remote sync pending.
