# R9b-2 deployment QUALITY/security review

Verdict: PASS for frozen script implementation `77ca608c7d98a147a2af4d657c2cb8c82be9e495` and final preparation/evidence commit `41e878449186294df9cf14b4236c3561cf470436`, after SPEC/domain review. The sole independent evidence-identity finding was corrected and reverified. No unresolved blocker found in the checked preparation and recovery boundaries; no deployment PASS is asserted.

## Independent execution

All commands used PowerShell 7, UTF-8 without BOM, Python 3.12 with PYTHONUTF8/PYTHONIOENCODING, and PYTHONDONTWRITEBYTECODE. The exact export command is `py -3.12 <this-directory>/freeze_inputs.py`. The frozen release modules were never imported; tests compile selected real AST bodies with inert Docker/SSH/signals and synthetic local temporary files.

| Evidence | Actual command after the directory prefix | Result |
| --- | --- | --- |
| author-replay.log | `py -3.12 -m pytest -q -p no:cacheprovider <this-directory>/frozen/test_release_boundaries.py --basetemp <this-directory>/pytest-author` | 15 PASS, exit 0, 1.17 s |
| independent-unknown.json | `py -3.12 <this-directory>/test_unknown_boundaries.py` | 11 PASS, exit 0 |
| independent-edges.log | `py -3.12 -m pytest -q -p no:cacheprovider <this-directory>/test_independent_release_edges.py --basetemp <this-directory>/pytest-independent` | 9 PASS, exit 0, 1.01 s |

These are 35 local cases, not an additional image/PG suite. Fifteen are independent re-execution of author cases, eleven reuse the earlier independent UNKNOWN harness with the new exact script identity, and nine are newly written review cases. Author-reported counts are not added again.

## Checked failure boundaries

- ABSENT is emitted only for FileNotFoundError from lstat. Permission errors, other I/O errors, directories and nonregular objects fail. Candidate hashes and rollback old hashes use the same helper. A leftover lease module after rollback is rejected rather than accepted as absent; a mismatched installed Consumer is rejected even if source Consumer is correct.
- Each of the five old-runtime drift cases aborts the actual preparation body before any candidate build. Payloads and four baseline hashes are independently compared with the named product Git commits. Candidate/rollback Compose equivalence and worker-only build/switch are asserted.
- Guard execution is a separate owned process session, bounded at 480 seconds with bounded process-group cleanup. Timeout, cleanup failure, unexpected wait failure and nonzero exit all remain UncertainSwitch; no automatic rollback races an uncertain daemon-side operation. A settled successful guard followed by postcondition failure invokes guarded rollback. Ambiguous rollback remains FAILED and cannot acquire rolled_back=true.
- Before cutover, exact live container/image, all preserved runtime settings, Compose source hashes, guard/probe hashes, old source/ABSENT and schema/HTTPS readiness are rechecked. The actual image receipt must have both successful checks and cleanup, match candidate+manifest, and bind exactly all seven validation inputs; input/manifest/image/check/cleanup drift is rejected.
- Switching rechecks image health and the five runtime source states. Successful completion also requires every unrelated container ID to remain unchanged. Only business-worker is passed to the permanent guard. API image/config is unchanged; the guard still checks both roles.
- Preparation uses umask 0077 and a verified 0700 private snapshot directory. Resolved environment/config remains in private files; old log files are hardlinked into an owned private archive without truncate. The isolated probe uses unique names, network none, read-only root, bounded tmpfs/memory/CPU/PIDs, dropped capabilities, no-new-privileges, no production credentials/data mounts, and 90/15-second run/cleanup deadlines.

## Scope and limitations

For the complete preparation-body tests on Windows, only the POSIX directory-mode assertion was omitted because Windows stat mode does not represent Linux permissions. All configuration/hash/build-manifest code ran unchanged. This local test does not prove Linux mode enforcement; that line remains in the shipped script and must pass during actual preparation. Synthetic I/O tests do not prove live Docker switching, filesystem hardlinks or network/DB health.

The existing deployment lock is release-directory-local; root remains responsible for serializing other release operations. The two zero-PROCESSING samples are not a transactionally held drain. The publication argument is not external publication evidence. These are documented operating boundaries, not new guarantees.

The source review remains `cc1c372759d22c11e2e3f77e84d15ce3accba98e`, including separate real PostgreSQL evidence. This deployment review did not rerun unchanged product suites or access production. `scripts/verify.ps1` is not a substitute for these script-specific failure gates; no whole-repository PASS is claimed.

## Appended actual-image evidence and identity repair

`verify_received_evidence.py 41e878449186294df9cf14b4236c3561cf470436` independently reads exact Git blobs, checks all core/payload bytes remain identical to 77ca, audits the seven runtime inputs and manifest binding, and reconciles the author-generated receipts. It completed exit 0 (`image-evidence-audit-green.log`, full byte identities in `image-evidence-audit.json`). This is an independent evidence audit, not a second Docker execution.

- Exact candidate: `sha256:abda33f8fe5bb4abca45464a5d300fff8981a8b68908be1b64f6e3ee0d8a0e7f`. Exact runtime manifest SHA-256: `341c84e9151f1ad9881d090d307bd2397d9e0f7786e192cb475756bad4ace502`. The old worker remains bfde; API remains a935. All five source hashes agree with the reviewed product commit.
- Author-run actual-image default entry and tests completed 10:03:07–14 UTC: correct installed Consumer/default main origins, all five source hashes, 70 PASS / 1 SKIP in 2.07 s, both temporary checks exit 0 and cleanup exit 0. The skip explicitly requires an isolated PostgreSQL URL; it is not a pass and does not invalidate the separately completed native PostgreSQL source review.
- The same permanent guard checked three unique immutable images: unchanged API, candidate worker and bfde rollback worker. Each returns the exact nine role protocol checks. No PYTHONPATH/product-source mount or production credentials/data was supplied. The actual main test calls main(), observes real renewal SQL and commits the synthetic receipt; external dependencies remain test substitutions.
- Author-run isolated checks ended 10:03:26 UTC with the complete 60-name/container-ID snapshot unchanged and no added/removed/changed container. At 10:07:12 UTC the private configuration proof confirms API fully identical, worker only image different, old API/worker IDs/images still healthy, and current guard/probe hashes unchanged. The separate running inventory contains 35 IDs and its canonical set hash matches. No deployment receipt or service switch is claimed.
- Added staging wrapper accepts only a fixed-SHA ZIP with an exact 14-entry allowlist, no duplicate names, and no path outside the release root. Its sole executable follow-up is prepare. Isolated-check wrapper uses bounded validator/protocol calls and always compares all container IDs. Configuration proof reads private settings but emits only booleans, identities and hashes. Evidence tools perform local Git/read/write work only.

The first appended identity file at `2760bc102650fe92da5777e3b769ee756cee6e6d` recorded checkout rather than Git hashes for ten text artifacts. Independent audit actually failed at absence-green.log (exit 1); `image-evidence-audit-red.log` and `identity-red-details.json` preserve the exact mismatch set. The defect included evidence logs, payload-spec and configuration proof identity records, not the actual script/payload/runtime receipt bytes. Author's follow-up changes only metadata/generation/audit documentation: `files` now binds staged Git blobs and `checkout_raw_files` is explicitly nonportable local observation. All final published identity entries now match exact final Git bytes. Core scripts, image, seven runtime inputs and original receipts did not change; their completed tests were therefore reused.

## Timing and next executable step

Review preparation record: 09:50:47 UTC; exact script export: 10:01:39; local UNKNOWN/author replay finished 10:01:58/10:02:00; nine added boundaries finished 10:03:59. Appended evidence failed the final identity audit and was repaired without remote operations; the final audit output/exit file records the successful rerun. Staged Python AST and diff checks accompany the independent review commit. No root/current-state/author source was edited.

Root can integrate this review as a standalone documentation/test commit. The next release action remains a fresh post-Android-publication live drift review; only then may root run the explicit deployment entry. A changed live baseline requires re-freezing the affected evidence. UNKNOWN switching still requires inspection of settled runtime before any recovery attempt.
