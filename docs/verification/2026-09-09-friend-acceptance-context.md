# Friend acceptance context verification — 2026-09-09

Approved user choice: 通过时显示好友申请说明（推荐）. Shared Flutter path applies to Android and iOS source; no native device/build claim.

## Behavior

Acceptance emits the existing encrypted `com.changliao.friend_accepted` system notice, with neutral relationship wording and labeled original request text. Event metadata carries request_id and requester_matrix_user_id. The accepting Matrix account remains the event sender; there is no impersonated requester chat bubble. Transaction ID is stable per request (`friend-accepted-request-<id>`), distinct on re-add. Old three-argument SDK callers retain the previous room/account-scoped transaction fallback.

Outgoing acceptance polling now refreshes contact metadata only. The retired onOutgoingAccepted hook is intentionally inert, including persisted pending requests and restart. The ordinary sendFriendRequestGreeting SDK method was removed.

Coordinator propagates chat initialization failures after preserving the accepted contact. The UI explicitly says friendship is saved and allows retrying initialization with the same request, without another acceptance API call. Choosing Later or terminating the app does not queue an automatic delayed chat event. Accepted request review provides an explicit 打开聊天 recovery action after restart. It rechecks GET /friends and exact business/Matrix identity before initializing with the original request; a historical acceptance cannot resurrect a removed friendship. The same request transaction ID prevents context duplication. Previously delivered messages are not rewritten. Already queued events from an older app and obsolete clients are outside this change.

Root owns AppHome wiring that awaits context before opening composer, as well as pair coordination integration.

## Test-first evidence

Before implementation, `flutter test --no-pub test/features/friendship/friend_request_watch_test.dart test/features/friendship/friend_acceptance_coordinator_test.dart --reporter expanded` failed with expected sends 0 / actual 2, and expected surfaced StateError / actual swallowed null. Neutral body test failed with expected 你们已成为好友... / actual 你已添加了 Bob....

Widget retry regression additionally exposed existing `_reload` setState closure returning a Future; changing it to a block closure resolved that assertion.

Final focused command:

`flutter test --no-pub test/features/friendship test/features/contacts/friend_acceptance_retry_test.dart test/features/contacts/friend_request_review_page_test.dart test/features/matrix/direct_chat_existing_recovery_test.dart --reporter expanded`

Result: 16 tests passed. Includes acceptance initialization await, immutable request context, preserved private contact preferences, surfaced failure, metadata refresh retry/restart, no legacy greeting replay, stable request transaction identity, accurate neutral system content, UI retry with exactly one acceptance API call, and SDK recovery returning null without creating when no room exists.

Targeted analyze on the six modified production files and relevant tests: No issues found. All owned Dart files formatted.

Additional SDK helpers for root pair gateway: findExistingDirectChat delegates only existing-room lookup/join; createDirectChatOnce calls createEncryptedDirectRoom(peer) once without avoidRoomId and waits for that room. No DirectChatService repair/fallback in this creation helper. Root recorded failing pair recovery/invalid-existing tests before those integrations.

Manual recovery test-first evidence: two missing-action widget failures before adding 打开聊天, then both accepted-current-friend and accepted-removed-friend cases passed; zero acceptance API writes and preserved original request ID/message.
