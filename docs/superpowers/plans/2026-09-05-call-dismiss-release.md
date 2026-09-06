# Call presentation dismissal and ARM64 release

Status: Approved by the user's request to fix calls closing when the other account answers and to publish the ARM64 release (2026-09-05).

1. Trace Matrix/controller and native presentation termination separately; do not infer TURN or permissions as the cause without evidence.
2. Native coordinator owner: `native_call_coordinator.dart`, its test, and native `CallManager.kt`, `CallBridge.kt`, `CallConnectionService.kt`, `CallActivity.kt`. Root owns Matrix/controller investigation, release and shared verification.
3. Reproduce presentation-ended events terminating connecting/connected calls in tests before implementation. Include delayed previous-presentation events and explicit current user hangup/reject controls.
4. Separate presentation disposal from explicit user termination. Native presentation identifiers are opaque wakeup IDs, not Matrix session IDs; validate against the registered presentation only.
5. Run focused tests, specification review then quality/security review. Record evidence beneath `docs/verification/artifacts/2026-09-05/call-dismiss-release/`.
6. Root runs remaining required checks and publishes the authorized ARM64 artifact. Device verification remains distinct from unit-test evidence.
