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

## Subsequent authorized production deployment

After the user explicitly requested deployment, the reviewed source was committed as `8a985a68e5a20831aa8f440629999f43b53aeb51` (iOS candidate 0.3.59/62). The user then prohibited an Android update and requested comparison with official Android 0.3.68/2072. The additional Android source build was stopped before rebuilding/signing/publication. No Android release settings or files were changed.

The production friendship files were independently captured and matched HEAD before this fix. The running image was overlaid with only the three modified friendship files, new coordinator, additive 0040 reservation migration and a deployment-only 0057 merge joining the existing 0056 production head. Every other application/migration file retained its live hash. Compose environment, mounts, overlay hashes, image and container ownership were guarded against concurrent deployment.

Prepared-image migration-plan checking initially used an Alembic graph iterator that omitted the newly joined branch. This failed before any schema mutation or activation. The checker was corrected to inspect Alembic's actual upgrade steps; it verified exactly the reservation migration and merge revision. Six guard tests pass.

Deployment **activated successfully** at `/opt/starchat/docs/verification/artifacts/2026-09-09/direct-room-deploy/20260909T104704Z-a62324a9/deployment.json`. Image: `sha256:c76be88a7e5bef06405bdf6d8b7b5f65109ae8660f9da114ea5b378a2d5dee2f`. Database head: `0057_merge_direct_room`; reservation columns and `uq_direct_room_reservation_pair` verified. Internal readiness 200; live OpenAPI includes lookup, legacy registration, claim and publish. The actual client API host `https://liuhetong888.com` returned readiness 200 and unauthenticated POST claim/publish 401. A preliminary probe of website-only `www` returned 405 for those POST paths; it is not the app's configured API host. No proxy change was needed. Raw sanitized deployment evidence is `docs/verification/artifacts/2026-09-09/direct-room-deploy/deployment-final.json`.

This does not assert authenticated real-device end-to-end acceptance or all-old-client uniqueness. Official Android 2072 still uses the old creation/greeting logic; see `2026-09-09-ios-vs-android-0368.md`. iOS signed CI run 34341320812 and native compatibility run 34341320856 build the candidate source; no enterprise OTA or TestFlight publication has been performed.
