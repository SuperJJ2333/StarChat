# Wallet binding guidance and MI 6 debug delivery

User approved simplifying binding and requested a debug-signed MI 6 build. Figma remains deferred by prior user instruction.

Own manual_wallet_page.dart, manual_mfa_page.dart, related wallet widget tests, and this task's verification artifacts. Preserve API contracts, exact signed message bytes, original idempotency keys and authentication. Do not claim automatic wallet connection: no connector exists yet; wallet choice is requested for integration validation.

1. Add red tests for collapsed technical payload, intact expanded message and clear verification guidance.
2. Implement numbered binding steps, human-facing signature labels, collapsible details, countdown, and authenticator explanation/setup navigation.
3. Preserve uncertain-result recovery; do not discard submitted requests on a client-side expiry guess.
4. Run wallet tests, analyzer and repository verify. Review scope then security properties.
5. Build an incremented ARM64 debug APK, conventionally rebuild and verify using the existing debug certificate. Identify MI 6 and compare installed certificate before replacement; do not uninstall or substitute another device.

Automatic wallet signing and final device installation require a compatible chosen wallet and the MI 6 connection. These must be reported as incomplete until actually verified.
