# 827db32 mention recheck

Commit checked: 827db32. Read-only production review.

## P1: unread mention feature still has no runtime wiring

room_page.dart:223-226 only declares `late final UnreadMentionTracker unreadMentions`. Repository-wide lib search has no reference reading this field. Dart late initialization is lazy, so merely declaring it does not instantiate it. No production external callers of initializeBoundary/onMessageArrived/markViewed, no persistence restore/save, no external usage of conversation_mention_banner.dart components. Thus the room cannot populate, show, navigate, consume, or persist the planned unread-mention feature. This is the previously reported incomplete integration, not a new tracker model bug.

## P2: selection-only move still does not clear trigger

room_page.dart:310 wraps text-diff processing AND the new cursor range check at 326-333 in `if (next != _lastComposerText)`. Moving only the caret fires controller listeners with unchanged text and bypasses the check. Input @ then 兄, move caret to zero: pendingTriggerStart remains 0 and panel remains active.

Verification: selection_only_regression_test.dart copies current production controller/model event order (explicitly not full RoomPage E2E). `flutter test --no-pub <absolute probe path> --reporter expanded` failed 1/1 with expected null, actual 0; see selection-only-output.txt.

The two trigger tests in recheck_regressions_test.dart:94-118 only test clearAfterSend and text assignment, no selection event. The clearAfterSend production call at room_page.dart:794 is present and clears the model after recipient snapshot, so that specific prior bug is fixed.
