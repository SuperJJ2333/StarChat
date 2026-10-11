# Independent incremental review: cache publication and release helpers

Date: 2026-10-11. Reviewer: backend_review (non-author). Own tree: `C:/Users/Administrator/.codex/worktrees/im-media-cache-review/StarChat`.

Reviewed cache commit: `c3c66fbc4e5d779751368f0c9bce03bb5de8fd04`; parent: `44dabcc9d6428e38adfe93f572deeec0c64e8653`. No product code was modified. This review adds only its own report, synthetic probe and evidence. No server, device, installation or release action was performed.

## Stage 1 — SPEC / domain: NOT PASS

The original last-observer late-publication gap is fixed at the exercised boundaries: the unchanged original probe plus five author root/object/reference-flush probes independently pass (7 PASS, exit 0). The held-root cancel-then-rejoin control still uses one real source. The guard preserves captured global/account generations; true source work and its budget survive observer cancellation until settlement. Only the operation's own temporary file is removed. Existing published objects/references are not deleted as cancellation rollback. Rename submission is an appropriate explicit boundary for the uncancellable filesystem operation; it is not described as completion-time cancellation.

One additional acceptance failure blocks this candidate:

### P2 — A canceled source's publication guard rejects another live source sharing its verified object

Location: `apps/mobile_flutter/lib/features/matrix/media_cache.dart:694` (existing object-flight selection), `:699` (awaiting that flight), `:581` (guard before rename), `:1603` (demand bound to the source task key), `:1722` (source Zone capture).

Trigger: within one account, two legacy sources have different event/source identities and no trusted incoming `contentSha256`. They must download/verify independently, but their resulting verified plaintext has the same digest. Source A creates the shared `_objectFlights[objectKey]`; source B later waits on that same object write. Cancel A's last observer after its actual object temporary file has flushed, while B still has a live observer. The new pre-rename guard runs in A's Zone, sees only A's absent consumers, and throws `MediaLoadCanceled`. B inherits this failure through the shared object Future even though B's scope is active and its scheduler still has one consumer.

The independent probe uses actual scheduler, budget, hash worker, filesystem writes and the public load API. A filesystem override holds only the real temporary-file write after flush. B's real account-directory creation after verification schedules a Timer event; `_root.then -> _store -> await _objectFlights` drains in preceding microtasks, so cancellation occurs after B has reached that join. This avoids a fixed-delay assumption. Both distinct decrypt closures run once and both scheduler tasks are active before cancellation. All work settles and budget/active task counts return to zero.

| Same final probe | Result | Exit |
| --- | --- | --- |
| Parent 44dab, no cancellation | PASS; B succeeds | 0 for 2-case run |
| Parent 44dab, cancel A | PASS; B succeeds and object publishes | 0 for 2-case run |
| Candidate c3, no cancellation | PASS; B succeeds | 1 for 2-case run |
| Candidate c3, cancel A | FAIL; B is active but receives MediaLoadCanceled; object absent | 1 for 2-case run |

This is a new c3 regression, unlike the previous late-store gap reproduced on base 9902. It is a bounded correctness failure, not evidence of cross-account disclosure, corrupted plaintext, financial impact, or a production incident. Account-local verified plaintext sharing is permitted by ADR-0060; it does not authorize different encrypted descriptors to share unverified source bytes.

Required correction: a live independent joiner must not inherit another source's loss of publication demand. An implementation may aggregate legitimate demand for the shared object or make a surviving joiner re-register once after the canceled shared write has truly settled. Preserve per-caller generation/demand checks, account/digest isolation, bounded retries, actual-settlement budget ownership, and the no-consumer/no-new-publication tests. Do not turn all failures into retries or remove the guard. Re-run this two-case probe plus the original seven and affected consumer/clear/integrity cases, then request independent incremental review.

No E2EE, authentication, wallet, ledger or server contract was changed in this patch. Synthetic local bytes only; no plaintext left the test process/device filesystem.

## Stage 2 — QUALITY / security: NOT APPROVED for integration

Quality inspection follows the SPEC result and adds no separate security blocker. The above reproducible regression is sufficient to withhold approval; no broad cache redesign is requested. Previous 44dab priority/admission/preparation-lifetime review remains applicable. The narrowed c3 change is otherwise coherent: no delete-before-rename race, unique temporary-file cleanup, clearing-root checks independent of consumer demand, and accounting for already published objects is retained.

The author source/log manifest was checked by normalized SHA for all four source inputs and five archived logs (9 matches). The copied original probe is byte-equivalent after LF normalization to review commit `e339bb6e9971ddecb4a4ea3034a3d268a2ef7fc4`. Existing adjacent 93 PASS and analyzer-zero evidence is reused only for those frozen inputs. The 7-case and 93-case runs overlap and are not summed as unique tests. No full suite or native device evidence is claimed here.

## Release-helper incremental review: PASS within stated scope

Root helper tree: `C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat/docs/verification/artifacts/2026-10-11/im-reliability-release/`.

| File | Reviewed SHA-256 |
| --- | --- |
| build-native-media-fixture.ps1 | 49e6dfecff116c03d96e713ead8211172b4f49003381d45b7b9d074a4d99f8d7 |
| bounded_native_adb_install.py | 463caa433e2b6c0ca2794c6103d3c982dd44314a71bdd471430538439afb6aa1 |
| run_shared_gates_v2.ps1 | 2af87c159f3eaa824b379ef8f7660c2f262fbed46c2e7f06cecad497d5ada7b1 |
| android-arm64/freeze_mobile_input.py | 748e8c2ea22086a50757c2083162cb134a11ba26f299891f75a440783cfbf503 |

SPEC: Gradle system property explicitly sets the isolated debug identity to true, so a prior global false cannot override the project environment setting. Native fixture work targets only `emulator-5558`; package identity/signing/rebuild checks remain before installation. Both existing and retained debug packages are rejected, and install has no `-r`. Python install uses `--no-streaming`, timeout 180 seconds, with bounded state/package probes. A timeout remains uncertain and is not called a rollback. Normal final cleanup requires the installed APK to hash to this run's owned artifact. The helper does not touch emulator-5556.

QUALITY: fresh run directories refuse overwrite; W mapping is released only if this invocation owns it and its current target matches this repo. Shared gates check the manifest's SHA, mobile/generated inputs and HEAD before/after execution, return failures, and retain per-run logs/receipt. This freeze is specifically for mobile inputs; it is not claimed to hash all external tools or non-mobile test scripts. Both PowerShell helpers parse without errors. The owner's four no-ADB mock safety tests and log were read and reused (test SHA and log SHA in review identities). No extra device invocation was needed to check this increment. The bounded installer limits the installation subprocess; the entire build/drive and old preliminary shell ADB reads are not thereby given a global timeout. Source freezing during native work remains the parent's declared responsibility.

Helper PASS does not override the cache NOT PASS and does not authorize release of that cache candidate.

## Evidence identity, timing and next step

Owned artifacts: `docs/verification/artifacts/2026-10-11/im-media-cache-independent-review/`.

- `cross-source-object-cancel_test.dart`: independent synthetic cross-source control and cancellation probe.
- `c3-publication-7-rerun.log`: independently rerun original/new publication probes, 7 PASS, exit 0.
- `c3-cross-source-object-cancel-rerun.log`: final compiled probe, 1 PASS / 1 FAIL, exit 1.
- `44dab-cross-source-object-cancel.log`: identical final probe, 2 PASS, exit 0.
- `c3-review-identities.json`: reviewed inputs, hashes, log timestamps, helper hashes and exact result boundaries.

The first 7-case invocation used the repository root instead of the Flutter package and exited before tests; the first new probe had a nullable test-harness compile error. Neither is defect evidence. The retained rerun logs above are the definitive comparisons. Review-stage command wall times: 7-case run 7.47 seconds; candidate two-case run 8.48 seconds; parent comparison including checkout/restore 5.74 seconds. All tests run from `apps/mobile_flutter` with Flutter 3.44.9 / Dart 3.12.2 and the existing Windows native DLL fixtures. Negative MediaIndex provider fallback output is the deliberate existing test fixture, not a newly ignored product failure.

Next executable step: author corrects only the shared publication ownership regression, demonstrates the unchanged independent two-case probe GREEN and retains the original seven checks; freeze the incremental commit for SPEC/domain then QUALITY re-review. Parent may proceed with the independently approved fixture helper while keeping c3 out of integration/release. No further production query, full-suite duplicate run, or deployment is needed for this review.
