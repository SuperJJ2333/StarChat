# Production user-declared address mode

ADR-0058 records the user's explicit production decision and residual attribution risk. An address registration is not ownership verification.

Set `BUSINESS_WALLET_USER_AUTH_MODE=address_only` explicitly on both API and Worker only after deploying support. Default remains `wallet_proof`. API `/wallet/config` exposes `user_auth_mode`; clients cannot override it.

The authenticated `/wallet/binding/address` operation accepts address and expected_version plus Idempotency-Key. It validates canonical TRON Base58Check format and enforces existing uniqueness, pending request, withdrawal-in-progress and rebind restrictions. It creates an audited REGISTER event and a pending binding. Worker establishes a fresh trusted TRON activation height before it becomes active; this is not a wallet ownership check. Signed challenge endpoints remain compatible for old clients.

User withdrawal requests omit TOTP only under address_only. Administrator claim/correction authorization is unchanged. Minimum amounts, fee, actual liquidity checks, immutable destination, quote terms, idempotency and ledger holds remain. Do not describe this mode as having the same identity assurance as wallet signatures.

Deposit receipt and manual payout history are included in the existing user transaction endpoint, with user filtering and bounded cursor pagination. Unknown/unattributed deposits are not assigned to a user merely to make the list complete.

Before deployment preserve exact runtime environment, image digests and database backup. Roll back the user mode and matching images together if needed; do not delete registrations, ledger entries or pending orders. Existing self-declared registrations remain unverified even after switching policy back.
