# iOS0.3.98/2137 enterprise re-sign handover

Candidate source: main742bf4ebe7efc5e09defc9ea0340db9bd88d6556, mobile tree identical to Android6aca8636. GitHub signed workflow35449326649 completed successfully; artifact10586613514 SHA25656c8762b9988a460e224c2ddbc73217265cda9976266b434e523d6ad0f104072. Exact downloaded IPA hash matched the CI codesign verification log.

File: `artifacts/2026-09-19/direct-conversation-auto-recovery/ios/ChatFlow-0.3.98-2137-enterprise-resign-candidate.ipa`,60542867 bytes, SHA256 `87bb99bd43a1ee972df90f7347f78a59d45b84adb67e0532e0f3dfe07e93412a`.

Verified: Bundle ID `com.liuhetong.liuhetongMobile`, version0.3.98/build2137, arm64 device executable, iOS16.0+, iPhone/iPad, audio/VoIP/remote-notification background modes, production APNs, get-task-allow=false, cryptid=0, SQLCipher included and loaded before sqlite. Statistics HTML matches source SHA89eab23270dc87ce6fd07715d9abb2606455d94ce1fc16cd56d2deeaeeafb9d5. Candidate Keychain declarations and default application identity match the previous2136 candidate.

This is an App Store signing-channel build for the user's enterprise re-signing, not a published enterprise OTA file. Preserve Bundle ID/version/build and required capabilities. Use the same enterprise identity and Keychain access configuration as the installed enterprise app. Candidate-to-candidate Keychain equivalence does not prove equivalence after a different enterprise signer is applied.

On return: verify the actual new file hash, enterprise profile/entitlements and signatures, compare executable/resources allowing only signing changes, check continuity with the currently distributed enterprise app, then follow the authorized iOS immutable upload/manifest/app_ios_* publication workflow. Until that returned file passes, keep current iOS0.3.96/2134 distribution unchanged. New2137 physical-device and weak-network acceptance is still required; prior incident confirmation concerned the manually repaired pair.

Overall implementation, server/Android release and final CI status: [recovery verification](2026-09-19-direct-conversation-auto-recovery.md), [task](../workflow/tasks/2026-09-19-direct-conversation-auto-recovery.md). Local verification JSON and CI logs are adjacent to the IPA.

Final CI: all three workflows against742bf4eb passed at23:01+08, including iOS18/26 native media and encrypted-history retention after app restart. Root-workspace delivery copy has the identical IPA hash.
