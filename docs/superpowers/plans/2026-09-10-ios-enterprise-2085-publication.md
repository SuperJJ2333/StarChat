# iOS 2085 enterprise publication

User authorization: enterprise signing returned; publish the iOS popup and automatic download transition. Continuation of approved platform-release-2085 plan. Uses the existing deployment, brainstorming and writing-plans workflows; no new product decision is required.

Owned files: frontend/download.html, frontend/src/download-redirect.js, frontend/src/admin-home.js (only iOS labels), frontend/tests/download-redirect.test.mjs, frontend/tests/home-ios-download.test.mjs and this release's verification report. Preserve unrelated work.

- [ ] Verify returned enterprise 0.3.81/2085 identity, provisioning, resources and signing-channel parity with 2073.
- [ ] Add failing automatic routing tests. Implement a fixed-destination, device-aware bridge: iOS/iPadOS -> OTA; Android -> existing APK; desktop/unknown -> manual choices. Explicit platform mismatch must not auto-launch another OS's package. Retain a manual button when a browser blocks automatic launch.
- [ ] Freeze live files, current images and settings. Upload immutable IPA in sequential resumable 16 MiB chunks and verify SHA256 before installation.
- [ ] Publish manifest and changed static files with drift checks/backups. iOS URL is /download?platform=ios&install=1. Legacy shared URL is /download?install=1; retain Android version/build/minimum/package. Legacy iOS 2073 sees the historical 2084 version label but is routed to iOS 2085; after upgrading it uses independent iOS settings. Do not pretend old binaries can request platform-specific metadata.
- [ ] Publish iOS settings through SettingService with audit and independent readback; update only legacy URL as a separate audited transition. Keep minimum support unchanged. Do not deploy an unrelated backend image.
- [ ] Run focused frontend tests and existing frontend suite, specification then quality review, server/workstation HTTPS hash/range/manifest checks, settings projection checks. Record actual iPhone install/audio/relogin acceptance as pending until device feedback.

Rollback: restore backed-up static files and settings through the same audited service, retain immutable IPA and existing Android artifact. Never delete application data.
