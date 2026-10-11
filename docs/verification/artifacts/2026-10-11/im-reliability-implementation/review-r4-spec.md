# R4 specification and domain review

Result: PASS for the frozen source implementation, before quality/security review. Candidate `99980f0e2062b151d38a9db316957fbb718eefd3`, worktree `C:/Users/Administrator/.codex/worktrees/im-android-fgs/StarChat`; reviewer is independent of the implementer. Review on 2026-10-11 +08. This is not full R4 device/release acceptance.

Checked against approved plan R4 and the task record's parent-approved 20-minute shared CPU/Wi-Fi lease:

- The fixed local 19.4.2 fork reports success only after native `startForeground` returns. Platform start rejection, invalid input, cancellation and a five-second acknowledgement deadline return failure; it uses START_NOT_STICKY. Dart arbiter reports applied/denied/stopped, separate from desired owners, and keepalive records running only for an applied request.
- Sync locks have application-scoped native ownership. Acquisition requires a confirmed service and returns an actual Boolean; a Wi-Fi failure rolls back an already acquired CPU lock. Dart false/null/exception results cannot claim locks.
- Both Android timeout signatures and onDestroy release sync resources before stopForeground/stopSelf and then best-effort Dart notification. Closed state makes repeated stop/timeout/destroy safe. Lease expiry releases both locks and reports only locksReleased; it does not falsely report FGS stopped.
- Start/stop sequencing uses Dart epochs and serialized arbiter work plus native request IDs. Cancelled or expired late native requests do not start foreground, and the explicitly tested old cancelled request cannot stop a newer applied request. A foreground retry waiting behind the old Dart attempt is retained.
- No watchdog timer remains. The post-stop native gate blocks dataSync in background until foreground; microphone/camera-only requests remain subject to Android restrictions. Such a call start does not clear the blocked sync-lock gate while backgrounded. Shared FGS timeout does not invoke the separate CallForegroundService or mutate CallManager.
- pubspec and lock change only hosted 19.4.2 to the versioned local path. No package version/build/signing change or new permission was introduced. The manifest product delta is a comment.

Evidence identity: all 117 entries in verified-inputs.json were independently recomputed and matched; the frozen HEAD/worktree was clean, and candidate diff-check returned 0. Read final Flutter 138-pass log, analyze/no-issues log, successful native compilation/JVM log and native-results.json (24 tests, no failures/errors/skips), as well as the supplied RED descriptions and added test assertions. These unchanged-input results are reused under the repository workflow; no duplicate full-suite run is represented.

No specification or domain blocker found. Shared full Flutter/repository gates, iOS compilation, real short-quota device drill with configuration restoration, long lockscreen/power/Doze/OEM checks, and fixed-signature APK rebuild/install are explicitly still pending. No whole-device delivery or actual ongoing-call power/quota acceptance is inferred from Robolectric or source inspection. Proceed to quality/security review of the same candidate.
