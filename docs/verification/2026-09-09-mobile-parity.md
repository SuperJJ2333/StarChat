# Mobile parity verification — 2026-09-09

Approved scope: complete Moments caching/reaction state and history-retention verification, then build Android/iOS from one source revision. Based on main be14e743, branch codex/mobile-parity-20260909. Target identity: 0.3.58 (61); both pubspec and runtime fallback agree. Build 61 follows the formal sequence; older 2xxx Android split/debug numbering is not used.

## Implemented and reviewed

- Moments navigation prepares verified account metadata before pushing the page, enabling cached first paint without trusting a stale profile alone. Feed and cover retain cached content during refresh. Likes update names/count/heart, persist confirmed changes and roll back failures. Loaded older pages remain visible. Account replacement and request revisions reject stale updates. Specification review required and verified the stale-profile correction; independent Quality/Security review required and verified field-scoped persistence so a successful comment cannot save an unconfirmed like or be lost during its rollback. Both reviews now pass; final focused suite: 36 passing tests.
- Shared Moments disk image cache across thumbnail, cover and full-screen viewers. Existing layout/gestures are preserved. Cache manager retains up to 200 entries with a seven-day stale/inactivity policy, not a strict byte quota or guaranteed deletion deadline. Root specification review and independent Quality/Security review passed.
- History validation exercises real application session/bootstrap/login services with synthetic HTTP and a Matrix boundary spy. Six composed cases plus related tests total 126 passing tests. Ordinary logout, Business refresh 401/403 and Matrix token failures retain existing identity material; same-user login reuses the original device; unconfirmed cross-account login keeps history gated. Root specification and independent Quality/Security review passed. No authentication/E2EE production changes in this branch.
- Current main already incorporated ADR-0007 continuity behavior. The older diagnostic branch's token-error reset finding is superseded for this source; it is not attributed to the release candidate.
- Four additional video integrity tests pass through the actual Matrix SDK encryption/decryption and production cache resolver. H264/HEVC bytes survive simulated ciphertext transport; altered/truncated ciphertext is rejected before plaintext caching. Independent Quality/Security review passed. This does not claim live server delivery.

The first repository-wide verification passed (349 backend/worker tests, 19 skipped; 66 mobile boundary tests plus policy, infrastructure, UI/OpenAPI and offline migration checks). Final source after review corrections is being checked again. Public HTTPS Matrix versions, client discovery and Business readiness endpoints passed; probes that initially used nonexistent generic health paths returned 404, then the declared `/api/v1/health/ready` route was verified. No server configuration changed.

## UI delivery record

Existing Moments node: https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78/ChatFlow?node-id=19-4.
Local behavior records: `frontend/artifacts/figma-state.json` and `packages/ui-contracts/changliao-component-registry.json`. No typography, geometry or token changes; cached/loading/liked/rollback state handling is repaired.

Remote Figma update: **Deferred — no callable Figma tools in this session**. The production-hotfix deferral in `docs/ui-development-figma-workflow.md` applies to this runtime regression repair. Existing Figma node ID is a reference only; no remote design modification or screenshot validation is claimed. The local ledger explicitly records `remoteNodesModified: false`.

## Evidence and limitations

Focused synthetic logs live below `docs/verification/artifacts/2026-09-09/mobile-parity/` in this isolated checkout; build/download evidence lives in the same named directory below the primary workspace. No credentials or user messages are recorded. The HTML suite passed 26 tests and UI drift verification passed (17 components, 330 screens).

Native process restart, SQLCipher and media tests must be recorded against the final candidate separately. Dart service reconstruction is not an OS restart, and simulated attachment transport is not a live two-account server test. The unavailable iPhone 15 and third-party enterprise re-sign behavior still require real-device acceptance. A signed App Store IPA requires TestFlight distribution or appropriate re-signing; generating it does not update the website enterprise package.

Builds and final combined verification are in progress; no artifact completion is claimed in this interim record.
