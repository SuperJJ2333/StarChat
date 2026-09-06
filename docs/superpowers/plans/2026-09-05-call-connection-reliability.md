# Call connection reliability — 2026-09-05

Approved scope: the user's request to optimize and test slow cross-network calls and immediate incoming-call acceptance freezes, as delegated by the root agent. Preserve the existing encrypted Matrix/WebRTC architecture, permission gates, and audio routing order.

## Bounded ownership

- Call race agent: `apps/mobile_flutter/lib/features/matrix/call_controller.dart`, `apps/mobile_flutter/test/features/matrix/call_accept_race_test.dart`, this plan, and controller verification evidence.
- Root: Matrix adapter, TURN/network investigation, integration and release decisions.

## Execution

1. Reproduce deferred permissions, deferred answer, early connection/end, repeated answer, and disposal using controllable asynchronous fakes. Save failing test output.
2. Guard answer entry and asynchronous continuations by call lifetime; enter connecting and arm the existing timeout before route/answer work. Preserve connected and terminal states when asynchronous work returns.
3. Run focused call tests and analyzer. Root performs required integration/full verification and specification review followed by quality/security review.
4. Record evidence under `docs/verification/artifacts/2026-09-05/call-connection/`. No build/deployment in the bounded controller subtask.

No protected encryption, identity, or financial contracts change. These deterministic tests validate state races, not physical cross-network media quality.

Root extension within approved scope: replace only the SDK's indefinite TURN credential cache using its public getIceServers override. Account-scoped memory cache obeys credential TTL, refreshes before expiry and at most every five minutes, shares in-flight discovery, and prewarms off the incoming-call path. Discovery is bounded to three seconds with the SDK's existing direct-connect fallback. Test expiry, concurrency, timeout and late completion. No hardcoded credentials or provider purchases. Verify public TURN allocations/relay separately before changing any production endpoint.
