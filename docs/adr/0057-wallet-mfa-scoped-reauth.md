# ADR-0057: In-place wallet MFA setup reauthentication

User approved on 2026-09-08. Replace the blanket five-minute login-age requirement for password-authenticated setup actions with explicit in-place password verification. Preserve active user, non-revoked family and device ownership checks, rate limits, encrypted enrollment secrets and audit/outbox transactions.

Enrollment returns an authenticated encrypted proof scoped to MFA enable, current user, family, credential, password-hash fingerprint and a five-minute lifetime. No credential persists on the client except the existing pending identifier; proof remains in memory. A pending enrollment can obtain a new proof by verifying the password on the same page. Enable validates the proof and current credential/device/account state. Already enabled/deleted credentials cannot reuse a proof. Legacy clients without a proof retain the existing recent-login requirement.

No wallet binding signature, payout authentication, admin operation password, general session age or funds control is bypassed. No login timestamps are rewritten. Proofs are not logged, placed in URLs or returned by status queries. No schema migration is needed.
