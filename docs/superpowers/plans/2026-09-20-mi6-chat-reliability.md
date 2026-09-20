# Mi6 chat reliability implementation plan

**Goal:** repair three reported client regressions and deliver a verified debug package to Mi6 without publication.
**Architecture:** client runtime configuration, persistent outbox independent of view lifetime, evidence-based identity recovery scheduling.
**Tech Stack:** Flutter/Dart, Matrix SDK, business APIs, ADB, fixed Android signing/rebuild.
**Authorization:** user requested these repairs under existing direct-fix authority; no new update popup.

- [x] Red-packet owner: chat_red_packet_sheet.dart and tests. Reproduce hardcoded200 fallback/slow-balance blocking; implement independent authoritative limit loading/retry, preserve financial server rules.
- [x] Outbox owner: room_timeline_controller.dart/sendstatus helpers and tests. Reproduce disposed in-flight completion lost and historical-source falsefailure; persist finalstate without liveview and preserve safe source ownership.
- [x] Root: matrix_home_page.dart, direct_room_directory_convergence.dart, matrix_e2ee_client.dart capability and tests. Reproduce no-sync failed recovery retry and per-peer head-of-line delay; implement bounded automatic scheduling, network/resume/account isolation, incremental convergence; keep strong identity criteria.
- [x] Root: review spec then quality, focused/full Flutter/analyze and relevant verify gate; avoid repeated unchanged gates. Record exact sources/results.
- [x] Root: enumerate Mi6, inspect installed identity, build debug ARM64 with existing HTTPS definitions, Apktool/zipalign/fixed signing/content checks; install preserving data, verify actual installed version/debuggable. No public upload/settings/updatepopup.
- [x] Explain causes and Telegram public approach, qualify WeChat knowledge; final task/evidence/device handoff.

Debug APK completed and verified; Mi6 installation completed with signature/version checks and exact installed-APK hash readback; no uninstall or data clear. No production/update-popup changes. Strong identity requirements preserved; no metadata invented for irrecoverably unclassified rooms.
