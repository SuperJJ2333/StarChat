# Wallet MFA setup without signing out

ADR-0057 separates active-session validation from recent password verification.

- Enrollment verifies the current password and returns a five-minute setup proof. The app retains it in memory and submits it with the authenticator code.
- After reopening a pending setup, use **验证密码并继续**. This calls `/security/mfa/reauthenticate` with the pending credential identifier and password. It does not reset the authenticator secret or return it again.
- `MFA_SETUP_PROOF_INVALID` means the proof expired, changed context or became invalid after a password change. Verify the password again on the same page.
- Revoked sessions/devices and unavailable accounts still cannot configure MFA. Signing out/in is appropriate only for an actually invalid session, not merely an old valid login.
- An enabled credential cannot be cancelled through the pending-enrollment endpoint. Unknown enrollment results must first refresh the current pending identifier.
- The proof is not a login token and cannot authorize wallet binding, withdrawals or admin operations. Never put it in URLs, logs, preferences or audit payloads.

Legacy clients without a setup proof still require a login less than five minutes old for enable. Upgrade to the in-place reauthentication client to use this flow. imToken ownership signing remains a separate integration.
