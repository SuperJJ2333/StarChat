# Address registration and WeChat wallet UI

User approved production address-only registration and no user TOTP. ADR-0058 records the explicit risk and scope. Figma deferred by prior instruction.

Own wallet config/runtime, binding registration/router/adapter, payout request gate, Flutter manual wallet API/page, dedicated tests and verification artifacts. No ledger schema or calculation change.

1. Red tests for direct format registration, invalid checksum/default-policy rejection, duplicate replay, existing pending/rebind restrictions; payout request policy separation.
2. Implement explicit policy, authenticated registration endpoint and user-request-only TOTP omission. Preserve administrator authentication and finality/deposit matching.
3. Implement WeChat-style wallet summary/action cards, grouped form, filled main buttons, secondary help, status labels, and direct binding with safe request recovery.
4. Verify focused tests, contracts, analyzer/full verification and scope/security review.
5. Back up and deploy API/Worker consistently, inspect actual capabilities, rebuild debug APK with existing identity and install on the user-selected Redmi Note 7. No claim of verified ownership or successful real transfer.
