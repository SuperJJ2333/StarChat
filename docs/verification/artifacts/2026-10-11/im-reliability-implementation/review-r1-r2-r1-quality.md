# R1 independent quality/security review

Review date: 2026-10-11 UTC+08. Reviewer: review_r1_r2. Scope: integration worktree, baseline 5c83a08a09b985146bc507a1608cb2153d361e48; frozen module SHA256 2210e152f422d57dc585acfd95e912d58a55596f2112efea0b8c764ce2b09ad7.

Verdict: **QUALITY/SECURITY PASS** for the bounded fixed authority endpoint repair. No blocking findings or deferred minor product-code findings. Specification/domain review was read before this quality review.

## Independent checks

- Executed a fresh Python equality assertion: the entire product module equals baseline after precisely one URL replacement, business-api:8000 to business-api:8082. Verified raw SHA256 against frozen identity. This does not introduce configurable URLs, forwarding of the native Matrix credential to business-api, or a new authority.
- Read Authority.matrix, Authority.verify and RecoveryVaultModule.handle: both bearer credentials remain mandatory; owner/device/native account restrictions, repeated native token lookup, expected family/generation equality, pre-write authorization and final release authorization remain unchanged.
- Fixed hostname/path and internal 8082 match the Compose listener/healthcheck. Five-second connect/request/body timeout behavior and bounded dependency response remain unchanged; 401/403/409 deny, 429 retries and unavailable dependencies return fixed errors. There is no new positive authorization cache, logging of credentials, or replacement-vault fallback.
- The sole release runtime change is the fixed endpoint. Storage, envelope/crypto, schema, keyring, account policy and trust boundary are unchanged. This approval does not extend historical custody authorization or resolve policy questions outside this repair.
- Runbook explicitly requires real HTTP authorization fixture coverage rather than a TCP check. Reviewed fixture: real Twisted listener on8082, exact request path/business bearer/body assertions; Matrix auth and status DB are explicit doubles. Missing credentials, rejection, timeout, binding mismatch and final revocation are checked without production material or request logging.

## Evidence and limits

Fresh local command: `python -m pytest -q -p no:cacheprovider tests/infra/test_recovery_authority_topology.py tests/infra/test_synapse_recovery_vault.py`. Result: **16 passed in0.60s, exit0**. Equality/hash assertion also exit0.

Read and reused unchanged-input evidence: topology/native RED, native GREEN14, real PostgreSQL20, candidate-native14, candidate preparation identity. Candidate sha256:0e861d72f57d56367c393994959cb4e85a1c485142adef7928fe5662d565185d; prepared, not deployed at review. PostgreSQL and transport fixtures each disclose their simulated adjacent boundaries. No claim of live production authorization, real-device recovery UX, or native Synapse logout end-to-end is made.

Shared infrastructure gate was925 passed and1 missing-jsonschema failure under Python3.12; r1-schema-recheck.txt records that failed test separately passed under the available jsonschema environment. These are separate results, not a full-suite exit0.

Rollback must restore the frozen previous compatible main/sync image only; no table or key deletion. Runtime drift comparison, protected backups, final image/module identity, shared-module compatibility and deployment checks remain release-owner work. No deployment or real credential/network operation was performed by this reviewer.
