# R8 cache incremental disk accounting

## Recovery and scope

- Authorization: approved `docs/superpowers/plans/2026-10-11-im-reliability-remediation.md` R8 S8-1/2, parent task's explicit bounded delegation and acceptance of the design on 2026-10-11. Base `82a8eca515b81a8747d2a45ea6992a3b0af8a8d8` already contains the separately reviewed activity budget.
- Owner: `review_media_android`; branch `codex/im-media-cache-index`; tree `C:/Users/Administrator/.codex/worktrees/im-media-budget/StarChat`.
- Owns `media_cache.dart`, new `media_disk_quota_index.dart`, `media_cache_storage_policy.dart`, and their two new tests. Matrix, RoomPage, AppHome and durable outbox remain owned by the durable-media task.
- Status: implementation and focused verification complete; awaiting independent SPEC/domain, then QUALITY/security review. No deployment, package, RSS or device-performance claim.
- Native dependency: integration commit `53bd03f4` supplies `chatflow/media_storage.documentsChatMediaPolicy`. This commit only calls the fixed no-argument method and checks `protected == true && backupExcluded == true`; native compilation/device backup verification belongs to the integration task.
- Next executable step: review the exact commit and input hashes, then cherry-pick onto the integration branch after the activity-budget commit. Shared candidate gates and device checks remain with the parent.

## Problem and delivered behavior

At the base, every store awaited `media_cache.dart:631` quota enforcement. Line 752 called `_accountObjects` (721/727) unconditionally, listing and statting every account object. Lines 767/772 recursively walked all `chat-media`; line 769 added the same object size again for each new logical reference, and concurrent accounting had no common mutation queue.

The new disposable SQLite index contains only account digest, physical object name, byte size and modification time. It reuses the existing pinned sqflite dependency without a lock change. One row per physical object and incremental per-account/device totals replace directory enumeration on ordinary writes. Hashing, decoding, downloads and producer futures run outside the quota mutation queue. Index metadata is never proof of content integrity, permission or decrypted-media authenticity.

Missing/corrupt indexes perform one asynchronous initial scan of `chat-media/v2/<64hex>/objects/<64hex>[.mp4|.mov]`. A valid index survives restart without a directory scan. File mutations have a flushed dirty marker before the file change; interruption before index commit forces reconstruction next process. Metadata-only SQL work is serialized; connections close at the end of each mutation. SQLite unavailability retains process-local accounting and the dirty marker so stale durable rows cannot be trusted later.

Calibration is coalesced, requested after six hours on subsequent cache activity, and can be explicitly requested with `reconcileDiskQuota`. Its directory walk is outside the mutation queue. Revision and account-clear markers merge mutations that happened after the walk began, including stale objects observed before a concurrent clear. Failed/incomplete calibration preserves files and disables index-driven eviction until a successful complete scan; retry is throttled to at least 30 seconds. No incomplete snapshot is saved as zero usage.

Quota eviction rechecks owned directory types, candidate type/size/mtime, pin and active-write protection. Changed candidates are recalibrated, vanished candidates are forgotten, and directory links are not followed. Account soft quota and device hard quota retain their existing values. Same bytes under multiple refs count once; `.mp4` rename is repaired by calibration. Background calibration does not delete files. Explicit GC still reads refs and scans its selected account, with recognized object names only; source and pending-media domains are excluded.

The iOS cache policy is attempted once, coalesces inflight requests and retries only on a later foreground lifecycle after failure. It is not awaited by cache writes. Failure or missing/false readback preserves offline files and does not claim protection. Android makes no call.

## Acceptance and evidence

| ID | Assertion | Evidence |
| --- | --- | --- |
| R8-S8-RED | Warm 13 writes enumerated 13 times, expected zero | `red.log`, exit 1 for intended assertion |
| R8-S8-IO-RED | Unreadable initial directory propagated and leaked an open DB; desired preservation/recovery | `scan-failure-red.log`, exit 1; repaired |
| R8-S8-hot | Warm writes enumerate zero; reused object total stays 3 bytes over eight refs and restart | New quota test, GREEN |
| R8-S8-durable | Real SQLite corrupt file and interrupted write reconstruct actual 49 bytes; later success cannot erase interruption marker | New quota test, GREEN |
| R8-S8-concurrent | Calibration paused after observing an old object while clear/write finishes; stale result does not resurrect it | New quota test, GREEN |
| R8-S8-quota | 24 concurrent stores, 30-byte account/50-byte device limits, active pin and account clear | New quota test, GREEN |
| R8-S8-boundary | Actual directory link toward pending original is not followed; ordinary source/pending sentinels preserved | New quota test, GREEN |
| R8-S8-iOS | Fixed method, exact readback, once/inflight coalescing/resume retry, Android no-op, real store remains available on native failure | New policy test, GREEN; Flutter channel fixture only |

- `regression-green.log`: **134 PASS**, exit 0, final 13-file Flutter run. Includes both new files plus media index phase2, cache clear, content-addressed media, verified proof, download budget, transfer admission, native download, room preview, memory cache, index performance and cache metrics. Invocation: `flutter test --no-pub` with those exact test paths and `--reporter expanded`. The native download test is `test/core/native_media_download_test.dart`.
- `focused-green.log`: **12 PASS**, exit 0; eight quota cases and four native-policy contract cases, including the stronger stale-snapshot interleaving.
- `analyze.log`: `flutter analyze --no-pub`, exit 0, **0 issues**.
- `mobile-boundaries.log`: `python -m pytest tests/mobile/test_flutter_boundaries.py tests/mobile/test_vendored_matrix_dependency.py -q`, **8 PASS**, exit 0.
- Repository policy, deployment policy, TemplateTools logs: all exit 0. `git diff --check` and unchanged `pubspec.lock` comparison passed.
- Tooling: Windows, PowerShell 7 UTF8 without BOM, Flutter 3.44.9 / Dart 3.12.2. Source/lock hashes are in `input-hashes.json`; no credentials or production network calls were used.
- Full `scripts/verify.ps1` was preflighted, not executed: this isolated tree has no `.env` and no local `.venv`; importing production secrets is not appropriate. Focused Python uses the existing primary-tree virtualenv. No new full Flutter suite, native build or real-device backup/RSS result is claimed.
- Expected fixture output: corrupt SQLite prints its synthetic file-is-not-a-database diagnostic; existing MediaIndex tests deliberately exercise unavailable/degraded factories. Initial test harness failures (wrong native test directory; IOOverrides Windows type behavior; open DB teardown) were corrected; final runs are exit 0. Earlier iteration logs remain local. Tracked log whitespace is normalized; exact raw copies are preserved in ignored `raw/`.

## Timing and limits

- Exact exploration start was not captured. Intended RED finished 12:42:15 +08; unreadable-directory RED finished 12:57:06; final regression finished 13:01:30; final analyze finished 13:01:02 on 2026-10-11 (log modification times). Active/tool-wait durations were not separately measured.
- Ordinary writes have zero directory enumeration after initialization. First missing/corrupt-index construction still awaits an asynchronous metadata walk before the first managed write; explicit GC and calibration are intentionally O(number of managed objects). This is not a claim of zero startup work or a fixed device latency.
- The cache quota remains best effort when the cache directory cannot be inspected, files are pinned/inflight, a single keep object exceeds quota, or an external actor changes files. Capacity metadata may remain conservative/stale until calibration. Activity-array budget, decoded-image cache, prepared queued media, native temporary downloads and pending originals are distinct domains; this change does not claim total RSS or all disk files are capped.
- Rollback: revert this commit without deleting media. The additional quota SQLite file is disposable metadata; the previous implementation continues using objects/refs. Pending source files and encryption parameters are unchanged.
