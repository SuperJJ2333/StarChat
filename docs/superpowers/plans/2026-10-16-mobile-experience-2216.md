# Mobile Experience 2216 Implementation Plan

> **For agentic workers:** Use subagent-driven-development task-by-task with independent specification then quality review. The user has already approved the proposed design and requested execution.

**Goal:** Implement all five approved 2215 experience fixes and verify a preserved-data emulator Debug upgrade.
**Architecture:** Reuse existing encrypted caches, bounded Matrix windows and durable media outboxes; repair lifecycle/paint/permission seams instead of introducing another authoritative store.
**Tech Stack:** Flutter3.44.9/Dart3.12.2, Android native APIs, Swift/iOS16+, Matrix local fork, HTML catalog.
**Spec:** ../specs/2026-10-16-mobile-experience-2216-design.md

## User-approved follow-up: visible super emoji autoplay (2026-10-16)
The latest user request supersedes Task2's static-by-default choice for message rows. Restore default visible autoplay without removing immediate SVG/Unicode fallback or existing shared bounded decoding, offscreen/background suspension and pressure cleanup. Keep the explicit tap mode available to other callers. Own a separate task/evidence record; reproduce the no-tap resource request regression, verify frame progression and lifecycle, synchronize the HTML demo, review specification then quality, rebuild/install the preserved-data Android Debug candidate and report measured memory limits. Do not present the old unsigned IPA as containing this fix.

## Global Constraints
- Preserve account isolation, E2EE, installation continuity, authentication, stable txid and durable recovery. No unapproved authentication bypass, no DB destructive migration.
- Candidate0.4.47+2216 subject to build preflight; preserve installed Debug package/signature and data. Debug APK follows conventional rebuild/signing workflow.
- All evidence/briefs/ledger under docs/verification/artifacts/2026-10-16/mobile-experience-2216; PowerShell7 UTF8 only. This repository rule overrides skill bash/.superpowers scratch paths.
- Execute tasks sequentially; one writer per file. Root owns final integration, docs, HTML registry/demo and builds. Agents may not spawn other agents or run full suites/builds concurrently.

## Review Focus
1. User defers permission or startup interrupted: later explicit request remains possible (Task1).
2. Account switched while cached/media work finishes: no cross-account paint or mutation (Tasks2–4).
3. Lost ACK/cancel/retry/restart: same txid, discoverable tasks, no duplicates (Task3).
4. Missing GIF preview/iCloud asset/pressure: nonblank fallback, bounded memory (Tasks2–3).
5. Revoked credentials/locked keychain/old-history anchor: no auth bypass, data loss, forced jump (Task4).

### Task 1: Contextual permissions
Files: app_home.dart notification prompt integration; core/notification/system_notification_presenter.dart; new focused permission state helper as needed; features/matrix/call_permissions.dart and actual permission UX callers if gaps proven; matching unit/widget tests. No room_page.dart edits without root coordination.
- [x] Reproduce premature prompted_v2 persistence and default Darwin auto-request with failing tests.
- [x] Separate initialization from request; full native notification status; serialized foreground contextual requests, defer vs deny vs API error, setting return refresh and explicit reentry.
- [x] Verify mic/camera request callers and provide actionable denied guidance through existing gateways without unrelated prompts.
- [x] Focused green tests/analyze touched sources; report exact cases and limitations; spec then quality review.

### Task 2: Nonblank persistent media previews
Files: ui/chat/emoji_resource_glyph.dart, super_emoji_message.dart, shared_emoji_image/player as needed; features/matrix/emoji_preview_cache.dart and preview integration helper; targeted tests. Root coordinates room_page.dart changes.
- [x] RED pending emoji blank, static-first behavior and repeated preview load tests.
- [x] Immediate SVG/Unicode fallback; chat super emoji static by default with real tap playback; GIF first-frame local encrypted cache path, stable namespace and bounded read/decode queue.
- [x] Verify cold/warm/offline/corrupt/dispose/pressure, no flash-media exposure; focused tests and review.

### Task 3: Durable optimistic outgoing media
Files: room_page.dart, room_timeline_controller.dart, media_outbox_pending_view.dart, media_outbox_store/recovery/sender and outgoing video models as needed; unit/widget/native integration tests.
- [x] RED selected image/video thumbnail missing at send and restart task discoverability.
- [x] Add stable preview identity and phase projection; reuse gallery thumb/poster immediately; native extract only if missing. Persist bounded encrypted previews with durable tasks and restore rows; same txid/event mapping.
- [x] Replace pending bar only once retry/cancel/restart are available inside rows; no blank normal-path previews; distinct acquiring/upload/ACK states and preserved ordering.
- [x] Verify delayed preparation, offline, ACK race, cancel, restart, account switch and capacity; review.

### Task 4: Startup and history first paint
Files: main.dart, session_gate.dart, installation_startup_gate.dart, session bootstrap only within existing auth contract; room_page/timeline/Matrix local storage hooks as evidence requires; performance traces and tests.
- [x] Instrument phase timings and reproduce cache waiting/blank room with delayed dependencies.
- [x] Defer optional work; stable cached shell and safely scrollable preview; necessary identity/key/migration checks retained. Local first read30 / UI cap40 before optional indexes/history; keep prior content and meaningful loading/retry state.
- [x] Avoid full history scans in initial path; page30–50, max200 models, event anchor retention; cancel stale leases.
- [x] Focused failure/weak-network/large-history tests and review; no fake cache hit claims.

### Task 5: Integration, native verification and delivery
Root-owned: HTML catalog/registry/tests, task record/current-state, pubspec version, CI diagnostic targets and build artifacts.
- [x] Mirror changed states/controls in HTML demo; UI contract and affected frontend tests.
- [x] Focused tests then one final Flutter full/analyze/boundaries; preflight verify.ps1 environment and record missing prerequisites without borrowing production secrets.
- [x] Recheck APNs production identity safely. Do not replace credentials/topic with guesses. Record real device/signing dependency if absent.
- [x] Build2216 Debug, conventional rebuild/fixed signer, verify and install-r; actual9JPEG+GIF+MP4 send/11uniqueACK/coldreentry/video and syntheticnative5casegate. FinalmainAPK restored; account/data preserved. Debug metrics recorded without real bodies.
- [ ] Complete actual offline/weak-network and Release/Profile timing matrix; one LDPlayer network-toggle probe hung, recovered with data preserved, no offlinePASS.
- [x] Run iOS existing CI: unsigned deviceIPA PASS; 21nativePASS/2protectedoutboxERROR; independent policy4PASS/4capabilitySKIP confirms Simulator limitation. Final code spec/qualityreviews complete, originalerrors/rollback recorded.
- [ ] Matching HY9Q7Q35S5 signature and realiPhone permission/APNs/background/locked/cross-Team upgrade/protectedoutbox success acceptance; no simulator substitution.

Integration evidence clarification (2026-10-16 08:11+08): shared full executed, retained exit1/6035PASS/2fixtureERROR/9SKIP; final fixture-only18PASS plus unchanged-input reuse closes affected cases, not a rewritten all-green command. verify.ps1 missing.env remains explicitly incomplete. Android actual-main11synthetic media ACK after cold restart, video playback, UID/firstInstall retained. Dedicated native5case aggregate27b00b9f is being rebuilt/run after host/live-binding separation. iOS IPA built and verified; native21PASS/2ERROR, same-runtime policy4PASS/4capabilitySKIP; signed real-device gates stillpending.
