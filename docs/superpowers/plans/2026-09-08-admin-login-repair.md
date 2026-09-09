# Admin login repair

User-authorized scope: real CAPTCHA on the admin web login, brand above the card, restrained Apple-style layout, centered session-expiry dialog, related error/retry fixes. Figma remote synchronization remains deferred by the user's earlier explicit instruction.

Owned files: admin-home.js, admin-api.js, new admin-login.js/admin-login.css, admin.html; identity.py and new login_captcha.py; focused tests, OpenAPI and UI metadata, verification artifacts in 2026-09-08/admin-login-repair.

1. Reproduce production page and inspect existing authentication contract. Confirmed: phantom CAPTCHA input and two-column CSS.
2. Add tests before implementation. Implement a separate CAPTCHA-required browser login endpoint, sharing existing password verification/session issuance/audit. Preserve mobile login contract and RBAC.
3. Implement a server-generated PNG, short-lived Redis-backed single-use challenge, hashed answer, issue/attempt limits, no automatic login replay. Browser handles loading, refresh, failures and duplicate submission.
4. Single-column brand/card, labeled fields, focused centered native dialog, mobile and reduced-motion verification.
5. Domain review then quality/security review, focused and repository checks. Prepare scoped production image/static deployment with backup and rollback; verify live assets and public CAPTCHA. Do not change wallet switches, reserves, APK or signing.
