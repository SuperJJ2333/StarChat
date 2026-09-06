# Root back and native call overlay verification

Scope: approved `2026-09-05-background-call-signature.md` plan. No APK installed or real recipient called for these checks.

## Findings and changes

- MI 6 (`cbd0156b`, API 28) read-only adb: `SYSTEM_ALERT_WINDOW: allow`. Existing running services included Getui and notification foreground service, but no CallOverlayService. This permission was already granted; missing overlay cannot be attributed solely to permissions.
- CallManager.appContext was initialized only by push/Telecom receivers. A foreground Matrix call or outgoing call bypasses those receivers. `minimizeCallPresentation` returned false immediately on null context. NativeCallBridge now requires Context at setup, stores only applicationContext, and MainActivity supplies it before any report/minimize request. Existing cold-start receiver paths remain valid.
- Flutter's default FlutterActivity.popSystemNavigator returns false, leaving the platform plugin to finish the activity on root back, particularly relevant on API 28. MainActivity now consumes that unhandled root navigation by `moveTaskToBack(true)`. Flutter child route navigation is handled before this callback.
- Home/app switching kept CallPage mounted and never invoked minimization. CallUiManager now requests native overlay on paused and hides it on resumed only when the user has not intentionally minimized the call. This changes presentation only; media ownership and explicit rejection behavior remain unchanged.
- Getui gateway wiring in AppHome was updated at the push agent's request to its new canonical URL helper.

## Executed evidence

Artifact directory: `docs/verification/artifacts/2026-09-05/background-call-signature/`.

- `native-red.log`: root-back regression failed its assertion that root back must be consumed. This was the unchanged inherited FlutterActivity behavior.
- `native-overlay-red.log`: initial test compilation exposed the missing context setup API, plus a corrected Robolectric shadow type in the test harness. This alone is not runtime proof.
- `native-overlay-assertion-red.log`: with the context assignment absent, the executable bridge test failed because applicationContext was null; the root-back regression already passed.
- `native-green.log` and `native-overlay-results.xml`: all 6 native call tests passed (3 new presentation tests and 3 existing pending-action tests). New tests execute encoded native_call MethodChannel messages, report a connected call without a prior push, verify the started component is CallOverlayService, run its actual onStartCommand and assert WindowManager has one attached view. A second start retains one view; ended state stops the service; destruction removes the view. Permission denial returns false without starting a service or changing the active call. Three repeated root-back requests are consumed without finishing MainActivity.
- `flutter-overlay-red.log`: lifecycle regression initially failed because handleAppPaused was missing.
- `flutter-call-green.log`: 41 tests passed across CallUiManager, CallPage and NativeCallCoordinator, including back minimizing without hangup and native presentation-ended preserving the distinction from explicit reject.
- `flutter-call-analyze.log`: focused Dart analysis reports no issues.

Native tests use fixed Robolectric 4.14.1 and API 28 with Config.NONE. Enabling Android resource inclusion hit an AGP 9/Flutter assets task dependency configuration error, so the service/window tests use framework resources only. Existing Android build deprecation warnings remain (Flutter/Kotlin plugin migration and existing platform API usage); no new warning suppression was added.

## Review boundaries

Specification check: root-back backgrounds; child route behavior stays with Flutter; leaving active call provides a native overlay when permission is allowed; permission denial preserves the call; returning to call does not answer/reject; no financial or E2EE domain changes.

Quality check: context initialization retains the Application rather than Activity; bridge teardown/reinitialization remains idempotent; overlay duplicated starts are tested; terminal-state cleanup and denied permission are tested. No background restart loop, task-swipe override, force-stop workaround or keepalive escalation was added.

Remaining release validation belongs to the parent task: build the final integrated APK, then user/device verification of actual UI transitions. Robolectric verifies Android service/window behavior but does not claim OEM task-swipe delivery or real encrypted media continuity has been tested on a device.
