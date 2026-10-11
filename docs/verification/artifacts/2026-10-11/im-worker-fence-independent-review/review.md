# R9b paired worker deployment scripts: independent SPEC → QUALITY review

Verdict: **PASS for the bounded candidate scripts at the exact identities below**. Reviewer `/root/fix_scheduler_r6` did not edit root, invoke the scripts' top-level bodies, use Docker/DB/network, send signals, or deploy.

## Subsequent finding: r1 did not cover the real import location

The original verdict above is retained as historical evidence and is **superseded for deployment readiness**. The first `13f3c67...` candidate failed its production startup and the recorded deployment receipt reports `FAILED`, `RuntimeError`, `rolled_back: true`. Root reports the worker restored to the previous `18a88c4d...` image, healthy with zero restarts after rollback.

This review checked the requested Worker and `/opt/business-api` Consumer bytes but missed that the worker image installs the API package into `site-packages`; its default `python main.py` therefore imported the old Consumer from `/usr/local/lib/python3.12/site-packages/app/core/outbox.py`. The earlier isolated pytest invocation overrode `PYTHONPATH=/opt/business-api` and concealed this mismatch. Its 49 passing tests cannot establish the default production entry point. The new Worker correctly failed closed on the old Consumer's missing fenced completion API. This was a deployment-overlay/gate-fidelity gap, not a reason to weaken that fail-closed check.

r2 separately overlays identical reviewed Consumer bytes into both the real installed location and the source copy, and requires default-import identity/hash/constructor evidence without a PYTHONPATH override. Its independent review lives in `../im-worker-fence-v2-independent-review/`; it must not be inferred from the r1 mock results below.

## Inputs and specification

- `prepare.py` SHA256: `e0e90fe3111b594b3b2cce42537db330fc7b9b43c3bf4ae6a07807717e95a99f`.
- `deploy.py` SHA256: `1ff679590fdd0568f764133b46c5e371fa61e7c28de6b818e12b68aa820f21f2`.
- Domain-reviewed source commit: `9920947c34e6c41a050a1fbb1d9cc7d7ac882749`; both payloads compare byte-for-byte with its Git blobs.
- Worker base: `sha256:18a88c4dde6e09fb75122aef1f011fd11c7a0421e61559b0548ed78c1b8b3ecf`.
- Prepared worker candidate, per root's preparation receipt: `sha256:13f3c67b2f84b09a659af16a5308917c3358071f1fada9cb66e7c9af6b2d9cd7`.
- API stays `sha256:a935b4144d18ebfb7486bcc014a4441eb8cd45c06b9f97cb5b19217e0cfccab3`; schema requirement remains `0095_wallet_source_alerts`.

SPEC PASS: one candidate worker image contains both `worker.py` (`f88387d6c957f774b6c137f786b82235b74e8a5cf26a5e282259c7da94eb2299`) and `outbox.py` (`a2e606116fef84986d7d4781090d792f6d8d6f0785b8679db3299160a660f680`). Preparation checks both old live hashes and both reviewed payload hashes before the network-disabled overlay build. The API has no overlay files. Deployment and rollback verify every paired file against the corresponding new/old hash after switching the whole worker image, and success receipts now retain both hashes. The guard command targets only `business-worker`; unrelated-container identity checks remain intact. The diff from R9a changes the release path, worker base/payloads, preparation timeouts, paired verification loop and paired receipt, as claimed.

## Quality and fault boundaries

QUALITY PASS: the existing lock, image/container/config/source identities, read-only schema/processing checks, HTTPS certificate verification and guarded candidate/rollback mechanism remain unchanged. Preparation subprocesses are now bounded (30-second query/render; 180-second build). Sensitive inspect/render data stays in the server-private location under the existing restrictive umask; the public receipt contains identities/hashes, not environment secrets.

An outer guard timeout, cleanup failure, wait failure, or nonzero guard result becomes `UncertainSwitch`. The catch records failure and explicitly withholds automatic rollback, avoiding a second switch racing unresolved daemon state. Only a completed guard followed by a failed postcondition can enter the guarded rollback path. An uncertain rollback is never recorded as a successful rollback. These rules were executed against the real AST-selected functions and catch body with inert substitutes.

Independent local verification: **11 reused fault-boundary cases PASS** after binding the new path and exact SHA; **6 additional paired deploy/rollback cases PASS**, including rejection when either worker or Consumer runtime hash is wrong. Static/identity checks additionally establish reviewed payload equality, unchanged API image, prepared-manifest pairing and both source hashes in the success receipt. See `failure-boundaries-result.json`, `paired-overlay-result.json`, the two test scripts and the saved R9a→R9b diffs. No source-test suite was redundantly rerun.

## Limits and next step

This approves script behavior for root's authorized guarded operation, not evidence that deployment already succeeded. The prepare receipt is historical local evidence, not a fresh production observation; the script must pass its live guards at execution. Root still owns final candidate protocol validation, execution receipt and production postflight. Two zero-PROCESSING observations are a release precondition, not an atomic drain. R9b step 1 fences stale completion; it does not add heartbeat renewal or prove exactly-once external effects. The known active-handler expiry fault remains separate and is not hidden by these script results.
