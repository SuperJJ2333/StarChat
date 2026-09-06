# Call permissions and return-to-call behavior

Approved by the user's request on 2026-09-05. Existing permission to defer Figma remains applicable.

1. Root owns CallPage, CallUiManager, AppHome, and NativeCallCoordinator wiring: leaving/minimizing a call never hangs up; retain a global in-app return entry; explicit notification/overlay return restores the same session; terminal states remove entries.
2. Permission agent owns readiness gateway/checklist, NotificationSettingsPage and MainActivity permission methods. Show actual microphone, camera, notification, channel, full-screen and overlay capability; request only following user action; re-check on resume. No forced permission grants or assumed OEM authorization.
3. Native return agent owns call services/bridge/notification classes, call_notifications.dart and call-specific AndroidManifest entries. Preserve ongoing notification/service after presentation dismissal; overlay is optional; notification taps restore rather than answer; select permitted audio/video service types.
4. Write failing focused regressions for each root cause, then implement and test. Inspect available MI6 permissions read-only; never place real calls or modify permissions silently.
5. Run relevant Flutter/JVM checks, specification then quality/privacy review, and record evidence under docs/verification/artifacts/2026-09-05/call-permissions-return/. Build validation follows integration. System/user/OEM restrictions remain explicit limitations.
