# StarChat local fork: flutter_local_notifications 19.4.2

Upstream package: `flutter_local_notifications` 19.4.2 from pub.dev. Original
archive SHA-256 in the application lockfile was
`7ed76be64e8a7d01dfdf250b8434618e2a028c9dfa2a3c41dc9b531d4b3fc8a5`.
The upstream BSD license is retained in `LICENSE`. Source was copied from the
local immutable pub.dev cache; the global cache was not modified. Example app
and generated artifacts are omitted. All Dart, iOS and macOS executable source is unchanged. Upstream trailing
whitespace is normalized in README, CHANGELOG and the iOS podspec so repository
whitespace checks remain clean; the podspec content is otherwise unchanged.

R4 patch is limited to these Android files:

- `ForegroundService.java`: acknowledges a request only after native
  `startForeground` succeeds; startup failure and the 5-second acknowledgement
  deadline return errors. Cancellation and stale request IDs cannot revive a
  stopped service or stop a newer session. Returns `START_NOT_STICKY` to avoid
  automatic background restart. Both Android timeout signatures and destruction
  release the application resource owner, stop foreground/self, then notify it.
- `FlutterLocalNotificationsPlugin.java`: routes foreground start/stop through
  this contract and cancels pending replies on engine detach.

`SyncKeepAliveResourceOwner` in the application owns only sync CPU/Wi-Fi locks;
it does not own or stop `CallForegroundService` or change call UI state. It uses
one 20-minute lease for both locks, without background renewal. Expiry releases
both locks and reports `locksReleased`; FGS running state remains distinct.
After an OS stop, background restart is blocked until the app is in foreground.
This gate applies to sync. Microphone/camera-only call requests are still checked
by Android and do not clear the sync lock gate while the app is in background.

Tests run in the application's JVM test target (using its existing fixed
Robolectric version), including the package-local
`ForegroundServiceLifecycleTest` and `SyncKeepAliveResourceOwnerTest`. No new
test dependency or runtime permission is introduced. Dependency updates must
reapply and rerun these contracts; do not switch back to hosted 19.4.2 silently.
