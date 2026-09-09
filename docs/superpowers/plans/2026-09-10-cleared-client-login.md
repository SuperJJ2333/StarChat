# Cleared Matrix client first-login repair

Continuation of user-authorized account-switch repair. Ownership: matrix_e2ee_client.dart, matrix_client_factory_test.dart, ADR0004 clarification and verification evidence. No APK/IPA replacement or local data deletion outside user-confirmed app flow.

Reproduced: successful explicit clear sets suspended metadata null; next login resumes a fresh client but unconditional old-continuity check rejects null. L04 occurs before homeserver check/token consumption.

Design: allow one fresh unsigned-in client adoption only after successful explicit clear AND through an explicit login operation. Require no logged-in identity/device/fingerprint. Ordinary sync/resume keeps exact prior continuity check; failed clear never enables fresh adoption. Invalidate fresh allowance after adoption; preserve allowance when opener fails for safe retry. No server or E2EE/key algorithms change.

- [x] Test real SDK gateway clear -> login, observe expected different-identity red.
- [x] Implement bounded lifecycle transition, test rejected stale clients and ordinary sync after clear.
- [x] Domain then quality review, focused/full tests and analyzer; record limitations and package handoff.
