# Address registration and WeChat wallet verification

## Scope and specification review

User explicitly approved production real funds with format-only private-wallet registration and no user signature/TOTP. ADR-0058 and the approved address-wallet-wechat plan define this policy. API and Worker implement an explicit server setting; clients cannot choose it. The default remains wallet_proof. Administrator operation-password authorization is unchanged. Figma synchronization remains deferred by the user's prior instruction.

Scope review: direct registration preserves Base58Check validation, authenticated session, uniqueness, optimistic version, 30-day cooldown, pending payout restriction, audit/outbox and idempotent recovery. The trusted activation height remains mandatory. Existing signed endpoints remain compatible. Real receipt and manual payout history is included in the authenticated user's bounded history query. No schema, ledger formula, reserve policy or official-address change.

## Quality/security review

Reviewed router authentication and extra-field rejection, REGISTER replay payload, global lock order, trusted barrier fields, request-only MFA policy separation and per-user history filters. No fabricated signature or verifier that always succeeds. Ownership is explicitly NOT established: the user accepted impersonation and erroneous attribution risk. Finality and deposit intent checks do not remove that residual risk.

Test-first evidence: missing registration method, address-mode UI still showing MFA, and manual order absent from history failed before implementation. Focused backend binding/payout suite: 111 passed; route/runtime/admin/binding suite: 111 passed. Full verification: 1351 passed, 31 skipped; Flutter boundary suite: 66 passed; migrations/OpenAPI/Compose PASS. Wallet Flutter tests: 53 passed. After the real-device button contrast correction, wallet tests again 53 passed and analyzer reported no issues.

Existing dependency notices: Starlette TestClient httpx deprecation (one warning); Flutter plugin Built-in Kotlin migration advisory. They are not new wallet failures and did not prevent builds. No warning suppression was added.

## Production deployment

Both containers deployed with source-hash verification, protected database/inspect backup and exact image/env rollback overlay at `/opt/starchat/releases/wallet-independent-20260908/address-wallet`. Existing mounts, commands, credentials and fund gates preserved; only image plus BUSINESS_WALLET_USER_AUTH_MODE changed.

- API: sha256:17d4e623dcbf268d087cc48e72025145892bd028d7c22da3fe6c880cc85766b5
- Worker: sha256:1edb41235b1c2b228860af0de228140b1eef611e7fa93221c696e9d7da832f9e
- Live runtime: address_registration=true; user_mfa_required=false; deposits/payout_requests/payout_execution/conversions=true.
- Live TronGrid finality query succeeded under TRONGRID_SINGLE_SOURCE_V1.

No real registration, transfer, payment or ledger credit was performed for verification. Initial SSH/scp attempts failed during handshake; SSH streaming upload succeeded, deployment returned DEPLOYED. Local external HTTPS probes were intermittent; do not confuse them with successful end-to-end payment acceptance.

## Device

Redmi Note 7 selected by the user, not MI 6. Initial rebuilt 0.3.60-debug/2063 installed with `adb install -r`, retaining existing data and the installed debug signer. Initial login restore failed, then retry recovered without clearing data; the wallet page became accessible. Debug exception inspection collected class/stack names only and made no account-state edits. Real-device review exposed green-on-green main button text; corrected to explicit white while enabled. Final replacement build and screenshot evidence recorded below after verification.

Artifacts: `artifacts/2026-09-08/address-wallet-wechat/`.

Final device delivery: **0.3.61-debug / 2064**, rebuilt with Apktool 2.12.1 and build-tools 36.0.0, DEX/resource/manifest/native/assets equivalence checks passed. APK SHA256 `6608f84aa946083e55fbb5aa7a3b18d569d6448a95ab4aa52abad722b365fd85`. Debug certificate SHA256 `34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1`, matched the APK pulled from the selected device before installation. `adb install -r` returned Success; installed version verified 2064/0.3.61-debug. Final startup recovered the existing session normally. Navigated Me → Wallet → Private wallet; production status loaded, address registration form had no signature or TOTP inputs, green main buttons displayed white text. Existing unfinished legacy binding data was preserved, not submitted or cleared. Snapshot without a full wallet address: `final-build/wallet-top.png`.

Production readiness URL returned HTTP 200 when checked from the server. No formal-user update popup was published for this debug delivery. End-to-end real registration/deposit/payout still requires the user's own test operation; no such financial success is claimed.
