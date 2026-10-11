# Playback after an independent preparation cancels

Parent authorized this bounded correction after backend_review froze review d111a29571c9c5d7ab74abf59560db886bfd2d00. Input implementation is 34d1263ceb53b8f9e3efe703e548aa58de82dd5e. The unchanged reviewer public resolveCachedVideoFile probe reproduces 1 PASS / 1 FAIL: A is canceled while its real store root preparation is held; independently verified B publishes a valid reference, but B's preparePlaybackFile snapshot waits A and inherits A's cancellation. No claim is made that this remaining boundary was introduced by 34d rather than an earlier baseline.

## Correction and limits

Only preparePlaybackFile production code changes. It still snapshots and waits all matching real preparations; each preparation now captures only MediaLoadCanceled. Future.wait retains its non-eager settlement behavior and every other error propagates. Processing cancellation per preparation also prevents an early cancellation from hiding a later filesystem failure. No source/scheduler/budget release timing changes.

The method captures the requesting consumer and global/account epochs, checks them before waiting, after all preparations settle, and after the existing cached lookup. A cancellation is bypassed only if that request is still current and its account/reference or supplied content digest resolves through the existing integrity checks. If no valid file exists, the captured cancellation and stack are rethrown. A canceled requester cannot use B's file, a damaged/missing cache cannot become success, and account/session changes still fail. A real preparation I/O failure is never converted to a cache hit, even when another valid object exists. The existing no-preparation cache-miss FileSystemException remains unchanged.

The object-demand aggregation, per-source reference guards, unique synchronous preparation registration and actual-work byte budgets are unchanged. Matrix, RoomPage, scheduler, quota/native/database factory, Android distribution and iOS tests are untouched.

## Evidence

| Evidence | Exact result |
| --- | --- |
| playback-preparation-red.log | Unchanged reviewer public playback probe on 34d: 1 PASS / 1 FAIL; active B receives A's cancellation. |
| playback-owned-red.log | Seven new boundary cases on 34d: 5 PASS / 2 FAIL. Valid B is incorrectly canceled, and early cancellation hides a later real preparation I/O failure. |
| playback-preparation-green.log | Seven owned boundary cases plus unchanged two-case public playback probe: 9 PASS, exit 0. |
| playback-impact.log | One run of 13 impacted files: 104 PASS, exit 0, including the prior 97 plus all seven new preparation boundaries. |
| playback-analyze.log | Final production and new test file: zero issues, exit 0. |

The seven owned cases are valid published B, canceled playback requester, no published object, same-length object corruption, account clear, global clear and later I/O failure. All use real public load/store/prepare entry points, a held root preparation, bounded waits and real temporary files. The I/O case holds two preparations: A's cancellation settles first while the later real failure remains blocked, and playback plus its 4096-byte remaining reservation must still be pending. The public reviewer probe preserves its strong final cached openRead/Timer barrier and File.open forwarding. Its exact raw SHA-256 is cfea0cd1cb32901d78741a57cfc254e2cd958b45921cd26788915871fb2e25c4 in both source and copied artifact.

Counts overlap and are not summed. After the 104-test run, a test-only brace correction removed one analyzer style notice; the final 9-test and analyzer runs include it. No production or test assertions changed after the 104-test run. playback-impact-timing.json records the full run interval, and playback-input-identities.json binds final inputs/logs and commands with raw and LF-normalized hashes. Negative provider/index fallback diagnostics are intentional existing synthetic fixtures.

Next step: backend_review independently checks SPEC/domain then quality/security for this frozen incremental commit, followed by parent integration. Cherry-pick order remains 44dab -> c3 -> 34d -> this follow-up. No df1b3/iOS test dependency. The isolated branch does not contain root's later shared SQLCipher factory; parent retains integrated full/native/package gates. No device performance, RSS, package or production acceptance is claimed. Reverting only this commit restores 34d's demonstrated playback failure.
