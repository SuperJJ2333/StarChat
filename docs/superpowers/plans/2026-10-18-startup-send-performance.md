# Startup and send performance implementation plan

> **For agentic workers:** Execute inline using executing-plans; root is the sole product writer. Request independent SPEC then QUALITY/security reviews before delivery.

**Goal:** Implement the four performance changes explicitly approved by the user on 2026-10-18, preserving cache-first interaction and durable/encrypted delivery.
**Architecture:** Extend existing closed diagnostic counters, retain isolated identity snapshots with fewer whole-file passes, coalesce optional cache work and reuse freshly rebuilt room heads, and bound existing outbound-session loading to prioritized rooms. No new server or storage schema.
**Tech stack:** Existing Flutter/Dart, vendored Matrix, SQLCipher, Android fixed-signature rebuild.
**Spec:** User's four numbered instructions; existing approved startup projection ADR plus `docs/adr/2026-10-18-startup-send-io-performance.md`.

## Constraints and ownership

Root owns: `core/performance_metrics.dart`, `features/matrix/local_identity_preflight.dart`, new `identity_snapshot_io.dart`, `matrix_e2ee_client.dart`, new optional-work/warmup helpers if needed; SDK `src/utils/send_timing.dart`, `matrix.dart`, `src/room.dart`, `encryption/encryption.dart`, `encryption/key_manager.dart`; corresponding tests, this plan/ADR/task/evidence. No concurrent product writers. Reuse worktree interactive-cache-startup, baseline1c403352. Formal distribution remains2216.
Keep whole-content verification, read-only isolated snapshot, wrong identity/key rejection, E2EE rotation and per-message session persistence, privacy invalidation-before-apply, same transaction retry, exact owner cancellation. No plaintext/keys/IDs in timings.

## Tasks and acceptance

- [ ] 1. RED then GREEN: closed `MatrixSendTiming` observer with durations for before/after local sync, queue, session load/check/create, encrypt, session persist and HTTP API. App maps enum to bounded PerformanceOperation samples; identity phase durations separately record copy/hash/open/read/fingerprint. Disabled/throwing observers do not alter operation results. No new diagnostic strings or data.
- [ ] 2. RED then GREEN: stream-copy and hash source in one pass, still hash copied snapshot and rehash original after inspection. Verify missing/added/changed sidecars, symlinks, mid-copy mutation, corruption, wrong key/identity and temp cleanup. Test byte-read budget proves 4→3 full read passes, bounded memory; original files unchanged.
- [ ] 3. RED then GREEN: skip repeated durable head invalidations only while same coordinator already knows head invalid, reset conservatively before any head commit. Never skip privacy pending targets or a failed invalidation. Coalesce optional capture calls; settled sync supplies changed room IDs to prioritize within existing current/top40 coverage. Capture first, then repair only missing fresh heads; preserve full repair if capture is absent/fails. Global invalidation does not permit reviving unchanged rooms' old permits: retain bounded global encrypted-envelope generation. Local echo stays durable; no direct cross-module DB writes or skipped sync delivery notifications.
- [ ] 4. RED then GREEN: after complete verified initialization, preload existing outbound sessions only, current room first then existing pinned/draft/recent ranking, maximum8 rooms/one worker. Current-room request supersedes remaining background work; hidden/left/nonencrypted rooms excluded. No session creation, sharing, encryption or ratchet advancement during preload. Fix/join per-room load flight so concurrent send never observes a prematurely loaded marker or overwrites newer in-memory session; revoke/clear/identity replacement discards late result.
- [ ] 5. SPEC then QUALITY/security review, focused tests, freeze once. Preflight native DLL/tool hashes and run final shared full/analyze once for unchanged candidate. Native delayed-recovery/scroll/outbox/identity/privacy tests plus targeted new I/O/send/preload tests. Reserve next free Debug version only before packaging; conventional rebuild/fixed signer/verified install-r. Compare real test-group samples to2222 with same timing scope, include all failures and control overhead. Existing user authorization permits test-group messages; no formal release.

## Review focus

Mid-copy ABA/change versus final byte consistency; commit partial failure and privacy target saturation; two concurrent sends/preload versus session ratchet; account suspend/room replacement during optional work; long/offline sends still retain local queue and actionable cache miss fallback. Root records rulings and exact test/artifact identities in the task ledger; no invented speed target.
