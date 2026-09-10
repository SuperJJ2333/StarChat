# Redmi pinned-room live comparison

Date: 2026-09-10, Asia/Hong_Kong. User requested comparing the same room before/after pinning, then reported that opposite friend-profile entry points opened different conversations. Scope remained diagnosis; no application code, room history, canonical registration, or encryption settings were changed.

## Subjects and method

Redmi `cbd0156b`: superJJ, verified installed 0.3.78-debug / 2082. User reported the peer “这个小鸿” runs Android 0.3.73; the peer device was not directly inspected. Read the running Dart VM's current client, live conversation list, and shared read-state fields. Recorded only identifiers, counters, flags and filtered notification decision lines, never message text or credentials. Full room/event identifiers and timestamped snapshots remain in ignored local artifacts at `docs/verification/artifacts/2026-09-10/pin-comparison/`.

Two distinct same-title rooms are present:

- A: `!vvlRlCSNwHGu…`, originally pinned.
- B: `!wBgWiXYJhbfr…`, unpinned.

An actual GET through the running `ApiDirectRoomCoordinator.canonicalRoomId` returned A. An invocation of the active coordinated `DirectChatController.open` also returned A, encrypted with two joined members. Most importantly, after the user navigated through superJJ → peer profile → Send message and confirmed entry, the mounted RoomPage actually held A. Thus opposite-entry divergence was not reproduced in this observation; it cannot be dismissed historically, and B still exists with separate message history.

## Same-room A observations

| Observation | Pinned | Server notificationCount | List unread | isRoomOpen | Notification evidence |
|---|---|---:|---:|---|---|
| First message capture, 15:38 | yes | 2 | 2 | false | Earlier A events permitted foreground banner and sound |
| User entered profile-linked room, 15:54 | yes | 0 | 0 | true | 15:53:32 and 15:53:37 events suppressed: `current conversation open` |
| Second message, 16:01 capture | no | 1 | 1 | false | 15:56:41 event permitted foreground banner and sound |
| Original pin restored, 16:01 | yes | 1 | 1 | false | Same last event and counts retained |

The user sent messages. The initial intended target was B based on older notification logs, but current incoming messages landed in A; the test was corrected to A and did not compare A's counts against B as if they were one room. Actual pin mutation used the existing public `MatrixConversationCapability.mutate(togglePin)` operation; temporary unpin was restored and verified. Failed earlier HTTP invocation did not change the pin. No message was sent by the agent, no manual unread mark was applied, and no notification preference was changed.

## Interpretation and limits

Pinning did not suppress unread counters in this controlled observation. A fresh message while A was not open produced server/list unread 1; restoring pin retained 1. Notification policy explicitly permitted banner/sound for both pinned and unpinned incoming events. This is policy evidence, not an independent measurement of audible hardware output or background/lock-screen delivery.

Two confirmed contributors explain the apparent inconsistency: A and B have the same display title but separate event/unread streams, and some missing alerts were explicitly suppressed while A was marked open. The live profile-entry check now resolves A; no proof establishes that all historical divergence was caused by the peer's older version. No new notification bugfix was installed during this comparison.

Recommended remaining work: use the server-registered A for new friend-profile opens; preserve B as distinguishable historical conversation rather than deleting encrypted history; bring the peer onto the current tested client; validate background delivery separately if it remains problematic. Existing history has not been merged, hidden, left or deleted.
