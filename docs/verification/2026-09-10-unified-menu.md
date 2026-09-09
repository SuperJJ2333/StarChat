# Unified menu verification — 2026-09-10

Scope: shared `WeChatAnchoredActionMenu`, compatible `MessageBubbleMenu` wrapper, conversation menu and three Tab more menus, feed/detail/personal comment long-press and confirmed deletion synchronization. No room_page, Matrix crypto, signing, Git staging or commit edits in this subtask.

## Behavior and review

- Shared rendering: 272dp, 8dp corner radius, #E64C4C4C, white 20dp icons / 11sp labels, four columns, minimum 44dp target. Original 120ms opacity and .96→1 scale are applied around the menu itself; reduced motion disables animation. All new presenters reuse MessageMenuPlacement and edge/keyboard insets.
- Conversation actions ordered pin/unpin, unread, hide, delete. Existing public mutation remains authoritative; delete confirmation explicitly says local-device history and no group exit. UI catches mutation errors. Parent/video agent owns replacement of the preexisting leave/forget mutation.
- Three Tab menus preserve existing actions. Message wrapper preserves public parameters/action keys and does not require room_page changes.
- Long press a comment copies; own comment or own-post comment additionally deletes. Other-person comment tap still replies; existing own-comment tap deletion remains compatible. Delete remains server-authorized. Single in-flight deletion per API/account/post/comment; account/privacy checks prevent stale UI changes.
- Confirmed deletion broadcasts to mounted feed/detail/personal projections, removes only matching comments, preserves concurrent likes, invalidates refresh revisions, and removes the comment from the account-scoped persisted feed cache. API failure keeps the comment and exposes retry error. Completion can persist after detail route unmount (existing regression preserved).

## Evidence

- `artifacts/2026-09-10/video-menu-redmi/menu-suite.log`: 108 focused tests pass (all moments tests, shared menu/wrapper tests, discovery tests).
- `menu-targeted.log`: 11 menu/detail cases pass during regression repair.
- `menu-regression-red.log`: all four long-press integration cases fail for missing Copy when the added long-press binding is removed; restored binding yields green. Initial `menu-red.log` used an incomplete friend fixture and failed before finding the comment. It is not valid test-first evidence; corrected regression red was run after implementation. This limitation is explicit rather than claiming strict initial red/green sequencing.
- `menu-analyze.log`: final Flutter analyzer output; Matrix implementation lint, if present, belongs to the coordinating video agent.
- Full Flutter, repository verification, backend and device verification are parent-owned.

## Review follow-up: server-confirmed deletion versus cache errors

- Added failing interaction regression before fix: API returns 204, `onConfirmed` throws a cache error, and the confirmed-deletion broadcast was missing (`menu-cache-red.log`).
- Fix publishes/removes the confirmed deletion before persistence callbacks, continues the shared cache update even if the page callback fails, and uses “评论已删除，请刷新页面” for post-success persistence failures. It never restores the confirmed-deleted comment or falsely reports an API deletion failure.
- Focused regression evidence: `menu-cache-green.log` (comment integration and detail tests).
- Specification review first: four-column shared appearance, first-position conversation pin action, page action preservation, own-post comment ownership, tap/long-press separation, account/privacy isolation, and navigation completion retained.
- Quality/security review second: no leave/forget or crypto edits in owned scope; API authorization remains server-side; in-flight guard released in finally; confirmed server mutations survive callback failure; page listeners removed on disposal; refresh generations prevent stale overwrite; no sensitive logs added. No additional finding in owned scope.
