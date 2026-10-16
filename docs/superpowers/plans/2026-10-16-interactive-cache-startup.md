# Interactive Cache Startup Implementation Plan

> Use subagent-driven-development task by task, with specification then quality review. User approved the concrete chat design and instructed implementation on 2026-10-16; proceed without another design approval.

**Goal:** Existing-account cold startup and room entry show actual cached content and allow navigation, scrolling and durable pending sends during recovery; deliver preserved-data emulator Debug.
**Architecture:** Reuse encrypted account stores, existing local identity eligibility, bounded timeline snapshots and persistent outbox. Separate usable local UI from optional recovery work. Never bypass identity, storage, membership or sending permissions.
**Tech Stack:** Flutter/Dart, local Matrix SDK, SQLCipher, Android.
**Spec:** User-approved chat design, captured in docs/workflow/tasks/2026-10-16-interactive-cache-startup.md.

## Constraints and review focus
- Scope includes local client changes and emulator install-r only; no public release, account reset or signing change.
- Identity/key/installation checks still precede account access. Missing/corrupt cache has honest failure/empty state.
- Cache account changes, logout/revocation, delayed futures and route disposal must reject stale results.
- Scroll anchor and pending txid survive live handoff; no duplicate send or fake sent state.
- Input is available once durable local storage is ready; actual dispatch waits for existing live permission/E2EE capability.
- No plaintext cache fallback, destructive migrations or new authentication contract.
- Root owns documents/version/build; one product writer at a time. Evidence under docs/verification/artifacts/2026-10-16/interactive-cache-startup.

## Task 1: Room first paint and local send readiness
Files: apps/mobile_flutter/lib/features/matrix/room_page.dart, room_timeline_controller.dart and related room lease/local snapshot/outbox public interfaces only as required; matching tests.
- [x] Establish focused baseline, then RED: retained local bubbles visible while full timeline future held; scroll works; send accepted durably without awaiting optional history; late hydration preserves anchor and pending txid.
- [x] Reuse encrypted bounded cache/head (initial30–40, max200 UI models) and existing outbox, expose minimal local-ready API where necessary; live hydration merges without clearing the subtree.
- [x] GREEN with revoked/disposed/hidden/cleared-history/account isolation and duplicate ACK coverage. Run focused analyze. Commit exact owned files.
- [x] Independent specification then quality review, fix covered findings.
Interface: existing RoomPage/RoomLease entry remains source-compatible. If early navigation requires a deferred lease API, document the exact public interface for Task2. Do not alter AppHome/main/session gate in Task1.

## Task 2: Cold startup and interactive home
Files: main.dart, installation_startup_gate.dart, session_gate.dart, app_home.dart, matrix_home_page.dart; startup factory/local restore only when necessary and within existing security contract; matching tests.
- [x] RED held optional startup/Matrix resources: valid local account can switch tabs and open cached room; read-only preview never upgrades before existing local safety checks.
- [x] Minimize pre-shell blocking work, preserve necessary installation/key/account checks; mount stable navigable home from eligible local state; room uses Task1 local readiness and existing live dispatch gate.
- [x] GREEN logout/account switch/late completion/first install/no cache; preserve routes and scroll at live handoff. Analyze and commit.
- [x] Specification then quality review.

## Task 3: Integration and Debug delivery
Root files: docs, pubspec/AppConfig version as needed, relevant HTML parity if UI skill requires it, build evidence.
- [x] Verify final scope and security, focused plus shared full Flutter/analyze; preflight verify.ps1, reuse unchanged inputs only with evidence.
- [x] Whole branch independent review before build, resolve blocking findings with tests.
- [x] Check installed version/signature, use new build greater than2217 and unused version at freeze, emulator ABI, fixed75b31 signer and Apktool2.12.1/build-tools36 rebuild. Verify semantic/asset/manifest/signature output.
- [x] adb install-r, compare UID/firstInstallTime, launch passive smoke. Do not send messages to other people. User owns manual interaction testing.
- [x] Record exact artifact/version/hash, commands/results, timing and remaining true-device limitations; update primary task entry.
