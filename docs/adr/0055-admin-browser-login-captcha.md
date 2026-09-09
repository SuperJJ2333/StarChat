# Admin browser login CAPTCHA

Status: accepted for implementation under the user's 2026-09-08 login repair request.

The existing browser renders an unused input after three errors; no challenge exists. Add GET /auth/admin-captcha and POST /auth/admin-login. The latter consumes a challenge before invoking the existing password login. Challenges expire after 120 seconds and are consumed atomically even for incorrect answers. Redis stores only a digest bound to a random challenge ID; PNG pixels contain the challenge. Creation and login attempts are rate limited by source IP. Storage failures fail closed.

This is a browser-entry anti-automation measure, not a replacement for credential validation, RBAC or global login rate limits. Existing /auth/login remains the supported mobile/API contract and does not gain a CAPTCHA requirement. No claim is made that CAPTCHA prevents direct API password attempts; that endpoint retains its existing rate limit. No authentication privilege, session lifetime or funds permission changes.

The client never generates/verifies answers and never retries authentication or financial writes automatically. Session-expiry errors show a centered native dialog with an explicit re-login action. Ordinary permission denial is not treated as session expiry.
