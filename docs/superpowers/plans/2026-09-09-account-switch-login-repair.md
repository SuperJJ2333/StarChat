# Account-switch grant and rate-limit repair

User-approved scope (2026-09-09): investigate first login interruption, eliminate duplicate token requests, preserve upstream rate-limit semantics. Own files: identity login response, Matrix gateway/error handler, Flutter business client/error and auth service/page, focused tests, OpenAPI and verification docs. Work in existing isolated V worktree; do not change Android release/artifacts or production account/key data.

## Design / ADR-0004 clarification
Authenticated password login returns its authoritative matrix_user_id as an additive response field. Never infer a new authenticated subject from previous local credentials. Existing identity-bound short-lived token authentication and confirmation before destructive switching stay mandatory. If a legacy server lacks identity, an unconsumed grant may be retained ONLY in memory for the same login attempt/target until its expiry; consume once and never retry a token whose consumption is uncertain. Prefer no initial grant for switches when the login response already supplies identity. Serialize login/confirmation attempts, clear pending grants on new login/cancel/consumption, verify target before deletion.

Propagate Synapse429 as application429 with safe MATRIX_LOGIN_RATE_LIMITED and numeric Retry-After, bounded/fallback parsing. Do not change limits or replay/cache credentials server-side. Client honors cooldown and does not blindly resubmit complete dual-domain login after a later-stage failure. Stage-only diagnostics must not contain tokens, usernames, homeserver bodies, or exception text. Preserve original failures if compensating logout/suspend fails. Identify first-failure boundary via tests and safe stage code; do not claim device diagnosis without evidence.

## Execution
- [x] Reproduce stale identity, preconfirm duplicate grant and masked failure/cooldown in tests; capture red.
- [x] Minimal fixes and additive contract regeneration; capture green.
- [x] Domain/spec review followed by quality/security review under ADR0004; address findings.
- [x] Focused Flutter/backend tests, analyzer, repository verify; record evidence. No release bump/build or replacement of Android requested in this task.

Deployment: no stale backend image rollback; if deployment is performed it must preserve current production overlays and only include reviewed repair files. Candidate client changes need subsequent signed release to reach existing devices. Installed iPhone first-failure stage remains pending unless observable independently.

Result: server repair deployed with guarded three-file overlay, all checks and two reviews passed. First-device exception/retest remains pending; client code is ready for a subsequent signed release, not yet distributed. See docs/verification/2026-09-09-account-switch-login-repair.md.
