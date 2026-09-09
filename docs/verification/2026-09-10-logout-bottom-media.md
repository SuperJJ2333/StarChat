# Logout / Messages long press / local media erase verification

Date: 2026-09-10. Plan: `docs/superpowers/plans/2026-09-10-conversation-state-logout-main.md`.

## Scope and implementation

- `app_home.dart`: retains original logout confirmation; adds default Save / Cancel / explicit bold red Confirm delete. Save calls existing logout without clear. Delete awaits existing `clearLocalChatData`, always executes logout even on clear failure, then presents a truthful surviving-root notice when local deletion was incomplete. Pending UI disables repeated logout and finally resets; both choice dialogs close before resource teardown.
- `messages_tab_icon.dart`: platform mediumImpact feedback and 300 ms scale animation; reduce-motion skips scaling. Active and inactive Messages icons invoke AppHome's public conversations.clearAllUnread API and total refresh independently of the visible page. Pending requests do not stall animation; repeated gestures during one local clear are guarded.
- `media_cache.dart`: public account-scoped clear removes the managed SHA-256 account directory (objects and refs), fences old decrypt results and stale reference/video writes, drains local disk writes, clears media memory, preserves all other account disk namespaces. No network deletion or cryptographic protocol change.
- Conversation-state owner wires preferences and media clearing into the existing lifecycle API before removing the account's persisted binding. Existing account-clear/fresh-login 2080 behavior remains owned by that API.

## Test-first evidence

1. Original logout regression failed with expected logout count 0, actual 1 after the initial dialog. Added second selection; regression passed.
2. Clear failure regression failed with expected `[clear, logout]`, actual `[clear]`. Added fail-closed logout in finally; passed.
3. Surviving error notice regression failed to find `已退出登录，本机数据未完全删除` after Settings teardown. Captured surviving root navigator; passed.
4. Messages-tab test first failed to compile because the new component was absent; implemented platform feedback/animation and public clear callback. Tests pass for hidden Messages page, pending clear, reduced motion, and handled errors.
5. Media erase tests first failed because clearAccount was absent; implemented selected-account deletion. Delayed hot reference regression then failed with PathNotFoundException after stale refs were recreated, instead of expected StateError. Generation checks at asynchronous reference/atomic write boundaries prevent recreation; regression passes and confirms refs absent.

## Verification

- Grouped Flutter tests: **120 passed**, exit 0: logout choice, Messages icon, AppHome lifecycle, login controller, session bootstrap, Matrix client factory, media clear, content-addressed media. Output: `D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-10/conversation-state-main/logout-bottom-media-final.txt`.
- Added final explicit Save and Confirm-delete route assertions after that grouped run; logout suite **8 passed**, exit 0, including both reaching the login page without modal residue.
- Scoped Flutter analyze on six implementation/test files: **No issues found**.
- Parent owns complete repository verify, full Flutter suite, final build and integration gates.

## Specification review, then quality/security review

Specification: two-step logout, default non-destructive action, explicit destructive styling, both successful choices reaching login, cancellation, pending clear, and failure teardown are covered. Bottom icon haptic plus 300 ms animation works while another tab remains selected. All-room unread correctness is covered by the conversation-state owner tests and public API.

Quality/security: existing approved ADR-0007 explicitly permits confirmed local deletion; no key formats, authentication protocol, server history, or other accounts are changed; only the explicitly selected local identity/key state is removed. Local media directory is derived from SHA-256 account identity, not caller-supplied paths. Failure keeps authentication closed and reports incomplete deletion rather than claiming success. No raw exception/identity/secret is shown. Independent branch_audit review re-ran nine logout/icon tests and ten media/conversation tests; reported both reviewed issues resolved with no remaining blocker in the reviewed snapshot.

Erasure scope: database, secure identity/recovery state through existing factory; account preferences through conversation owner; account media objects/refs through clearAccount; memory via logout. This is logical managed-data deletion, not a forensic wipe of flash storage, exported user files, or server ciphertext. Same content in another account has its own namespace and is retained. Save retains chat/crypto state per ADR-0007.
