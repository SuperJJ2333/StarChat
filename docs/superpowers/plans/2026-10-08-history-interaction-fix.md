# History Interaction Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore stable message order and bounded, responsive history browsing, keyboard changes and room navigation.

**Architecture:** Keep Matrix canonical timeline order and encrypted local storage. Move persisted ordering to additive indexed metadata with background legacy migration, retain a bounded resident SDK slice and visible presentation window, and rebase Flutter layout and ballistic coordinates together. Implement independent reviewable units; storage and SDK ownership hand off the same timeline file sequentially.

**Tech Stack:** Flutter3.44.9/Dart3.12.2, vendored Matrix SDK, SQLCipher/sqflite_common_ffi, PowerShell7.

**Spec:** [Approved repair scope](../specs/2026-10-08-history-interaction-fix.md), extending [approved investigation step5](2026-10-08-large-history-2204.md).

## Global Constraints

- UI visible initial40/maximum200; SDK resident settled raw events maximum1000 with separately retained pending sends. Persisted history remains complete.
- No O(total retained history) synchronous UI work for normal enter/refresh/keyboard/room switch. One-time legacy conversion must run in a worker and yield bounded database commit batches.
- Preserve Matrix sync authority, stable transaction/event identities, continuous-fragment boundaries, gaps, redaction and context semantics; no timestamp sorting across unknown gaps.
- Preserve E2EE/SQLCipher/key ownership, all existing candidate voice fixes, all finance/API behavior and primary WIP.
- PowerShell7 UTF8 only; temporary verification below this task's docs/verification/artifacts; Flutter/Dart commands serialized through U:/apps/mobile_flutter.
- Source repair/testing authorization is explicit; no new production publication authorization inferred.

## Review Focus

- Retrying before HTTP ACK versus first canonical sync: preserve pending position, canonicalize once.
- Same min/max extents during a fling or held drag: corrected coordinates remain continuous and preserve gesture/velocity.
- Legacy huge JSON during first open with competing sync/room switch: worker conversion does not hold global transaction gate or block UI.
- Live fragment reset while a history lease is active: retain its immutable fragment epoch/continuity, reject stale cursor without silently joining gaps.
- Filtered/system-only pages, redaction/decryption, multi-room logical history and voice continuation: bounded paging advances and preserves reachable history.

## Task 1: Pending retry order

**Files:** controller `apps/mobile_flutter/lib/features/matrix/room_timeline_controller.dart`; test `apps/mobile_flutter/test/features/matrix/automatic_retry_order_test.dart`.
**Interfaces:** existing `_retry(String id, {bool rethrowErrors = true})`; no new API. Preserve original local echo timestamp/txid; dispatch tracing owns attempt time.

- [x] Write regressions `automatic reconnect retains insertion before ACK`, `manual retry retains insertion`, unchanged-refresh control, first-confirmed-sync canonical correction once.
- [x] Run formal RED: automatic/manual fail for actual reorder; two controls pass, exit1.
- [x] Remove retry timestamp replacement; keep delivery-state transition, transport and canonical snapshot merge unchanged.
- [x] Focused GREEN:89PASS exit0; record logs/hashes/tool identity in retry artifacts.
- [x] SPEC then QUALITY acceptance, root fresh diff/hash verification, bounded commit4d086187.

## Task 2: Layout and ballistic coordinate correction

**Files:** `apps/mobile_flutter/lib/features/matrix/timeline_scroll_anchor.dart`; new `apps/mobile_flutter/test/features/matrix/timeline_ballistic_rebase_test.dart`; adjacent existing `timeline_scroll_anchor_test.dart`, `timeline_window_stability_test.dart`, `room_page_anchor_navigation_test.dart`.
**Interfaces:** existing `AnchoredTimelineList` and `ScrollPosition.correctBy(double delta)`. Replace three absolute layout correction sites with `correctBy(target-position.pixels)` when hasPixels. This sets Flutter's new-dimensions flag and rebuilds the current ballistic simulation at instantaneous velocity; do not manually call protected dimension/activity methods or terminate drag.

- [x] Promote equal-extent edge-qualified fling probe to formal test. Assert original anchor immediately preserved and bounded continuous displacement for at least two subsequent16ms ticks while still scrolling; both directions/control extents and held drag covered.
- [x] Run RED and verify actual stale-simulation jump, not fixture/framework errors.
- [x] Change three correction sites and run original test GREEN plus adjacent anchoring/window/navigation regressions.
- [x] Add keyboard/inset and idle-pagination→new gesture race integration during Task5; stale restoration guarded by existing generation.
- [x] Ordered review and root source/evidence verification; commitd9abd7ba after passing10-test expanded gate.

## Task 3: Indexed local order design and implementation handoff

**Design files:** `database_api.dart`, `matrix_sdk_database.dart`, native `sqflite_box.dart`, conditional native/stub order store, `timeline.dart` pinned IDs, `receipts.dart`, narrow preflight call sites `client.dart`/`room.dart`; capability local-search consumer handed to Task4 owner.
**Public design contract:** `prepareTimelineStorage(Iterable<String> roomIds)` outside transaction gates; bounded immutable fragment/epoch snapshot handle and indexed event positions/count. Compatibility full enumeration stays opt-in. Native order `(fragment,epoch,sequence,eventId)` indexed, metadata count/head/tail/revision; additive migration, epochs retained by leases. Snapshot pages <=256 IDs and close/dispose cancellation explicit.

- [x] Design audit writes exact signatures, all hot consumers, transaction overlay/preflight ownership, rollback and native/web fallback to storage-design/README.md; root checks no unbounded hot native fallback or gate deadlock.
- [x] Root freezes an implementation contract appendix before source edits; each test-first slice names exact files/tests in that appendix.
- [x] Implement indexed page/pin/write/count/receipt/preview/search public consumers; true SQLite size tests1k/10k/100k and legacy migration/control-room/close/injected failure.
- [x] Restore recovery continuous-order behavior: independent retained bodies do not append a missing newer head to an older continuous fragment without evidence; normal sync remains authority.
- [x] SPEC then QUALITY acceptance and root fresh focused verification.

## Task 4: Bounded resident timeline and projection handoff

**Design files:** SDK `timeline.dart`/`timeline_chunk.dart`; `matrix_e2ee_client.dart`, `room_timeline_viewport.dart`, logical timeline and adapter interfaces, bounded history source DTO if necessary. Task3 must release shared timeline.dart before Task4 changes.
**Public design contract:** settled raw resident limit1000, source/UI40/200; page older/newer by indexed fragment cursor/anchor and raw work budget, preserve100-row overlap. Per-change source work O(K<=1000); unchanged revisions reuse cached source. Structural/content/send-state/decryption changes all invalidate appropriate presentation.

- [x] Audit exact refill/revision APIs and date/search/multi-source/voice consumers; root freezes appendix and resolves Task3 interfaces.
- [x] Real SDK size regression rejects M-dependent snapshot reads; long bidirectional paging never increases retained settled events past1000 and old history stays reachable on disk.
- [x] Test-first implement resident paging, bounded source projection and revision invalidation; aliases, pending, filtered pages, member notice context and gap/reset controls remain correct.
- [x] SPEC then QUALITY acceptance and root fresh focused verification.

## Task 5: Interaction, aggregate verification and handoff

- [x] Real RoomPage large-history IME show/hide and room switching while paging/sync/fast-fling tests assert responsiveness, source work budgets, stable visible anchors, no lifecycle assertion or stale cross-room result.
- [x] Freeze inputs; focused/shared Flutter full gate, analyze, format, affected Python/mobile boundary and repository policies; preflight verify.ps1 .env before executing. Missing unrelated environment recorded explicitly.
- [x] Related Android native compilation and new SQLCipher exports pass. ADB has no device and user cannot connect USB; runtime/phone-frame and iOS checks remain explicit gaps, with no data or installation changes.
- [x] Final whole-branch SPEC→QUALITY review and source/input/lock/evidence hash closure; primary mirror is verified in final documentation closure.
- [x] Deliver actual candidate source/verification state and remaining device/publication steps; old installed2204 does not contain this repair.

## Execution rulings

This is a scoped restoration authorized by the user's last message. Routine design refinements are recorded in the ledger and do not require another approval. Storage/source subcontracts are frozen before dependent edits because their exact transaction/cursor contracts require the ongoing read-only source audit. Design audit deliverables themselves are checkable tasks, not permission waits.

## Task3 frozen contract — 2026-10-08

[Storage audit's public contract/schema/preflight](../../verification/artifacts/2026-10-08/history-interaction-fix/storage-design/README.md) is adopted with these rulings:

- Exact `DatabaseApi.prepareTimelineStorage`, `openTimelineIdSnapshot`, `getTimelineEventPositions`, `getTimelineEventCount`, handle `next`/`accept`/`dispose` signatures and revision/epoch semantics from that artifact. Query/output/worker ACK/commit pages max256. Legacy compatibility API remains explicitly full-export only.
- A worker never transfers or decodes the whole source on the UI isolate. Ordinary account database uses the same SQLCipher/key policy. Prefer bounded streaming legacy string decoding; larger sources cannot silently fall back to an unbounded UI list. One-time O(N) migration work is recorded separately from ready-room O(logN+P) operations.
- Preflight outside transaction gates; new empty fragments initialize safely inside current atomic batch. Existing direct SDK transactional tests remain compatible for empty/ready stores, with legacy tests explicitly preparing first.
- Snapshot cursor advances only after accepted payload page; revision-visible rows and old epochs survive active snapshot leases. Clear/forget/account-close dispose metadata consistently; failed batch invalidates staged caches and preserves old authority.
- Recovery independently stores bodies/checkpoint without poisoning the continuous fragment when overlap/adjacency is unproven. It cannot invent history timestamps or tokens.
- Storage implementer exclusively owns database_api.dart, matrix_sdk_database.dart, sqflite_box.dart, conditional new timeline-ID/migration-reader files, native compatibility hooks in indexeddb_box.dart, timeline.dart pinned-ID path, receipts.dart, client.dart/room.dart preflight sites, factory migration-reader injection, and matrix_e2ee_client.dart local-search/count path. Root/render do not edit these files until handoff.
- Tests: new `test/features/matrix/indexed_timeline_storage_test.dart` and `timeline_storage_migration_test.dart`; extend existing pinned history/recovery tests only after declaring exact filenames. RED on real legacy full-read/ordering or missing bounded behavior; native real-DB scale1k/10k/100k/+250k, same-batch updates, legacy reopen/close/control-room, sync reset/snapshot and recovery revision conflict. No mocked algorithm-only pass.
- Rollback is an explicit closed-client legacy projection/export with identity/count verification; old binary is not declared transparently compatible with new-only writes. No destructive body/source deletion or journal-mode change.

Task2 root owns only scroll widget/new ballistic test. Task4 design stays read-only until Task3 releases shared SDK/capability files; independent tests/root documentation may proceed. Flutter test lock remains serialized.

## Task4 frozen contract — independent application files first

Adopt [minimum source contract](../../verification/artifacts/2026-10-08/history-interaction-fix/render-design/MINIMUM-CONTRACT.md) with exact `RoomPagedHistorySource.readHistoryPage({RoomHistoryReadCursor? cursor,String? anchorEventId,String? sourceRoomId,required RoomHistoryDirection direction,int rawLimit=64})` and bounded page/cursor DTOs. Storage adds optional `TimelineIdDirection direction=older` to its snapshot open for newer indexed refill; no fabricated remote tokens.

Application implementer owns new `lib/features/matrix/room_paged_history_source.dart`, `matrix_room_timeline_adapter.dart`, `logical_conversation_timeline.dart`, `lib/features/search/room_search_index_pump.dart`, `voice_playback_controller.dart`, `room_page.dart`, controller page forwarding only after completed retry unit, and new bounded projection/consumer tests. SDK `timeline.dart` and capability `matrix_e2ee_client.dart` ownership transfers to this implementer only after storage explicitly releases them; before that all shared source stays read-only.

- Write behavior-first regressions for independent async voice continuation/cancellation and search paging outside the resident slice; actual failing assertions on existing behavior, not undefined-interface compilation errors.
- Add read-only pager DTO/interface and forwarding; catch-up pages do not move visible history. Empty filtered pages advance cursor, gaps stop or explicitly resolve through context, cancel/dispose/account epoch guard after awaits.
- Voice callback accepts FutureOr result, awaits then checks playback generation/current completed ID/manual stop/dispose/call policy; legacy sync callbacks remain compatible.
- Logical multi-source history merges bounded source frontiers preserving existing source attribution and per-fragment order; no silent1000-row truncation of reachable history.
- After SDK ownership handoff, settled resident1000, public presentationRevision invalidation on all meaningful mutations, bidirectional cursor refill and fork clone<=1000; projection skip unchanged stamp and changed O(K<=1000). Selection/hidden/outgoing/member changes invalidate explicitly.
- Tests `bounded_timeline_projection_test.dart`, `room_history_paged_consumers_test.dart`, existing pagination/voice/search tests selected by impact. Actual native1k/10k/100k total history separate from resident raw K; fallback unpersisted fake timelines cannot silently lose bodies just to meet memory assertion.

Independent application implementation may run in parallel with storage only on disjoint owned files; the developer's proactive parallelization requirement overrides the skill's generic serial-implementer advice. Review and Flutter execution remain serialized; shared files require explicit handoff.

## Follow-up ownership and query-budget rulings

After source G1 on2026-10-08 03:15:21–03:15:32+08 (38PASS/1 native resident-cap assertionFAIL), SDK `timeline.dart` transfers exclusively to `implement_resident_sdk`, plus its new `resident_timeline_refill_test.dart`. Application owner retains capability, DTO/adapters/controller, projection/consumer tests and adds `local_hidden_events.dart`, `local_search_id_snapshot.dart`, `local_room_history_search.dart`, `local_room_history_snapshot.dart`. Storage retains database/API/native worker/preflight and Matrix search-ID wrapper. No concurrent same-file edits; all Dart/Flutter commands require the single U lock.

Version-filtered snapshots must bound raw rows before filtering: `TimelineIdPage.rawCount` records consumed raw rows; an empty visible page can still have `hasMore=true`. Consumers accept/advance these pages, budget rawCount, and use explicit continuation rather than visible IDs/length as EOF. `TimelineIdSnapshot.fork` retains the same captured epoch/revision/bounds through an independent lease. Membership invite/join dependencies at a resident boundary must remain sufficient for existing notices; no synthetic inviter or invented remote token.

## Native search and maintenance closure

The storage audit found that current continuous IDs alone omit bodies retained across limited sync and independent recovery. Add a separate retained **search** index covering current, archived and body-only recovery records. Its timestamp ordering follows existing global-search policy and does not claim canonical chat adjacency across gaps. Native `retained_search_store.dart` and conditional stub are storage-owned; existing factory/cooperative/worker/API files remain storage-owned. Lazy same-account SQLCipher worker backfill reads bounded room-prefix body pages, transfers only IDs/timestamps and releases locks before ACK. Future body/recovery updates maintain metadata in the existing atomic transaction. Snapshot/checkpoint freezes version-visible membership and ordering, including unknown timestamps and timestamp corrections; outputs/raw steps max256, cached metadata counts, explicit clear/forget/cancel.

Rollback maintenance stages encrypted legacy JSON in <=256-ID commits. Original legacy rows, event bodies and active indexed authority remain intact on staging failure. The final verified activation necessarily copies one whole legacy-format row in one native transaction; this O(N) step is an explicit exception for a closed-client offline rollback, never normal room/UI work. Verify captured epoch/revision/count and staged count/head/tail before activation.

SDK aggregation remains the existing loaded-window contract used by prior client trimming. Rebuild contributions from resident/pending events once after replacement/trim, deduplicate stable IDs/transaction aliases, release empty target maps and bound the separate event lookup cache. No application caller currently requests full historical reaction/edit materialization; this task does not introduce that feature or its storage backfill. Persisted event bodies remain available through paging. Decryption results apply only to the same retained event instance after await; canceled/evicted instances cannot overwrite a new resident row. Cryptographic algorithms/key policies are unchanged.

Paged voice continuation searches canonically newer records relative to the completed event. Existing timestamp eligibility is retained within that domain; a canonically older record with a future clock is not selected. Each page is bounded and cancellation/call policy is rechecked after awaits. Application owner may extract the existing selection into a directly tested helper.
