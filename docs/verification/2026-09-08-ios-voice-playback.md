# iOS 0.3.53 voice playback regression

User confirmed background calls work. A fresh voice recording creates a message bubble, but both existing and new voice messages fail to play. Recording failure is not established.

USB technical-only capture: `artifacts/2026-09-08/ios-voice/voice-repro-02.log`. AVPlayer reports AVFoundation -11828 / OSStatus -12847 while setting its source, followed by DarwinAudioError and an uncaught asynchronous stream error. No audio contents were retained by the capture.

The locked audioplayers 6.8.1 writes BytesSource into an extensionless temporary file; the app supplies no MIME. The locked Darwin 6.5.0 supports MIME override when provided. The candidate inspects the existing decrypted byte header to supply MP4 or ADTS AAC MIME without trusting older incorrect message metadata. Unknown formats retain automatic detection. It also consumes playback stream errors. No new persistence or network transfer, recording, transcription or CallKit changes.

Test-first evidence (2026-09-08):
- MP4 source expected audio/mp4, got null: failed before implementation.
- ADTS source expected audio/aac, got null: failed before implementation.
- Native completion stream error: uncaught StateError and playing state remained true before implementation.
- Focused source/controller suite: 14 passed after implementation.
- Full Flutter suite: 1337 passed; `artifacts/2026-09-08/ios-voice/flutter-tests.log`.
- Flutter analyze: no issues; `artifacts/2026-09-08/ios-voice/analyze.log`.

Specification review approved the bounded patch. Quality review and repository verification pending. Signed candidate and physical-device playback verification pending; these tests do not establish that the iPad issue is resolved.

Quality/security review approved without blockers. Clean source-only candidate 38a98b7a95509e260eb810a2aed0aa5066e4a5ed contains exactly three Flutter source/test paths and the build workflow, based on reviewed public branch f42a4b060ef8e8fc7d810782634ef9048d511bc9. Build run 34178150800 / job 101911567308 passed Flutter integration and native core tests and entered signed IPA compilation. Candidate device playback remains unverified.

Repository scripts/verify.ps1: Verification: PASS (log artifacts/2026-09-08/ios-voice/repo-verify.log).

Signed build run 34178150800 completed successfully. IPA 0.3.53(59), 58,339,801 bytes, SHA256 9786f97d4778101ac1623468e2ad712b9ae73e397ad7a8677ac976fc3408819e. macOS signature/production APNs/SQLCipher/iPad/background declaration verification succeeded. Local artifact Info.plist version, bundle ID, device family, microphone and background modes rechecked. Upload-only commit a797f28f59efd5bfd41c3d6f3667032b35ff208a pins the successful source run, source SHA and exact IPA SHA. Upload result pending.

Upload completed successfully: run 34178747782, job 101913297206, commit a797f28f59efd5bfd41c3d6f3667032b35ff208a. Both Verify exact reviewed IPA and Upload to App Store Connect for TestFlight steps succeeded. Apple processing / TestFlight visibility and actual iPad old/new voice playback still require user verification. Windows PowerShell HTTPS had intermittent TLS EOF; read-only curl status verification succeeded without bypassing TLS checks or exposing credentials.

User device acceptance: after updating to iOS 0.3.53(59), user confirmed both existing voice messages and newly recorded 3–5 second voice messages are audible. Voice recording/playback incident verified resolved on the test iPad. This confirmation does not establish a new transcription or call regression test.
