# Shared-candidate media regression correction

Base: 9902d35079e9cb051125808a251ae479b06893cb. Worktree: im-media-cache-regression/StarChat, branch codex/im-media-cache-regression. Parent assigned the shared full-gate media failures under approved remediation R7b/R8; the parent owns shared integration, platform and release gates. No Matrix client, RoomPage, quota implementation, native code or deployment was changed.

Review follow-up: the no-late-publication statement below was incomplete at commit 44dabcc9. Independent review reproduced a pre-existing cancellation gap during store preparation, also present at base 9902d350. See [publication-followup.md](publication-followup.md) for the RED, minimal correction, exact publication boundaries and new focused gates. The original run history below is retained, not retroactively relabeled as independent acceptance.

## Failure classification and correction

| Failure | Finding | Correction / retained assertion |
| --- | --- | --- |
| incoming_media_prefetch descriptor case | Stale probe treated every non-null downloadCallback as native joining. The bounded HTTP downloader now also supplies a callback. | Exercise that callback: independent B receives distinct HTTP ciphertext, requests B's URL and never reads native A; exact A receives native ciphertext without another HTTP request. Native IDs remain distinct. No production descriptor/security change. |
| media_audit two memory cases | Test used unawaited loads plus five zero-duration ticks; worker verification had not settled. | Await each actual load and explicit failed attempt; preserve byte/entry LRU, zero charge on failure and successful retry assertions. |
| media_consumer integration | Real regression: cold prefetch reserved all 192 MiB before entering the priority scheduler. Later visible work could not queue, and a returning observer could not join an uncancellable source holding that reservation. | Scheduler priority comes before atomic byte admission. The actual scheduled source owns one scope/budget through decrypt, verify and cache settlement; observer cancellation only removes its lease. Current scheduler consumers and generation fence publication. A later observer can rejoin the same real work. |
| video concurrent store/playback | Real regression: store registered its flight only after worker verification. A simultaneous playback lookup saw no pending store and reported unavailable. Its subsequent unfinished write also polluted the next fixture teardown. | Register the complete preparation Future synchronously, before verification yields; preserve later digest/object deduplication and account-clear waiting. Playback waits the whole store. |
| transfer integrity four cases / video file-count cases | Incremental quota index is a new non-media file. Old generic counts included quota-v1.sqlite as plaintext. | Strict exact path sets now permit the quota database plus independently derived account/content/ref SHA paths only. No arbitrary sqlite/file exclusion: extra files or symlinks fail. Ciphertext corruption still rejects and leaves zero cache bytes and no plaintext objects. |
| two bubble lifecycle cases | Two fixed pumps after source completion did not wait for worker verification. These tests directly use MediaMemoryCache and bypass the scheduler correction. | Start/finish their actual async lifecycle in tester.runAsync; await the surviving/retry Future with a five-second bound before the same two pumps. Keep source call counts, scope isolation, canceled retry and exactly one rendered Image. No extra sleeps or pumps. |

The only scheduler change is public read-only hasConsumers(key), explicitly authorized by parent. Scheduled cold work now holds its existing concurrency slot through verification/cache settlement, so the byte reservation never ends before those phases. Disk hits and already-admitted local outgoing bytes continue to bypass network queuing. Every surviving caller writes its own reference even when joining a source whose original observer has left. Shared source work checks current consumers before source work and before publishing verified results; if all observers leave, its reservation remains until actual I/O settles and it publishes no object. Global/account generation checks and immutable verification remain in place.

## RED and verification

- five-files-red.log: exact base, 20 PASS / 14 FAIL, exit 1. Reproduced real priority/rejoin/playback regressions and stale callback/count/settlement fixtures; all failures retained.
- admission-order-red.log: strengthened assertion isolates the priority root cause. Queued prefetch expected zero active bytes, actual 201326592, exit 1.
- five-files-green-attempt.log: 34 PASS, exit 0 after the initial corrections.
- adjacent.log: 50 PASS / 2 FAIL, exit 1; the remaining failures are the two unadapted lifecycle fixtures above. This run is not described as all passing.
- chain-green.log: 111 PASS, exit 0 for consumer, transfer admission, verified proof, content-addressed encryption, scheduler/scope, preview and media-index/GC tests. Includes the new abandoned-source test proving true-settlement charge and no late cache publication.
- lifecycle-green.log: 7 PASS, exit 0 after actual Future waiting. Final hard timeout was then included in the combined gate below.
- final-impact-green.log: 87 PASS, exit 0 over all six reported files plus download/transfer budget, clear, quota-index/storage-policy and memory suites. Six consumer cases overlap the 111-test command; counts are reported as runs, not summed as unique tests.
- analyze.log: all eight changed executable files, zero issues, exit 0. Exact commands, source SHA256/LF-normalized identities and timestamps are recorded in input-identities.json.

Expected negative-test output includes a deliberately corrupted SQLite database open error and a test-only MediaIndex provider fallback. Those cases pass their recovery assertions; they are not production validation warnings being suppressed. The strict official pub get --offline --enforce-lockfile succeeded and the lockfile is unchanged.

scripts/verify.ps1 preflight found no local .env or .venv; its configuration/backend/full-project steps are outside this isolated correction. Parent explicitly retained shared full-gate ownership and prohibited repeating the full Flutter suite here. No secrets were imported to run that script, and no full verify exit-0, device/RSS or release claim is made. Root's separate Moments FakeAsync investigation is not part of this change.

## Review handoff

Required independent order: SPEC/domain, then quality/security. Inspect full-source lifetime registration, source/observer separation, generation fencing, preserved ADR-0060 verification and bounded byte reservation; verify fixtures assert transport and exact managed files rather than loosening failures. Integrate only this frozen change after review. Roll back this isolated commit to restore base source; no schema, format, protocol or dependency change is introduced.
