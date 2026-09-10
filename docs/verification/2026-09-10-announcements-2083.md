# Announcement member read verification — 2083

Scope: approved `docs/superpowers/plans/2026-09-10-four-fixes-2083.md`; owned files are `group_announcement_service.dart`, `group_announcement_page.dart`, new `group_announcement_member_test.dart`, and this evidence. No shared Matrix client, SDK, schema, server, signing or deployment edits.

## Root cause and correction

The existing announcement read path has **no moderator gate**. The vendored SDK `Room.getEventById` returns database hits immediately (`third_party/matrix/lib/src/room.dart`, around 1828), while only its network branch invokes decryption. `MatrixGroupAnnouncementService.load` previously assumed the returned event was already decrypted and required `originalSource.type == m.room.encrypted`; a cached encrypted event therefore produced `公告暂不可用`, surfaced as `公告加载失败，请重试`. The focused ordinary-member fixture reproduces this exact failure. This is source and automated reproduction evidence, not a claim to have inspected the particular user's failing device event.

The service now decrypts cached ciphertext locally through the existing SDK encryption implementation before validating sender/encrypted provenance. It checks joined membership before and after asynchronous reads. Save/upload still require the existing manager authority and E2EE setup; state writes remain an opaque event reference. Images use the same decryption helper. Missing/explicitly cleared announcement state remains normal empty content, and genuine failures remain retryable rather than becoming empty content.

The detail page now observes service changes, exits editing when moderator authority is revoked, reloads when the service/account changes, and rejects stale asynchronous read completions. The banner resets its content/subscription on service changes. The existing heading `群公告` and ordered content blocks remain; publisher name and local publication time are now derived from the authenticated decrypted event and synchronized member state. Missing display names use `群成员`, without displaying raw Matrix IDs or fetching a profile just to render metadata. The existing document schema has no separate title field.

## Red / green evidence

Artifacts: `docs/verification/artifacts/2026-09-10/four-fixes-2083/announcements/`.

- `red.txt`: cached-ciphertext member read, departed-member cached read, stale account load, and role revocation tests fail for the intended missing behavior; genuine failure retry/empty state already passes.
- `banner-red.txt`: old account banner content remains after service replacement before the fix.
- `metadata-red.txt`: publisher/date rendering missing before the addition.
- `green.txt`: 23 tests pass across member tests, existing announcement service tests, and existing draft/banner tests.
- `analyze.txt`: focused Flutter analysis of all three changed Dart files reports no issues.

Commands from `apps/mobile_flutter`: `C:/src/flutter/bin/flutter.bat test --no-pub test/features/matrix/group_announcement_member_test.dart test/features/matrix/group_announcement_test.dart test/features/matrix/group_announcement_draft_banner_test.dart --reporter expanded`; `C:/src/flutter/bin/flutter.bat analyze --no-pub lib/features/matrix/group_announcement_service.dart lib/features/matrix/group_announcement_page.dart test/features/matrix/group_announcement_member_test.dart`. Dart format ran on these same three files.

## Review

Specification review: normal joined members can read; manager writes remain gated; empty and retry states stay distinct; stale account reads and revoked edit controls are covered; heading/body/publisher/time are present for current encrypted documents. Legacy topic-only content has no authenticated publication metadata in the existing model and remains readable as before.

Quality/security review: no plaintext, room/session keys, sender IDs, or attachments are added to public room state or business APIs. Sender matching and encrypted-origin validation remain intact. No permission thresholds, key sharing, algorithms, or E2EE policy changed. Whole-repository verification, Redmi installation and device acceptance remain the parent task's responsibility.

## Review follow-up: pending editor operations

The review identified that load epochs alone did not protect pending image selection/file reads or save completion. `lifecycle-red.txt` reproduces five failures: save success popping the replacement page, save failure surfacing on the replacement page, and delayed picker/length/byte reads inserting an old-account image. Each editor operation now captures its service and editor epoch; service replacement and role revocation invalidate that epoch. Every asynchronous continuation, error and busy-state cleanup is guarded. Picker results from an obsolete service are dropped before reading the file.

`lifecycle-green.txt`: all 28 focused announcement tests pass, including all five new lifecycle regressions. `lifecycle-analyze.txt`: final analysis reports no issues after retaining an explicit mounted guard for navigation. Only announcement page and member-test Dart files changed in this follow-up.

## Final acceptance follow-up: retry classification

`error-red.txt` reproduces three inappropriate retry buttons for non-member, malformed document, and unknown local exceptions. The page now limits load retry buttons to socket/HTTP client transport errors, timeouts, and recoverable Matrix HTTP 408/429/5xx responses. Membership/Matrix permission errors show an explicit permission message; format errors show a format message; unverified/undecryptable or unknown failures show a non-interactive unavailable message. These cases do not become empty announcements, and later sync/service replacement still reloads them. Errors are not interpolated into user text.

The pre-existing transport fixture now throws an actual SocketException instead of labelling a StateError as offline. Additional tests cover timeout, HTTP client failure, server 503 retry, plus non-network failures recovering through the change stream. `error-green.txt`: 34 focused tests pass. `error-analyze.txt`: no issues. Changes remain confined to the announcement page/member test and this note.
