# Independent wallet activation implementation plan

Goal: implement the user's approved separate controls and manual-liquidity policy, then activate the independently verified production capabilities.

Authorization: 2026-09-08 user explicitly requests separate deposit, payout and conversion activation and defers replenishing full reserve backing. No authority to forge chain evidence, settle an unpaid withdrawal, bypass account authorization or use user credentials.

Architecture: distinct deposit-credit, payout-request, payout-execution and conversion gates. Explicit manual-liquidity policy leaves historical reserve deficit visible but removes total platform backing as a prerequisite for incoming receipt credit and value-preserving conversion. Actual payment instructions require fresh reconciled liquidity sufficient for that payment, exclusive pending execution, user hold, binding and administrator authentication. Default existing full-backing policy remains for other callers.

Tech: FastAPI/SQLAlchemy/Decimal, Worker, TronGrid, Flutter and admin HTML.

- [x] Capture predecessor and production readiness; declare affected ownership: wallet settings/runtime/routes, receipt/ledger public interfaces, manual payout coverage, reserve monitor/publication, Worker gates, mobile capability handling, tests/contracts/runbooks/evidence.
- [x] Add failing tests for independent gates and explicit manual-liquidity semantics; implement minimum policy change without altering recorded amounts or inventing reserves.
- [x] Add receipt credit with existing finality/binding/idempotency checks; preserve pending obligations and reconciliation while allowing the approved full-backing deficit.
- [x] Implement production atomic conversions via dedicated manual runtime integration; preserve debit/credit balance, precision, permissions, account locks, audit/outbox and retry equivalence. Activation remains a separate final step.
- [x] Separate withdrawal request from execution; enforce fresh actual liquidity and outstanding payment exclusion at instruction issuance; preserve cancellation/unknown-result recovery.
- [x] Propagate capability gates into Worker and app; existing admin UI uses server control state. Formal client verified, publication remains pending.
- [x] Domain review then quality/security review; focused tests, PostgreSQL concurrency/restart checks and full verification. Maintain explicit user-deferred Figma status if UI changes.
- [ ] Deploy scoped API/Worker/client revisions with backup and rollback; activate only verified capabilities, record real remaining prerequisites and ask for owner-only credential steps if still missing.

## Acceptance correction: moving observer snapshot

The owner's confirm request returned HANDOVER_EVIDENCE_UNAVAILABLE. Production diagnostics resolved the reason to MANUAL_SOURCE_PENDING, with a valid manifest and delivered SMTP notice. The observer performs a single sample spanning multiple network calls; a solid-head advance invalidates that sample and requires two later consecutive stable samples for reconciliation.

Within the existing authorization to complete integration, retry a complete moving-head snapshot at most three times under the original scan deadline. Keep each attempt's events, head and balance isolated, preserve the requested end window, reject regression/conflicting solid identities, and retain unverified status after exhaustion. No finality, freshness, reconciliation or authentication rule is relaxed. Test first, domain/security review, then update only the observer's verified source with backup/restart/rollback and observe fresh reconciled production cuts before owner confirmation retry.

## Acceptance correction: one-shot handover evidence

A later owner confirmation again returned HANDOVER_EVIDENCE_UNAVAILABLE. Production diagnostics observed a healthy initial source read followed by MANUAL_SOURCE_PENDING during the full proof. Four direct provider snapshots returned HTTP 200 and stable results, so no speculative transport retry or faster anonymous polling is introduced.

The confirmation service will wait for exact transient pending/busy conditions within a shared bounded 20-second monotonic budget and finite attempt cap. Each attempt runs a complete proof, outside any held transaction between attempts, using the same callback and original request identity. It retains fresh original administrator authorization, manifest, delivered notice and final commit checks. Permanent evidence conflicts are not retried. Exhaustion preserves the existing error code and adds only allowlisted diagnostic reasons.

Production also has no TronGrid API Key in either observer or wallet runtime. Official documentation requires a key for production and warns of strict anonymous limits. Complete software verification and prepare secure credential configuration; do not claim anonymous access will become reliable merely by retrying, request wallet secrets, or increase anonymous request frequency without evidence.

## Acceptance correction: actual coverage status mapping

After query-key configuration, production returned BLOCKED/MANUAL_COVERAGE_PENDING with valid notice and manifest. The isolated handover monitor intentionally rolls back through _HandoverProofRejected, which maps the transient coverage lag to BLOCKED; the confirmation retry whitelist only included WAITING for that code. Add precisely the actual BLOCKED/MANUAL_COVERAGE_PENDING pair, preserve rollback and all permanent blockers, and regress against the real monitor rather than replacing it with a synthetic status. No timing budget, authentication, coverage condition or ledger state transition is relaxed. Deploy API-only after focused/full verification.

## Acceptance correction: independent resume entry point

Owner handover is now complete (three dispositions, manual pause ownership adopted). The subsequent resume entry point still performs only one monitor activation proof, so transient pending/changed/busy outcomes return MANUAL_CONTROL_EVIDENCE_UNAVAILABLE. Apply the same bounded 20-second/21-attempt strategy to this separate service, using its actual WAITING/RETRY result contract. Preserve original authorization, snapshot, incident resolution, pause provenance, actual liquidity publication, atomic release and idempotency. Commit after the deadline must roll back. Show allowlisted recovery reasons specifically for the resume form. No repeated handover or financial gate activation is part of this fix.
