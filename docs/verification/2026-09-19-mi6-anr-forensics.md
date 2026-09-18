# Mi 6 ANR forensics — 畅聊 ChatFlow「没有响应」(2026-09-19)

**Status: IN PROGRESS — root cause not yet identified.** This file records only what the evidence
already establishes, so that later conclusions can be checked against it. Nothing here is a fix.

**Reported symptom.** On the Xiaomi Mi 6 (`cbd0156b`, package `com.liuhetong.mobile`) the debug build
pushed for testing (`0.3.96` / versionCode 2134) launches, shows the main screen, and then stops
responding: the system dialog「畅聊 ChatFlow没有响应」appears. The user confirmed the previously
installed `0.3.95` / 2133 build worked normally on the same phone on 2026-09-18 after its
installation at 19:02:33 (`artifacts/2026-09-18/android-0.3.95-debug-2133/install.log:129`), and only
started hanging on 2026-09-19.

## 1. Identity of the builds under test

| Build | versionCode | mode | signer cert SHA-256 | note |
|---|---|---|---|---|
| `artifacts/2026-09-19/android-0.3.96-debug-2134-wallet/final.apk` | 2134 | debug (JIT) | `75b31c66…61fff` | `sha256 5211f972…cf117`; the reported broken build |
| `artifacts/2026-09-18/release-2134/android/final.apk` | 2134 | **release (AOT)** | `75b31c66…61fff` | 79,997,982 B; the control experiment |
| `artifacts/2026-09-18/android-0.3.95-debug-2133/ChatFlow-0.3.95-debug-2133-arm64-rebuilt.apk` | 2133 | debug (JIT) | `75b31c66…61fff` | `sha256 ce52dec1…ac296`; source commit `61b29917`, **does not contain** the outbox commits |

`firstInstallTime` stayed `2026-09-11 00:42:05` throughout every `adb install -r`; no uninstall and no
data clear was ever performed.

## 2. Raw evidence

- ANR traces (4) extracted from `artifacts/2026-09-19/anr-forensics/bugreport-2133-anr.zip`
  (`FS/data/anr/anr_*`), plus a release-AOT capture in `bugreport-release-aot-anr.zip`.
- `anr-forensics/logcat-warm-relaunch-2133.txt` — debug 2133 warm relaunch (no reinstall).
- `anr-forensics/server-request-rate-probe.txt` — production gateway/business-API/Synapse request-rate
  forensics, with the probe scripts `anr-server-probe.sh` / `anr-server-probe2.sh`.
- `artifacts/2026-09-19/android-0.3.96-debug-2134-stallprobe/` — instrumented diagnostic build.

## 3. Thread CPU, recomputed from the traces

Per-process `utm` (user ticks, HZ=100) taken from the section whose `Cmd line:` is
`com.liuhetong.mobile`; the two last rows are the **same pid** 65 s apart, so their deltas are the
meaningful numbers:

| trace (CST) | pid | main | DartWorker threads | 1.raster |
|---|---|---|---|---|
| 06:11:19 | 11407 (2134) | **R** 1605 | 222 / 146 / 12 | — |
| 06:12:04 | 12097 (2134) | **R** 1968 | 289 / 172 / 11 / 4 | — |
| 06:14:58 | 12936 (2133) | S 3175 | 881 / 518 / 95 / 12 | 48 |
| 06:16:03 | 12936 (2133) | S 7821 | 2480 / 2011 / 2 | 48 |

Delta over those 65 s: main **+46.5 s** CPU, DartWorker **+29.9 s** CPU ⇒ **~76 s of CPU in 65 s of
wall time (>1 core)** while `1.raster` accumulated only **0.48 s** in total, i.e. essentially no frame
was ever committed. The main-thread stack at 06:16:03 is parked in `nativePollOnce` → `Looper.loop`,
with `pthread_cond_wait` and libflutter frames inside that call and `[anon:dart-code]` beneath them:
at the sampling instant the thread is idle, but across its lifetime it burned ~70 % CPU.

**Correction to an earlier draft of this investigation:** the figures "main state=R utm=2070,
DartWorker 453/398" come from a different process section and do not describe pid 12936.

## 4. `1.ui` absence is expected, not a misconfiguration

`lib/arm64-v8a/libflutter.so` extracted from `release-2134/android/final.apk` contains
`no-enable-merged-platform-ui-thread`, `Unable to move the UI task runner to the platform thread` and
`MergedPlatformUIThread::kMergeAfterLaunch does not support spawning`; a regex over the whole `.so`
finds only two Android embedding meta-data keys (`…EnableImpeller`, `…EnableFlutterGPU`), and neither
`packages/flutter_tools` nor `packages/flutter/lib` mentions the feature. The engine therefore merges
the platform thread with the UI thread by default here: the Dart UI isolate runs on the Android main
thread, which is why Dart `debugPrint` appears at TID == PID, why `1.raster` is the only numbered
thread, and why **any long non-yielding UI-isolate stretch starves input dispatch**. This reframes the
bug as "the UI isolate stopped yielding", not "a thread is misconfigured".

## 5. Exclusions (each with its evidence)

| Hypothesis | Evidence against |
|---|---|
| The 30 commits between `61b29917` and `d36692e9` (outbox `a60de626`, wallet, greeting, dividers) | `git merge-base --is-ancestor a60de626 61b29917` → exit 1: build 2133 does not contain them, yet ANRs identically |
| Apktool rebuild damaged the package | 2133 was produced by the earlier pipeline and ANRs identically |
| Debug-only / JIT / asserts / `debugPrint` | **release AOT 2134 ANRs too**: 06:31:28 launch via monkey, list and avatars rendered, first tap at ~25 s never processed, `Wait queue head age: 159022.7ms` at 06:34:29, ANR 06:34:33 |
| Avatar logging storm | `[AvatarLoadError]` = 0, `[AvatarLoadErrorStack]` = 0; `[AvatarFirstPaint]` = 101 lines confined to 06:29:30–31 (~50/s) then zero; the log exists only inside an `assert`, so it cannot exist in the release build that also ANRs |
| The 2.9 GB / 71,291-entry avatar cache | Moving `cache/changliao-member-avatars-v1` out of `cache/` and relaunching **still ANRs** (06:38:52, main thread still ~73 %); cache was restored afterwards |
| Directory enumeration (`media_cache.dart:679-688`, `emoji_preview_cache.dart:154`) | `app_flutter/chat-media` holds **563** files; `app_flutter/emoji-previews-v1` does not exist |
| SQLite blocking the UI isolate | `createDatabaseFactoryFfi` runs on a background isolate; the `Sqflite` thread is idle in every sample |
| Synchronous `dart:io` | no `Sync(` calls to blocking filesystem APIs in `lib` |
| Java Looper blocked | Looper healthy; the blocker is the merged Dart UI isolate (§4) |
| HTTP retry storm / polling pile-up | gateway per-minute totals for the phone (`111.45.23.7`): 37, 80, **1**, 43, … during 22:10Z–22:14Z; ~46 requests/min baseline over 6 h; nothing above 135/min all evening; Synapse serves these in 0.001–0.018 s. **No storm** |
| The production deploy window | the ANR reproduces at 06:31–06:38 CST, long after the 06:11–06:20 CST switch, with the API healthy (health 200/200) |
| `app_home.dart:979-1010` 5 s poll | `FriendRequestWatch.poll()` is single-flight (`_polling ??= …whenComplete`), `refreshContactsQuietly()` is throttled to 15 s with the timestamp set before the `await`; neither can pile up. Hygiene only (the comment still says 60 s) |

## 6. Server-side observation worth keeping

The phone's traffic is **bursty per launch**: ~30–40 requests inside ~6 s (identities lookup, privacy,
friends, Matrix `sync`, room `members`, avatar thumbnails, `app-updates`), then near-silence. During
each hang the client makes **no requests at all** — the gateway sees 1 request in whole minutes — which
means the stall is local computation, and it also means the process got *through* its startup request
burst before it stopped yielding.

## 6b. Tap matrix — the ANR is *declared* on input; the freeze itself is time-triggered

Fresh launch per action, one action only, 30 s settle, `am start` (not `monkey`, which injects its own
events):

| action | result |
|---|---|
| **touch nothing for 180 s** | **no ANR**, focus stayed on MainActivity the whole time |
| tap conversation 「傻逼集合地」 | no ANR |
| tap 「测试群」 | **ANR** |
| tap 通讯录 / 我 / 发现 tabs | no ANR (tab switch visible) |
| tap 「测试群」 again | **ANR (2/2 reproducible)** |
| tap 「哥们测试群」 | no ANR |
| tap 「测试」 | **ANR** |

**This table must not be read as "input causes the hang".** The instrumented run measured the stall
onset directly: `STALL_DETECTED … silent=3923ms at wall=20014ms` puts the freeze at wall≈16.1 s,
**14 s before the first tap of that run**. Android only *declares* an ANR when an input event is pending
and unserviced, so "no touch ⇒ no ANR" measures the declaration condition. The app is most likely
frozen for most of those 180 s. An earlier draft of this investigation concluded the opposite; that
conclusion is withdrawn.

The last Dart line before the freeze is
`[room-open] room-open source=conversation_list mode=offlineFirst outcome=openedLocal reason=local_joined
room=!UjnfrgeCTdwOdENAVr:matrix.localhost` in tap runs (the room opens **from the local store**), and in
the no-touch probe run the freeze instead lands 0.1 s after the notification/push startup lines
(`[channel] initialized 3 channels` → `[startup] notification system ready` → `[fgs] acquire:…` →
`[push] getui initialize: true` → `[push] firebase unavailable`). A same-second coincidence is a time
anchor, not causation.

Room sizes on the homeserver (read-only, `anr-forensics/room-content-probe.txt`, `hang-room-dump.txt`)
rule out any scale explanation:

| room | events | joined members | tap result |
|---|---|---|---|
| `!UjnfrgeCTdwOdENAVr` (测试) | **16** | 3 | **ANR** |
| `!RNLeLdUImdjTHEyRIe` (测试群) | 32 | 2 | **ANR** |
| `!nBQXdLFZaurrFInqIO` (测试群) | 2538 | 5 | — |
| `!nsnBepMjaTOSYXwjns` (哥们测试群) | 327 | 6 | no ANR |
| `!DGnWZMrOawXypvdfxo` (傻逼集合地) | 154 | 1 | no ANR |

A 16-event, 3-member room hangs while a 327-event, 6-member room does not: the trigger is specific
content, not volume. No dangling or cyclic reply relations exist in any room.

## 6c. Mechanism, established by instrumentation (probe v1)

`anr-forensics/stallprobe-run1.log` (246 MB, build `STALL_PROBE` v1, SHA-256
`07b098530284dbc26c66092c085c9b72b8a98dd422cb5a31f9e8ef189922bf78`):

- **The timer queue dies.** The 1 s heartbeat fires for the last time at 07:05:38.699 (t=14,530 ms) and
  never fires again; the main isolate goes silent at wall≈16.1 s while the callback counter keeps
  climbing to **~5,400 callbacks/s and stays there for 90+ s**. The watchdog prints `STALL_ONGOING`
  every 5 s and **no `RESUME` appears** in the capture window.
- **No platform call is stuck**: the last heartbeat's `inflight` holds at most
  `local_notifications#deleteNotificationChannel:650ms` (the same call merely *ageing*, 200 ms → 650 ms)
  and `sqflite#query:4ms`. So this is not a hung native call.
- **Composition of the flood** (508,901 `enter` lines over 92 s ≈ 5,530/s): `unaryCallback` 254,453 and
  `callback` 254,448 — a near-perfect 1:1 pairing, i.e. **one stream event delivering to two
  subscribers**. Stack anchors: `_rootRunUnary` 100 % of unary callbacks,
  `_microtaskLoop` 37.5 %, `_BufferingStreamSubscription._sendData` 25.0 %, and **`Future._propagateToListeners` 0**,
  **`Timer._createTimer` 0**. So the mechanism is **an asynchronous Stream delivering ≈1,380 events/s
  through the microtask loop**, starving the timer queue and, through the merged platform/UI thread,
  input dispatch. A future-continuation chain is *excluded* (0 occurrences).
- **The feeder is local, not network-driven.** The gateway log for the probe run's own window
  (07:05 CST = 2026-09-18 23:05 UTC, client `111.45.23.7`) shows a normal launch burst of 41 requests
  over 11 s, then **one request at 23:06:00 and nothing until 23:12** — the app is off the wire for the
  entire flood. Matrix `/sync` count over 23:00–23:15Z is 20 (≈1.3/min). `onSync` therefore cannot be
  the feeder; any sync-driven loop is at most a co-symptom.
- **Probe versions** (all debug 2134, same fixed signer, `STALL_PROBE=true`):
  | build | SHA-256 | what it samples |
  |---|---|---|
  | v1 | `07b09853…22bf78` | per-callback `enter` with creation stack — too noisy, stack truncated at 6 frames, probe frames defeated the app-frame filter |
  | v2 | `2df109f5…f455840` | counters + sampled **invocation** stacks (18 frames) + flood summaries |
  | v3 | `283e7427…861ed36` | as v2 plus sampled **microtask-scheduling** stacks, which is where an asynchronous `StreamController.add` exposes its caller (the emitter) |
  v1's probe adds a zone, a channel wrapper, an isolate and (in v1) ~5,400 log lines/s, so it perturbs
  timing and the ANR was not declared in that run; mechanism claims come from the probe, product-level
  claims still come from the un-instrumented builds and the ANR traces.

## 6d. Root cause (identified) and fix

**Root cause.** The vendored Matrix SDK's `Event` constructor self-heals an event that has been left in
`sending` for longer than `Client.sendTimelineEventTimeout` (1 minute by default; the app never
overrides it) by re-injecting that event through `Client.handleSync`
(`third_party/matrix/lib/src/event.dart:120-146`). Sync handling reconstructs events while it persists
them — `MatrixSdkDatabase.storeEventUpdate` builds the previous row as an `Event` at
`matrix_sdk_database.dart:1063` — so with the unguarded self-heal **one stale `sending` row re-entered
sync processing on every reconstruction, without bound**:

```
MatrixSdkDatabase.storeEventUpdate (matrix_sdk_database.dart:1063)
  -> Event.fromJson -> Event() -> (event.dart:120-146) Client.handleSync
     -> _handleSync (client.dart:2404) -> _handleRooms (client.dart:2536)
        -> onSyncStatus.add(...) per room (client.dart:2540)
           -> _AsyncBroadcastStreamController._sendData -> _PendingEvents.schedule
              -> scheduleMicrotask            <- 33 % of all microtasks, single top-1
        -> ... storeEventUpdate again -> Event.fromJson(previous row) -> handleSync -> ...
```

This is exactly the chain device instrumentation captured (probe v3, `microflood … top=[n=329472 @
_CustomZone.scheduleMicrotask <- … <- CachedStreamController.add <- Client._handleRooms
(client.dart:2540) <- Client._handleSync (2404) <- Client.handleSync (2392) <- new Event
(event.dart:132) <- new Event.fromJson (event.dart:190) <- matrix_sdk_database.dart:1063]`). It explains
every observation: **purely local** (the synthetic `SyncUpdate` never touches the network, and the app
was off the wire for the whole flood), **stream/microtask driven** (~1,380 deliveries/s to two
subscribers), **timer queue dead** (`timers` frozen at 248 while `inv` reached 2,653,623), **no frames**,
**content/room dependent** (only rooms holding a stale `sending` row), **identical in debug and
release** (SDK-level, not build-mode), and **"the same APK worked yesterday"** — the trigger is a local
row that becomes stale one minute after a send was left unfinished, so it is a threshold the data
crosses, not a regression in a recent commit.

**Fix (2026-09-19).** `third_party/matrix/lib/src/event.dart` now claims the self-heal at most once per
`<roomId>\u0000<eventId>` per timeout window (bounded map, 512 entries). The heal itself is unchanged —
the event is still re-injected, still marked `EventStatus.error`, still persisted through the same sync
path — it can no longer be re-entered from inside its own reconstruction. Recorded in
`third_party/matrix/CHATFLOW_PATCH.md`; regression
`test/features/matrix/sdk_stale_send_selfheal_test.dart` (real vendored `MatrixSdkDatabase` on an
in-memory sqflite database; seeds one stale `sending` event and asserts that `Client.onSyncStatus`,
which `_handleRooms` writes once per processed room, observes at most one sync run).

**RED.** With the guard bypassed the same test **never completes** — it was killed at the 600 s cap
because the reconstruction storm starves the event loop, i.e. the test reproduces the production
failure rather than merely asserting around it. **GREEN.** With the guard in place it passes in under a
second; `flutter analyze` clean, `test/features/matrix` +1669, full suite **+3364**.

## 6e. Device verification of the fix (instrumented build, probe v3)

Verification build `android-0.3.96-debug-2134-staleheal-fix/final.apk`, SHA-256
`39bf010cf77a907ceca4ba86fb647445bce38cab39d7bcae078dacce16f8d6a9`, 145,068,331 B, versionCode 2134,
debuggable, signer `75b31c66…61fff`. Installed with `adb install -r`; `firstInstallTime` stayed
`2026-09-11 00:42:05`; no uninstall, no data clear.

**A — same no-touch 150 s run as the failing baseline** (log saved raw before grepping,
`anr-forensics/staleheal-fix-run1.log`):

| metric | before (`stallprobe3-run1.log`) | after |
|---|---|---|
| `hb` heartbeats | stop at t≈11.7 s | **144 lines, last at t=144,647 ms** |
| `timers` | frozen at 248 | monotonically 3 → 804 |
| `micro` | 992,000 (still climbing) | **15,242** (≈65× lower) |
| `inv` | 2,653,623 | 67,515 |
| `frames` | 24 | **87** (884 by the end of the interactive run) |
| `STALL_DETECTED` / `STALL_ONGOING` | 1 / 18 | **0 / 0** |
| `microflood` samples | 31, top-1 `n→329,472` | **0** (the 32,000 threshold was never reached) |

**B — the interactions that previously reproduced the ANR 2/2**: tap 「测试群」(540,527) → ok, back → ok,
tap 「测试」(540,985) → ok, back → ok, scroll → ok, reopen 「测试群」 → ok, all four tabs → ok.
`ANR in com.liuhetong.mobile` appears **0 times** in logcat. Screenshots show the conversation actually
rendered (`anr-forensics/fix-verify/1-ceshi-group.png`, `3-ceshi-group-25s.png`), so "no ANR" is not a
silent no-op. The final probe line at t=235,642 ms is `timers=1662 micro=27891 frames=884 inv=127410
inflight=[none]`.

**Observations left open (not ANR, not fixed by this change):**

1. The conversation list contains messages showing the red failed-send bubble. Those are precisely the
   local rows that were stuck in a failed/`sending` state and triggered the recursion; after the fix
   they no longer cause a livelock but they remain genuinely failed sends — a data/business question
   (resend or clean up), outside this fix.
2. One `slowFrame`, one `slowTimer` and one cold-start `W Looper: Slow Looper main … 1877ms late` were
   seen; all are single start-up costs, far below the stall threshold.
3. In one session the first screen of 「测试群」 was still blank at the 10 s screenshot while
   `[AvatarFirstPaint] source=room-message` was still logging. The two screenshots are of different
   rooms (the list was scrolled in between) and the room may genuinely have had no local messages, so
   this is **an observation, not a finding**.
4. This evidence is from an instrumented build. Product-level confirmation was then taken on the
   un-instrumented build (see §6f).

## 6f. Device verification on the un-instrumented product build

Build `android-0.3.96-debug-2134-anr-fix/final.apk`, SHA-256
`5c3a3beaf98d24c9bf0dae165fc85183c520fe46a07c7bedd9dec22f37337772`, 145,051,947 B, versionCode 2134 /
0.3.96, debuggable, signer `75b31c66…61fff`. The probe is not merely disabled but absent: `main.dart` was
restored to stock, `lib/debug/stall_probe.dart` was removed from the tree, and a search of the shipped
`assets/flutter_assets/kernel_blob.bin` returns no match for `StallProbe`, `microflood`, `STALL_DETECTED`
or `stall_probe`. Installed with `adb install -r`; `firstInstallTime` stayed `2026-09-11 00:42:05`; no
uninstall, no data clear.

**A — touch nothing for 150 s** (`anr-forensics/anr-fix-run1.log`): `ANR in com.liuhetong.mobile` count =
**0**; `dumpsys activity processes | grep -i anr` empty; the app stayed alive and focused
(`mCurrentFocus=…com.liuhetong.mobile/.MainActivity`) with the same pid (`30583`) for the whole run.

**B — 12 interactions, each photographed and hash-compared against the previous screen**: tap 「测试群」,
back, tap 「测试」, back, scroll, 通讯录, 我, 发现, 消息, 32 s idle inside a conversation, back to the list —
**every step `ok` (no ANR dialog, focus unchanged) and every step changed the screen**, so the app was
genuinely responding and rendering rather than silently ignoring input. Final ANR count still 0, pid
unchanged. `fix-verify-noprobe/B10-room-idle-32s.png` shows the conversation fully rendered (date
separator, join system message, timestamps, emoji message with avatar, composer), and it stayed
responsive through the 32 s idle.

**Measurement limitation stated plainly:** `dumpsys gfxinfo` is not usable for Flutter on this device —
it reports `Total frames rendered: 1` because Flutter renders through its own Skia surface instead of
hwui, so hwui frame counters are meaningless here. Rendering evidence therefore comes from per-step
screenshot change plus the instrumented build's frame counters (§6e: 884 → 2,532), not from `gfxinfo`.

**Historical record, not a new failure:** `dumpsys activity lastanr` still lists an ANR from 07:03:48
(`Wait queue head age: 59394.3ms`) produced while the *unfixed* builds were being tested. It predates
this install (`lastUpdateTime 07:43:49`) and the current session has zero ANRs and no process restart.

**Scope of this evidence:** this device and this account, over the listed paths (list, four tabs,
scrolling, entering and leaving several conversations, 32 s idle inside a conversation, ~6 minutes
total). Weak-network, background-upload, wallet and moments paths were not re-exercised here.

## 7. Instrumented diagnostic build


`artifacts/2026-09-19/android-0.3.96-debug-2134-stallprobe/` — debug 2134, same fixed signer,
`--dart-define=STALL_PROBE=true`, SHA-256 `07b098530284dbc26c66092c085c9b72b8a98dd422cb5a31f9e8ef189922bf78`.
It adds a watchdog isolate (detects a starved event loop), a 1 s heartbeat with frame/microtask/timer
counters, a **platform-channel logger** (names a native call that never returns), frame timings, and
zone instrumentation that prints the creation stack of every app/gesture/service callback **on entry**
(so a callback that never returns is still named, because `print` bypasses the event loop). It is a
diagnostic instrument, not product evidence; it comes out of the tree after the investigation.

## 8. Real defects found on the way (not the ANR; unfixed, to be ticketed)

1. `lib/ui/foundation/avatar_cache.dart` declares `maximumDiskEntries = 500` while the device holds
   **71,291** files / 2.93 GB under `cache/changliao-member-avatars-v1` — count-based eviction is not
   working; ~142× over budget.
2. `flutter_local_notifications` `ForegroundService` throws `NullPointerException:
   Intent.getSerializableExtra on a null object reference` when restarted after the main process is
   killed (separate process, 06:38:56).
3. `launch_background.xml` `<bitmap>` lacks a valid `src` (`Resources$NotFoundException`, 06:36:56).
