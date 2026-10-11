# R8 cache index independent review

Reviewed c3050684c07f955b0e9f449e909cea05ec36786e and follow-up
896e8e77fc3ed20098b6eebb4a4fd287bba7aa48, integrated as 43acaaca/f87f72cc.
Reviewer: root, independently of the cache implementer. Read the full index,
native policy caller, cache mutation/eviction integration and both new test files.

SPEC/domain review: initially changes required. A failed background scan left a
previous complete index eligible for eviction, contrary to the intended fallback.
The follow-up has a real initialized-index RED, disables eviction and leaves a
durable dirty marker on failure, preserves files/counts and restores eligibility
only after complete reconciliation. Final SPEC/domain PASS for the bounded scope.
Objects count once across references; normal warm writes avoid directory walks;
account/device accounting is serialized; calibration merges revisions and account
clear without resurrection. Pending originals are outside the managed object domain.

Subsequent QUALITY/security review: PASS. Durable rows carry only digest names,
size and timestamps; they never authorize decryption or replace content validation.
Eviction checks fixed managed parents, no-follow type, current size/mtime, pins,
active writes and the current keep object. Corruption/crash rebuild targets only
the disposable fixed index. Calibration is coalesced and runs its scan outside the
mutation queue. iOS failure preserves cache files and retries on foreground; no
Android channel call is introduced. No network, keys, tokens or message plaintext
are added to the capacity index.

Independent integrated execution: `flutter test --no-pub
test/features/matrix/media_disk_quota_index_test.dart
test/features/matrix/media_cache_storage_policy_test.dart --reporter expanded`:
**13 PASS, exit 0**, r8-cache-independent.txt. The printed SQLite-corrupt diagnostic
comes from the deliberate corrupt-file fixture. Author's 134 earlier regression
and 42 follow-up adjacent results/analyze are separately retained, not counted as
independent executions.

Limits: first absent/corrupt index still scans asynchronously before the first
managed write. SQLite metadata and the in-memory object catalog grow with managed
object count; this is not a total RSS bound. Quotas are best effort for pinned,
inflight, overlarge keep objects, unreadable roots and external changes. Periodic
calibration requires subsequent app activity. Unknown/source/legacy files outside
the fixed v2 object pattern are preserved and are not included in its byte total;
this total is not whole-application disk usage. The index is not an atomic security
boundary against malicious same-process filesystem replacement. iOS actual native
readback/backup and device performance remain separate gates.
