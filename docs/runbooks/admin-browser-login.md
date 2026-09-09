# Admin browser login

The admin web entry uses `/api/v1/auth/admin-captcha` and `/api/v1/auth/admin-login`. Enter the six-character image code; case does not matter. The challenge is valid for 120 seconds and is consumed by an attempt. Use “换一张” for an unreadable/expired image. Failed requests do not automatically retry login.

Redis must support GETDEL (the production isolated smoke checks this). Challenge generation is limited to 30 requests/minute/source IP; browser login to 20 attempts/15 minutes/source IP, in addition to the existing password login limit. Redis stores a digest with TTL; no new database schema or environment variable is required. A Redis outage prevents the browser CAPTCHA login and produces CAPTCHA_UNAVAILABLE; do not bypass it in the client.

Mobile/API password login retains its existing endpoint and limits. This browser CAPTCHA is not a substitute for server password throttling, RBAC or operational authorization.

On 401 or RECENT_LOGIN_REQUIRED, the browser displays a centered modal. Re-login is explicit. Previously submitted financial operations are not replayed; refresh authoritative status before any retry and preserve the original idempotency key where applicable.

Release 2026-09-08: `/opt/starchat/releases/admin-login-20260908/result.json`. The private `before/` folder contains the original API inspect/environment, rendered rollback overlay and static predecessors. Revert API with the same original Compose file list plus `before/rollback.json`; restore backed-up frontend files and remove only the two new login files listed by this release. Check API health and preserve the exact environment. No database down-migration is needed.
