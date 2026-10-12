# Android2215 builder preparation: QUALITY/security review

This report follows `01-spec-domain.md` and is limited to build preparation. It does not attest a new APK, successful actual signing, true candidate preflight, device execution or production publication.

## Actual independent verification

- The initial exact e987 Git export contains 28 files. All 27 candidate-input manifest hashes and all eight tool pins match the exported bytes. No author working-tree output was substituted for test input.
- Seven closure tests and four actual guarded preflight-prefix tests pass independently: **11 PASS / 0 FAIL**, 2.824 seconds, in `e987-independent-11.log` and its receipt. Before execution, the real build tail is replaced by an unconditional throw. Synthetic identity files, no-write/no-subst throwing doubles and read-only Python substitutes keep the test within preparation scope.
- Against the exact e987 copied signer, the independent real-Windows-DPAPI synthetic line-ending regression produces **1 intended FAIL**, exit 1, `System.FormatException`, 0.702 seconds. It executes only the parsed DPAPI read assignment, uses synthetic data in a fake user profile, preserves intended password whitespace and checks that no signer is invoked. The failure is retained, not reclassified as a passing candidate.
- Old real artifact/receipt/source/decode checks are recorded separately in `independent-reference-closure.json`. They corroborate historical static reuse only.

## Guard review

The default path returns before build-directory creation, mapping or signing. Explicit Execute is necessary; Execute plus PreflightOnly is rejected. Version and production baseline values are checked, as is the production observation's 30-minute age. The output root is constrained under the task directory, existing reparse components are rejected, run IDs are constrained and existing run directories are refused. W/V mappings are created only after Execute, existing conflicting mappings are refused, and cleanup removes only mappings this invocation owns and still finds pointing to its expected target.

The exact mobile manifest SHA, Git HEAD, raw file inventory and generated dependency/plugin inputs are checked before the build, after it and after final verification. Eight helper hashes and the pinned Apktool hash are checked. An unexpected local keystore/Firebase input is refused. The known ignored dev registration correction is bounded and read back; it is not a production plugin-list rewrite. Every native step writes its actual exit to the run's step record and stops on failure. Final artifact identity is generated only after all final gates and source readbacks complete.

The copied signer retains absolute local path/reparse/output guards, existing fixed P12/alias, certificate/key checks before use, v2/v3 verification, input readback and exclusive atomic final output. It transmits only the name of a task-scoped process environment variable to apksigner, clears it in finally, disposes protected memory and suppresses sensitive tool diagnostics. There is no key generation or fallback identity. The required DPAPI fix trims the serialized envelope, not the decrypted password; every other signer guard must be byte-identical.

The final lock check still runs against the newly decoded final artifact. The full rebuild semantic verifier remains required after that check. Historical successful receipts are not used as replacements for new artifact signing, resources, source/final semantics or actual media-debug evidence. The publication framework and CAS/rollback review are a separate frozen task; this directory does not execute those operations.

## Finding and limits

Original e987 has one P1 execution blocker: stale copied signer at line 95 (`1baf91b7...`) fails on the already observed serialized DPAPI line ending. `e987-rejection.md` provides the reproduction and required exact correction. No other release-preparation blocker was found in the reviewed fixed scope. Actual build success and final-artifact checks are deliberately unclaimed. No real identity/password, signature operation, ADB, remote call, product write or root-source write was performed in this independent review.

## Corrected candidate: incremental QUALITY/security decision

**PASS for preparation only**, `45341ce97e60e7ceee55675f725e1dec0357b36a`, after the specification review above. Independent raw-byte comparison proves the existing signer changes exactly one line: serialized DPAPI `.Trim()` before decryption; certificate, key, path, arguments and cleanup guards are unchanged. The exact corrected copied file equals its declared Git source. All 35 exported blobs, 34 manifest entries and eight helper pins agree. Twelve fixed build/closure/semantic inputs are unchanged, so the seven previously passed closure tests and real historical-object checks are reused without rerunning them.

The four affected real guarded-prefix tests were rerun on the exact corrected Git export: **4 PASS**, 3.666 seconds (process elapsed 3.844 seconds). The same independently pinned synthetic Windows DPAPI case that was RED now passes: **1 PASS**, 0.746 seconds (process elapsed 0.890 seconds). Both receipts bind the exact corrected candidate and signer SHA. No actual signer, real identity or build tail was invoked. These are incremental results, not a claim that every old test was rerun on the new commit. The test-only added runner was inspected and parsed; it pins the prior test source, refuses overwriting receipts, extracts only the DPAPI assignment through the pinned test, and records actual exits.

No remaining blocking issue was found in this preparation scope. The original e987 rejection and RED log remain intact. `preparation-review.json` records this precise decision with actual evidence hashes and denies any implication of actual-package or publication approval. Root must still execute true-input preflight, source build/rebuild/signing, new final-artifact checks, media-device gates and a separately reviewed frozen publication package.
