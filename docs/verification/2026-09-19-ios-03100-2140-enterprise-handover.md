# iOS0.3.100/2140 enterprise re-sign handover

Candidate source: mainbb408e92f54ca79b9695b879eb3536c59a582c13, matching Android2140 source. GitHub signed workflow35453172213 succeeded; artifact10587537876 SHA2560854a12d414e5a4ce518a087c168ad934e5559437bb93b817528f27b4142fe68. Exact downloaded IPA hash matches the CI codesign verification log. Download and offline verification completed2026-09-20T00:05+08.

File: `artifacts/2026-09-19/conversation-identity-admission/ios/ChatFlow-0.3.100-2140-enterprise-resign-candidate.ipa`,60552688 bytes, SHA256 `308692f9da345a7d34a3ba41ff099033af597c4bdcec4840b803ac5bec6ddac2`. Root-workspace delivery copy has the identical hash.

Verified: Bundle ID `com.liuhetong.liuhetongMobile`, version0.3.100/build2140, arm64 device executable, iOS16.0+, iPhone/iPad, audio/VoIP/remote-notification background modes, production APNs, get-task-allow=false, cryptid=0, SQLCipher included and loaded before sqlite. Statistics HTML matches source SHA89eab23270dc87ce6fd07715d9abb2606455d94ce1fc16cd56d2deeaeeafb9d5. Candidate Keychain declarations and default application identity match the previous2137 candidate.

This is an App Store signing-channel build for the user's enterprise re-signing, not a published enterprise OTA file. Preserve Bundle ID/version/build and required capabilities. Use the same enterprise identity and Keychain access configuration as the installed enterprise app. Candidate-to-candidate Keychain equivalence does not prove equivalence after a different enterprise signer is applied.

On return: verify actual hash, enterprise profile/entitlements/signatures, compare executable/resources allowing only signing changes, check continuity with the currently distributed enterprise app, then follow the authorized iOS immutable upload/manifest/app_ios_* publication workflow. Until the returned file passes, keep iOS0.3.96/2134 distribution unchanged. Physical-device weak-network acceptance remains separate from automated tests.

Overall status: [verification](2026-09-19-conversation-identity-admission.md), [task](../workflow/tasks/2026-09-19-conversation-identity-admission.md). Artifact download metadata, verification JSON and CI logs are adjacent to the IPA. iOS18/26 native integration tests are still running at this handover preparation stage; their final status will be recorded before final delivery.
