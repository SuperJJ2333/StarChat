# Wallet access verification release

Scope: ADR-0064 and approved 2026-09-10 wallet access plan. Preserve global admin login (48 hours), API runtime configuration and all other services. New fixed 60-minute verification applies only to official-wallet administration; enabled mode requires the configured wallet owner with SYSTEM_ADMIN permission. Other roles need a separately designed verification policy before wallet access can be enabled for them. No financial state repair or clock change is included.

## Preflight and rehearsal

Follow `app-release-deployment.md` SSH jumper route and SHA256 gates. Actuator scripts and manifest live in `docs/verification/artifacts/2026-09-10/wallet-access-production/`; restricted runtime snapshots and database dump stay under `/opt/starchat/releases/wallet-access-20260910/` on the host.

1. Compare changed source and static files against current production, not an earlier release. Baseline API: `sha256:5ca2e95d14ce6b82cd8915f00a84f2dc4643b2fcddabbd576e49ddf7a7aef4ee`.
2. `server_release.py snapshot`; `static_release.py preflight`; `server_release.py build`; `server_release.py backup`.
3. `rehearse.py`: create-only candidate/rollback runtime comparison, image import checks, isolated database restore and migration. Preserve only approved environment delta `BUSINESS_WALLET_ACCESS_GRANT_ENABLED=true`.
4. Complete specification and quality/security reviews, focused HTTP/UI/PG tests and repository verification. Rebuild/rehearse if any shipped source changes.

## Apply

`migration_gate.py` verifies live baseline, candidate digest and database head, applies **only `0062_wallet_access_grant`**, and checks head plus both new tables. Do not run `upgrade head`: unrelated local mobile migrations are not in this release. Migration creates authorization/attempt tables; existing business tables and financial data are unchanged.

`static_release.py deploy` requires matching migration/rehearsal evidence before enabling the flag, recreates only business-api, then installs manifest static assets atomically with `admin.html` last. Do not change the Worker, gateway, mobile downloads, app-update settings or admin-session.js.

Verify API readiness JSON at `https://liuhetong888.com/api/v1/health/ready`; unauthenticated wallet status and wallet data return JSON 401. Confirm server-side flag, schema, shipped hashes and unchanged global login settings without printing credentials. Check `https://admin.liuhetong888.com/` and JS/CSS cache versions. Existing open tabs must refresh once to load the new wallet verification UI. No production financial writes or fabricated administrator sessions are needed for deployment checks.

## Rollback

Run `static_release.py rollback` to restore API baseline and static backups. The old API configuration disables the new feature; the expanded schema remains compatible. Retain both new tables and revocations; never run a destructive downgrade. A newly introduced JS asset may remain unused after old HTML is restored. Rehearse exact image/config restoration before rollout.

The 60-minute UI timer uses server-reported time, not the workstation clock. Revocation is enforced on every server request; an already displayed page discovers remote revocation via a 30-second status check, focus/visibility events or same-browser broadcast. No server push is claimed. Expiry removes sensitive content immediately according to the known deadline. Unconfirmed requests stay scoped to account and are never automatically submitted.
