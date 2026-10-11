# R2 independent quality/security review

Reviewer: review_r1_r2. Review date: 2026-10-11 UTC+08. Performed after specification/domain review. Candidate commit9d32bdfdf070278a071a4f4ccf671411a11d063d. Product hashes: main.py `58ba9fa6cea9c6836de83bfd2ef8b0a907738ce21440b2f9a626d99ac2b651b8`; rate_limit.py `7e4a4bc114663d1deccee870aaee54c23eaceb1a8ba60dc7d37108090a509e17`.

Verdict: **QUALITY/SECURITY PASS** for the scoped bridge patch. No blocking product-code findings. No deployment performed.

## Concurrency, failure and privacy

- Reservation/admission/completion are synchronized. Pending work does not expire while provider work is active; old failures can release only their own room reservation. Terminal-result capacity is reserved at admission, so accepted partial outcomes are not evicted to admit new work.
- The nonblocking process-wide provider semaphore is held and released inside the synchronous worker. Cancellation of its ASGI waiter does not free a still-running provider slot or falsely clear pending ownership. Every worker exception returned through gather is retried unless explicitly permanent.
- Independently executed additional cancellation scenarios using the real route/client/limiter and synthetic provider: cancel waiter, duplicate while worker running returns503, then release worker. Successful completion is deduplicated on retry with one provider send; failed completion permits retry with two sends. Both PASS, exit0. A threading event was emitted after actual limiter.finish, not merely after provider reply, to avoid a false-positive timing assumption.
- Read actual pinned Synapse1.132.0 HttpPusher methods from isolated local image `starchat/synapse:v1.132.0-dedup.1` with `--network none`. Real dispatch_push plus _unsafe_process method probe PASS:503 returnsFalse, ignores its rejected body, retains stream position, schedules initial1s retry and leaves subsequent event pending; successful200 rejected and empty-result paths match gateway contract. HTTP/datastore/clock/reactor were explicit doubles. No live Synapse/vendor E2E claim.
- Fixed provider wire whitelist and sanitizer are unchanged. v1 carries only reviewed scoped digests; it does not re-enable UPS OS display or transmit plaintext. Existing log assertions and new timeout assertions verify synthetic secret body/CID are absent. Permanent/transient error enumeration remains existing GetuiRestClient behavior.
- Legacy and call paths retain their separate kind windows and wire shape. New overload behavior is explicit503. No financial, session authorization or mobile preference contract change.

## Verification and practical limits

Fresh full bridge suite:51 passed,2 pre-existing warnings,3.74s, exit0. Additional success/failure cancellation probes PASS, exit0. Actual pinned Synapse method probe above PASS, exit0. `git diff --check` exit0. All external provider calls used httpx MockTransport; no real push was sent.

1. Synapse serializes events per pusher/device. If a same-room event receives503 inside its1500ms window, later room/call events on that pusher wait for its retry. Actual probe confirms this head-of-line delay. This is the approved explicit-retry tradeoff, not an end-to-end room-fairness or immediate-call guarantee. Evaluate burst/backlog latency in deployment/device acceptance; a future durable coalescer or other policy would require its own design.
2. Confirmed outcomes deduplicate only in the same process and retention window. Restart, multiple bridge processes, expiry beyond300s/configured TTL, or ambiguous accepted-but-timed-out vendor calls can still duplicate. Stable provider IDs/durable global outcomes are not added and are not claimed.
3. Four slots bound active provider workers per app process, not total ASGI requests or AnyIO's scheduling waiters. One request is capped at100 targets and256KiB; overall ingress/load limits remain deployment concerns. This patch does not assert server-wide request admission.
4. Local test dependencies differ from the production image and existing requirements use ranges. Parent should preserve/freeze the actual production base image for the minimal overlay and smoke its runtime import/route behavior. No dependency upgrades are part of this commit.
5. Real device display/sound, OEM channels and full final integration gates remain separate. Existing deprecations are accurately reported and not hidden.

Next: integrate frozen commit, freeze bridge baseline/candidate runtime identities and execute authorized release checks. Roll back only bridge image/code; no schema/data migration exists.
