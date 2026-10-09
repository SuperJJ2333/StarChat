# iOS 2213 signing handoff

User requests latest iOS IPA for their enterprise signing, then later distribution. This plan continues the approved unsigned-device packaging path; no product behavior change, Apple upload or production publication.

1. Freeze main ee558632 and current 0.4.44+2213 shared source. Isolated worktree ios-signing-2213; own only CI version constants, version contract test and task/evidence.
2. Prove old workflow version mismatch red, update all build/verify/artifact boundaries to source version, run focused mobile contracts. Reuse exact main shared5758/analyze gates; execute fresh macOS device and storage gates.
3. SPEC then QUALITY review, commit and push only codex/ios-history-ipa-2213 to trigger existing unsigned workflow. No main push or TestFlight upload.
4. Bind run/head/attempt, inspect complete arm64 device app and native tests, download exact artifact and verify manifest/source/payload SHA/CRC/entitlements. Preserve failed attempts.
5. Deliver IPA and entitlement handoff, record SHA/path and pending enterprise signature/device upgrade checks. Later distribution uses returned signed bytes and a separate final signature gate.
