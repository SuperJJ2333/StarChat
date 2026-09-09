# Admin wallet recent-authentication compatibility correction

This corrective follow-up implements the existing approved admin modernization plan and ADR-0059. Owned production file: `services/business-api/app/modules/identity/wallet_access.py`. No migration, credential, session lifetime, or financial state change is requested.

## Diagnosis

Production admin session was created at 12:14:42 UTC and remained unrevoked. Its authenticated_at was updated at 14:25:02 UTC. Access logs show successful POST admin-session/step-up (200) followed immediately by GET wallet/security (403), while GET manual/operations/control succeeded (200). Thus the identity verification succeeded; the operation-password service subsequently rejected it.

`TokenService.require_recent_login` already uses the current AdminSession.authenticated_at. `require_wallet_session`, used again inside operation-password/financial transactions, still used RefreshTokenFamily.created_at. A step-up deliberately preserves family identity, so the second guard rejected every step-up of an old family.

## Correction and safety

For trusted decoded admin-scope claims, read the matching current AdminSession with a locked scalar query; use authenticated_at for the existing five-minute limit and check the absolute session deadline again in the freshness callback. Missing/replaced/expired admin sessions are rejected. Ordinary user sessions retain family.created_at. Existing user/device/family checks and the 30-second operation-proof freshness limit remain intact.

Regression first failed in service.status immediately after successful step-up, then passed. Focused identity, wallet authorization, operation-password and API suite: 48 passed. Independent Python 3.12 review run including additional guard and final-callback tests: 12 passed; specification and quality/security review found no blockers. PostgreSQL locking was reviewed statically in this focused run.

Final repository verification completed with `Verification: PASS`: backend 1388 passed / 34 skipped, followed by mobile boundaries, UI contract, imports/AST, migrations, OpenAPI and Compose checks. Existing dependency deprecation warnings remain visible in the saved output; no dependency was changed for this correction.

Release overlays one file onto the current production API image. Compose rendering must match the prior deployment exactly except image. Original source/image retained on server; rollback command is `python3 /opt/starchat/releases/admin-wallet-session-20260908/release.py rollback`. No database rollback is involved. Full verification output lives under `artifacts/2026-09-08/admin-wallet-session/verify.txt`.

Production deployment succeeded: API image `sha256:7cf7f88cf5d07b27cae561f71961a76215ed166c97167029206ab8f25fe8bea6` healthy; deployed source hash matched. Nginx configuration check/reload passed. Public HTTPS HTML and admin CAPTCHA returned 200 with TLS verification successful, and unauthenticated overview remained 401. Evidence: `artifacts/2026-09-08/admin-wallet-session/production-verified.json`. No actual administrator password was used by the agent; user verification requested after deployment.

User confirmed "已恢复正常" after deployment. Read-only production log confirmation: at 14:38:42 UTC step-up returned 200, followed at 14:38:43 by both wallet/security and manual/operations/control returning 200. Before that new step-up both correctly returned 403 because the previous verification had aged out. This verifies the repaired end-to-end sequence with the real user performing authentication.

## Connection investigation

At about 14:23 UTC, direct HTTPS returned 200 with valid TLS for HTML, JavaScript and the actual admin-captcha endpoint. The unauthenticated admin overview returned the expected 401. The earlier probe of `/auth/captcha` returned 404 because that was not the admin CAPTCHA route.

The local 127.0.0.1:7897 HTTP proxy reproduced a TLS handshake failure. Added only admin.liuhetong888.com to the Windows proxy bypass list, retaining all other settings and saving its previous values under `artifacts/2026-09-08/admin-connection/proxy-before.json`. Browser-level navigation verification timed out; do not claim this proves the user's browser has recovered. Direct SSH timed out during authentication; SSH over the same local HTTP CONNECT proxy succeeded with normal host-key verification. API, worker and chain observer health checks were healthy.
