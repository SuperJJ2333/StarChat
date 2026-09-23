# Input responsiveness Implementation Plan

> Execute inline with superpowers:executing-plans. User approved the preceding diagnosis and solution; do not repeat approval.

**Goal:** Reduce synchronous indexing work competing with chat input and prevent dropped index batches.
**Architecture:** Budgeted in-memory index pump; ID map + ordered tree for index writes; reuse timeline projections. No protocol/storage schema changes.
**Tech Stack:** Dart/Flutter, flutter_test fake clock, existing encrypted Matrix history source.

## Ownership and baseline

Worktree .worktrees/input-jank, branch codex/input-jank, main 1baaf36e plus copied prior mobile optimizations. Own room_page.dart, new room_search_index_pump.dart, global_search_index.dart, logical_conversation_timeline.dart and corresponding search/timeline/composer tests; this spec, plan, task and evidence. Preserve prior dirty files. No APK/deployment in this source-fix batch.

## 1. Establish regression evidence
- [x] Run existing incremental-index and composer isolation tests unchanged.
- [x] Add continuous batch/content replacement tests and budgeted pump tests. Run `flutter test --no-pub test/features/search/room_search_index_pump_test.dart test/features/search/bug_e1_search_index_incremental_test.dart` and record intended failures.

## 2. Implement indexing
- [x] Implement pump with `request(Iterable<RoomMessageViewModel> priority)`, captured account validity callback, lazy full-source callback, batches of64 and2ms target, event-loop yields; commit each successful batch before caching observations. Keep failed work for retry, cancel on dispose/epoch change.
- [x] Integrate via RoomPage `_recordGlobalSearchIndex` and dispose; remove old cancel-and-replace Timer path. Preserve sender/source metadata and local-only boundaries.
- [x] Replace index full-list dedupe/sort on ingestion with keyed updates plus timestamp/ID ordering; bounded oldest eviction; removals consistent across indexes.
- [x] Run targeted tests, verify late decryption/content updates and no lost batches.

## 3. Timeline and input verification
- [x] Add count-based regression for unchanged/single-source projection merge work, implement safe reuse if contract allows (no speculative caching of mutable SDK objects).
- [x] Test composing/focus during simulated update bursts with real room widget fixture where available. Preserve controller identity and existing local refresh behavior.

## 4. Final gates and integration
- [x] Run search/matrix/performance/composer affected tests and analyze; inspect verify.ps1 prerequisites and apply documented impact/evidence reuse (backend unchanged).
- [x] Run final Flutter shared full suite. Spec review then fresh quality/security review, fix relevant findings.
- [x] Compare baseline hashes before copying owned changes back; keep other optimizations. Write evidence SHA/tool versions, exact results and limitations, update current-state/task.

执行裁定：不直接返回单源可变List；以增量排序+线性合并保留语义，O(N)扫描仍需真机评估。仅源代码与验证完成，真机性能测量/新APK为下一交付阶段。完整证据见verification/2026-09-23-input-jank-fix.md。
