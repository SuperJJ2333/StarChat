# Direct-room coordination and acceptance context

Scope approved by the user: coordinate both business accounts before Matrix room creation; never create blindly after failed lookup. The user additionally selected displaying the original greeting as labeled friend-request context upon acceptance rather than later ordinary-message replay. Android and iOS share these Flutter paths.

## Implemented behavior

- Durable database-unique sorted pair reservation, one-time creation authorization, owner/attempt publication, immutable canonical room, and legacy registration exclusion during pending creation.
- Account-scoped persistent client intent and result. Unknown create outcomes only recover existing rooms; no expiry or second creation. Known/unsafe room failures propagate.
- Acceptor-authored encrypted system context before accepting route navigation. Outgoing polling emits no ordinary greeting. Explicit retry preserves the friendship, and accepted-request detail supports recovery after restart after checking current friendship.
- Existing duplicate rooms/history/keys are preserved. No production deployment, app rebuild, TestFlight upload, enterprise signing or website replacement is part of this source verification.

## Test-first evidence

Evidence directory: `docs/verification/artifacts/2026-09-09/direct-room-coordination/`.

- `flutter-red.log`: six behavioral failures before coordinated gateway implementation (duplicate create, unknown outcomes, failed publication and recovery).
- `legacy-red.log`: five failures demonstrating old fail-open directory/validation handling.
- Additional observed red: initial owner returned a new room instead of its existing legacy room; corrected by find/validate-before-create and SDK create-once callback.
- `flutter-green.log`: 20 gateway, persistence, transport and legacy guard tests passed.
- Backend red/green, PostgreSQL, greeting and integrated checks are recorded in the same evidence directory.

Final gates: full Flutter suite **1514 passed**; final Flutter analyzer **no issues**; focused friendship/OpenAPI **53 passed**; migration tests **10 passed**; real PostgreSQL coordination **9 passed**. `scripts/verify.ps1` exited 0 with **Verification: PASS**: backend/worker **365 passed, 19 skipped**; mobile boundaries **66 passed**; infrastructure **17**, Getui **28**, bot **9** passed; UI contract, import, AST, Alembic, OpenAPI and Compose checks passed. The 19 optional integration skips are not represented as executed coverage. Existing unrelated deprecation warnings remain in the Getui/backend verification output. `git diff --check` reported no whitespace errors.

## Reviews and limits

Specification review found an initial legacy repair-to-create fallback; it was corrected and re-reviewed with no blocking specification finding. The following quality/security review reported no actionable findings. Both were source reviews, separate from runtime test evidence.

SQLite file-backed multi-thread tests exercise actual transactions. Disposable PostgreSQL 18.3 loopback tests additionally exercise all nine coordination cases, including eight simultaneous claims, legacy registrations and mixed races. This is not production PostgreSQL 16 verification; no real iPhone/iPad or Android installation was used this turn.

For a lost creation authorization/result with no recoverable room, a pair intentionally remains pending. No unsafe automatic takeover is implemented. Obsolete clients can still independently create Matrix rooms or replay greetings; both endpoints must upgrade. Deployment must account for the production migration graph divergence described in `docs/runbooks/direct-room-coordination.md`.

## UI/Figma record

Existing system-notice styling is retained, with labeled request context and explicit retry/open-chat states. Registry: `packages/ui-contracts/changliao-component-registry.json`; ledger: `frontend/artifacts/figma-state.json`.

Figma remote update **Deferred**, not modified: no callable Figma tools were available. The hotfix deferral follows `docs/ui-development-figma-workflow.md`; the remote review record remains due the next working day. Existing page references: [Contacts](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78/ChatFlow?node-id=19-3), [Chat](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78/ChatFlow?node-id=18-7). These are known existing nodes, not evidence of a remote edit.

Repository hygiene exception: two relative pytest cache paths resolved under `tests/business_api/docs/` and `tests/business_api/friendship/docs/`. Automated command review rejected both recursive cleanup and a later bounded deletion of the eight explicitly enumerated generated cache files (`blocked by policy`, no further reason). Those ignored cache files remain; they are excluded from code delivery. New evidence/cache paths use absolute paths below the designated verification directory.
