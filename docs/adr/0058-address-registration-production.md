# ADR-0058: User-declared wallet addresses in production

2026-09-08: the user explicitly selected production real funds after being informed that format-only addresses do not prove control and may cause incorrect deposit attribution. The user requests no wallet message signature and no user TOTP for binding or payout requests.

Add explicit server policy `wallet_user_auth_mode=address_only`, with `wallet_proof` as the backwards-compatible default. New address registration validates Base58Check TRON format, current authenticated account, uniqueness, version and 30-day rebind rule. It retains the trusted chain-height activation boundary and pending payout restriction. Registration is self-declaration, never proof of ownership. Deposits still require applicable intents, confirmed matching transfer, deduplication and reconciliation. Residual risk: another account can register an address it does not control; uniqueness and matching intents do not eliminate impersonation or mistaken attribution.

User payout requests require the authenticated account, available balance, current registered destination and existing limits/holds/audit/idempotency. They omit user TOTP only under this explicit policy. Administrator operation-password authorization and manual imToken payment remain. No client can select the server policy. No bypass verifier returning true or fabricated signature is used.

The client follows server capabilities, uses a direct registration endpoint, and removes signature/TOTP UI under this policy. Existing signed requests remain available for backwards compatibility. UI uses existing WeChat tokens and real actions rather than decorative buttons.

The 2026-09-08 compact UI correction adds an optional full `address` field to the existing authenticated, no-store binding-status response so a user can copy their own currently registered address. Lookup remains scoped to the token subject; no public address directory or ownership claim is added. Existing clients continue using masked_address. Full addresses must not be logged.
