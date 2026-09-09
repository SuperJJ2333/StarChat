# Account-switch login repair — 2026-09-09

## Findings and scope

Production audit proved a1102 password authentication succeeded and account was ACTIVE. At 13:26:51 and 13:29:45 UTC Matrix grant issuance succeeded; subsequent requests within seconds received Synapse429 at `/login/get_token`, incorrectly mapped to business502. First iPhone generic exception after successful issuance remains unobserved: no device error log yet. Do not claim these server logs establish the exact first client exception.

A separate reproducible identity defect was found: business password login omitted Matrix identity, while the client inherited the previous saved account binding. That breaks account-switch decisions. The client legacy unknown-identity flow could also request a grant before confirmation and a second immediately after confirmation. Tests reproduce and cover both.

## Changes

Password login now returns the authenticated account's Matrix ID through an additive PasswordLoginResponse; refresh response is unchanged. New clients never inherit the previous identity when a server omits it. The service guards concurrent login/confirmation/cancellation, uses an unconsumed legacy grant only in its original attempt until conservative request-start expiry, discards it before consumption, and never retries unknown consumption. Cancellation holds the guard through logout. Later-stage network errors retain Business credentials and avoid automatic complete password-login replay. Safe stage codes L01–L06 identify identity read, grant, local clear, Matrix login, sync and binding without logging exception text or credentials.

Synapse429 maps to MATRIX_LOGIN_RATE_LIMITED/429 and numeric Retry-After. Malformed values use a safe60s fallback; numeric milliseconds are rounded up. No limits were changed or bypassed. Client grant exchanges share in-flight work and honor cooldown; confirmation displays the safe Business error instead of a generic failure.

## Verification

Backend red: six expected missing-behavior failures, thirteen existing pass. Client red: stale binding, repeated grant, concurrent login reproduced; the initial new rate test had a missing UTF8 mock header, corrected before green (do not count that fixture error as a behavioral red).

- Backend identity/grant focused:25 passed.
- Flutter full:1,570 passed before final cancellation/network review corrections; final expanded auth/history/lifecycle run:88 passed after those corrections.
- Final Flutter analyzer: no issues.
- Required scripts/verify.ps1: PASS; API/worker392 passed,19 existing environment skips; infrastructure17, push28, Matrix bot9, mobile boundaries66; OpenAPI/migrations/Compose passed. Existing dependency warnings were not suppressed.
- Domain review and subsequent Quality/Security review approved. Deployment overlay re-review caught a CRLF staging transform error before activation; it was corrected, constructors exercised, hashes regenerated and independently re-approved.

## Deployment

Server repair is LIVE on image `sha256:f7dd6edbe88c18ea740aaca9efa4bf62c4a660ca4d088566c3f5690d2e198415`, over the existing Moments/admin-auth image0751596a. Only three reviewed source files changed. Staged identity preserves extra production admin routes, staged errors preserves all no-store headers; complete source inventory, existing Compose inputs/environment and concurrent deployment guards passed. No migrations or production settings changes. Candidate HTTP mock verifies actual429/status/header/message redaction and authenticated identity response; ordinary AppError constructor also checked.

Internal readiness200, public TLS-verified apex readiness200, unauthenticated grant401. An initial www-domain probe was against the download-site vhost (405), and transient Windows TLS handshakes failed; correct API apex checks subsequently passed without disabling TLS validation.

Android settings remained exact digest `d6fb203a9151c4a474ab13cafe899615d4bf334976a70a627e2ddbe2645d5691`, version0.3.68/build2072 and original APK URL. No Android/iOS installation package or website link changed in this task. Client corrections require a later signed release; old installed2073 benefits immediately from server identity/429 changes but lacks the new client cooldown/stage codes.

Server evidence: `/opt/starchat/docs/verification/artifacts/2026-09-09/ios-account-switch/20260909T135301Z-5c2d6299/deployment.json`. Local technical evidence under matching worktree artifact directory; secrets, tokens, user content and raw authentication responses were not retained. User was asked to retry once after deployment and optionally connect the iPhone; device outcome remains pending.
