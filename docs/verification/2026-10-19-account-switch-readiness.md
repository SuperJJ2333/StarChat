# Account-switch readiness verification

Candidate0.4.62+2231; frozen runtime11b72ec7754179370926377ade0a16e578801349. Original Android emulator-5556 installed2230 at baseline, UID10090 and firstInstall2026-09-26. No production distribution changes or real test messages authorized in this task. Evidence root `artifacts/2026-10-19/account-switch-readiness/` in the interactive-cache-startup worktree.

## Findings and change

Selection retired A's projection owner but never bound B's new owner. This prevented subsequent encrypted head capture. Selection now uses the constructor/resume owner wiring after exact continuity validation; the owner stays unverified until the existing authenticated prime, and binding failure retires/closes it. Original startup fallback stays tied to its original owner.

A real SDK old-token sync401 delivered after retained broker login could clear the new token. Retained login now awaits the SDK abort's transaction drain and retired-generation isolation before broker adoption. Once server user/device, retained key upload/authorized rotation and continuity persistence succeed, the exact adopted token/device/client and lifecycle generation are rechecked, then the normal loop restarts with timeout0. Ordinary backoff, new-device init and genuine new401 behavior remain. Complete login operations are serialized; synchronous lifecycle generation checks prevent queued or acquiring old requests from reviving after logout/selection, and old failure cleanup cannot suspend a newer owner.

## Test evidence

- Original RED: readiness-red-r2/r4; real stale401 credential loss, omitted coordinator and overlapping login adoption. queued-logout-red and acquisition-red separately prove queued/acquiring intent revocation. Early compilation/fixture failures are retained and are not counted as root-cause RED.
- Final focused readiness-green-final:153PASS/exit0,2026-10-19 07:05:24→07:05:48+08. Includes stale old401/200, genuine new401, fresh real SDK success replacing cached unavailable status, current backoff preserved under repeated start, owner binding failure cleanup, upload/rotation/persistence/logout failure, and overlapping-login revocation.
- Real SQLCipher and AEAD fixtures prove A→B→A with identical room IDs remains isolated and shallow heads are readable while deep SQL is held; a real SDK SQL transaction held in storePrevBatch blocks broker adoption until its drain completes. Existing preflight/device rotation/retained identity/reinstall/temporary secure-storage and actual mismatch regressions are included.
- DOMAIN/SPEC then independent QUALITY/security implementation review:PASS. Final frozen analyze completed with0issues. Frozen complete shared gate and platform build/runtime remain in progress; do not infer their result from the focused gate.

The fresh-status fixture's intermediate failures were caused by an expect assertion in SDK runInRoot producing OutsideTestException. The assertion was moved to the test zone; no product condition was bypassed. All failed logs remain separate from the final gate.

## Delivery and practical limits

Final shared gate/build/install results are pending. Packaging follows source→Apktool2.12.1→zipalign36P16→fixed75b31 signer→semantic and payload verification. Only install-r; never clear/uninstall/downgrade. iOS request is prevention of historical L04/L07, not a reproduced current iOS defect; shared Windows regressions do not constitute native iPhone verification. No iOS signing/Keychain policy or production download/popup changed.

Observed baseline old-client suspension was9ms and one full preflight about1.44s in the available process log; these are partial intervals, not attribution of the user's actual >10s. The reported history phrase is not a literal in current source. Real user-assisted switching/login observation and complete timing remain open. Credentials must be entered only on the emulator, never read or collected by the harness.

Aggregate scripts/verify.ps1 preflight: canonical .env absent; do not import primary's runtime secrets. Scope-specific mobile gate is used, not an assertion that every repository gate passed. Previous14 synthetic ignored test DBs remain after automatic approval rejected cleanup with “blocked by policy”; excluded from APK and no retry attempted.

## Superseded first candidate

Original936507 candidate's conventional APK pipeline passed but Python version contract found compiled AppConfig2230 vs package2231; it was never installed or delivered. Full gate exit-1 is canceled/not passed. Version defaults corrected with3PASS and frozen11b72ec7; final evidence must use b2 gate/build artifacts. Same-source validation-only iOS compatibility workflow dispatched07:24:15+08; results pending, no publishing job.
