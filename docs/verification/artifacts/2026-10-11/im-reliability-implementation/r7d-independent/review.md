# R7d independent SPEC → QUALITY review

Reviewed commit: `b888e282c0deca3945ffd57bed5499ac2a68a5be` (four changed files). Reviewer `/root/fix_scheduler_r6`; author `/root`. Review date 2026-10-11. No shared production source edited.

## SPEC — PASS

Static specification review completed before the independent execution checks. This approval applies to the explicitly assigned bounded legacy-membership accelerator change, not completion of every R7d performance/metadata goal.

- The retained SQLCipher source, canonical epoch, migration and rollback projection remain authoritative and unchanged. The new table is an encrypted, rebuildable sidecar accelerator.
- Complete global Bloom coverage and same-source block coverage are required before block exclusion. Coverage checks require each 2048-byte block's expected item count, contiguous ordinal range and total block count. Missing, truncated or partial blocks fall back to exact source scanning.
- Cold membership scanning builds complete 1024-ID blocks without forcing an early successful lookup to finish the entire history. Full-source exhaustion alone publishes global Bloom completion. An interrupted partial build cannot establish absence.
- Warm block iteration is ascending and exact matches use `putIfAbsent`, preserving the first occurrence of duplicate IDs. Body plaintext and keys are not returned or logged. New diagnostics contain only the number of source IDs read.
- First cold unknown lookup remains O(N), adds block-building work, and mention metadata is not compacted. The implementation report states these limits; this approval does not claim a fixed total-memory bound or a mobile latency SLO.

## QUALITY / SECURITY — PASS

No blocking findings on the frozen diff. Source-generation checks fence the complete scan, candidate blocks and final publication. The cache identity includes encrypted-file header identity, source row/revision, user and device. Cache cleanup only removes bounded obsolete accelerator rows. Worker cancellation is checked between bounded work units; the public wrapper also rejects a cancelled result.

Seven additional independent real-SQLCipher cases passed against a verbatim Git snapshot of the reviewed reader:

1. Duplicate IDs in different blocks return the first ordinal; UTF-8, quote and backslash IDs at 1023/1024 boundaries retain exact byte-offset behavior.
2. Forcing global and block Bloom bits to all positive still returns only exact source matches, never false membership.
3. Truncating a block to two bytes falls back and finds the real tail ID.
4. Altering the last block's item count falls back and finds the real tail ID.
5. Removing a global Bloom part falls back and finds the real tail ID.
6. A same-length source rewrite rejects the stale generation, finds the new ID under the new identity and does not return the removed ID.
7. Cancellation after warm-index creation rejects the lookup, and a subsequent lookup still finds the tail correctly.

The author's million-ID fixture was rerun against the same exact reader: cold 10090ms, warm 320ms, warm exact source reads 2624, missing-block fallback correct. Combined independent command: **8 PASS, exit 0**, 22s reported test duration. Timing is a single Windows sample, not a mobile claim.

## Evidence identity and execution

- `snapshot-hashes.json` records reviewed Git blob IDs, exact file SHA-256 values and SHA-256 of copied author evidence. The three reviewed Dart file hashes exactly match `r7d-input-hashes.json`.
- The author test copy changes only its import to this local exact reader snapshot and its fixture directory to this review artifact directory; `legacy_membership_blocks_test.dart` preserves the original committed test. Added cases are `independent_membership_test.dart`.
- `independent-run.log`: command below, exit 0. Test fixtures were created and removed only inside this review's `fixtures` directory.
- Verified the SQLCipher DLL SHA-256 `7a1c979c4c64437280a3c50d6b906388beafd0f3c0772494e72de9a7a0bef1da`, matching the author's manifest. PATH change was process-local.
- Reviewer worktree SDK subtree and `pubspec.lock` have no Git diff from the reviewed commit. Lock SHA-256 is `a43833c8e7c3d6faa93d21babdc61dfe4b3563c7ac00912006f26daa8e0ecc5d`.
- Author evidence reused on verified matching inputs: `r7d-red-behavior.txt` (1M-read warm RED), `r7d-green.txt`, `r7d-adjacent.txt` (43 PASS, including migration, same-size source rewrite, epoch, cancellation and rollback), `r7d-analyze-final.txt` (no issues). Initial missing-DLL and style-failure logs are retained separately; neither is called passing evidence.
- `git diff --check b888e282^ b888e282` passed. No full application rebuild or native-device gate repeated in this bounded review.

From `apps/mobile_flutter`, PowerShell 7 UTF-8 with the verified SQLCipher directory prepended to PATH:

```text
flutter test --no-pub ../../docs/verification/artifacts/2026-10-11/im-mention-pages/r7d-review/independent_membership_test.dart ../../docs/verification/artifacts/2026-10-11/im-mention-pages/r7d-review/author_membership_test.dart --reporter expanded
```

The root task retains final integrated-candidate and Android/iOS performance verification responsibilities. No deployment was performed.
