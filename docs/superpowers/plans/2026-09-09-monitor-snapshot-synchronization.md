# Monitor snapshot synchronization repair

User requested investigation and repair, including production access by proxy or direct SSH. Evidence: generation 2 source incident at 09:40:51 CST read observation 5745 with solid head age 180942ms; observation 5746 healthy 80ms later. Thirty-three alert events (one reopened plus 32 unacknowledged escalations) were each delivered once. Latest event 8ad542c1… was sent 12:21:02 CST, before acknowledgement at 12:22:08.

Design: retain exact source identity/cursor/checkpoint, freshness, ledger, coverage, recent-auth and commit-time checks. Synchronize discovery through existing FundingScanService with funds_enabled=False before monitor attempts, preserving coverage registration without receipt ingestion, credit or recovery. Retry only incomplete coverage/source-change results, at most three attempts. Before classifying a valid but expired/unhealthy snapshot as an incident, resample once after 200ms outside financial transactions; persistent failures still pause, and no stale result is ever accepted. No email mute or disabling of P0 alerts: the observed repetition stopped after acknowledgement.

- [x] Write red/green tests for checkpoint-only progress, bounded retry, no credit, real coverage blockers, fresh replacement of boundary-stale snapshot and persistent stale failure.
- [x] Implement optional discovery synchronization in monitor, wire API and worker using existing public discovery service; retain all original authorization/idempotency guards.
- [x] Domain/spec and quality/security review, focused and full verification.
- [x] Pin current production API and worker images, overlay only scoped files, preserve current environment and rollback, deploy and verify read-only status. Do not confirm incidents or restore funds on behalf of the user.

Root owns monitor, API/worker wiring, tests and release/evidence. Reviewer read-only. Current production API base is 494464f3… (another intervening release); preserve it. Server hashes of the scoped API/monitor files match the workspace before edits.
