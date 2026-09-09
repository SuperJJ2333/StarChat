# Official wallet address display correction

## Cause and scope

The Flutter deposit button still called the legacy custody allocation endpoint. Production intentionally returned `WALLET_CUSTODY_NOT_CONFIGURED` (503), which the client collapsed into a retry message. A fixed official wallet address must be obtained independently of custody allocation.

Added authenticated, read-only `GET /api/v1/wallet/official-deposit-address`. The configured address is validated and returned with USDT/TRC20, minimum 10.000000, funding availability and an explicit notice. No ledger write, funding activation, migration or custody operation is included. The real address is kept out of source and verification artifacts.

Flutter now requests this endpoint, validates the TRON checksum, renders a QR from the same address as the copy action, clears stale data before retry and displays the server's funding-closed notice. HTML and local UI metadata were synchronized; remote Figma remains deferred under the user's explicit instruction.

## Verification

- API: six focused tests passed, including authentication, invalid configuration, no financial writes, no client address override and closed funding behavior.
- Flutter: new seven tests passed; combined withdrawal/conversion regression run fourteen passed. Independent specification review and analysis passed.
- Full `scripts/verify.ps1`: PASS; business tests 1133 passed and 31 skipped. Existing Starlette/httpx deprecation warning remains.
- Source build: standard ARM64 debug 0.3.54-debug (2056), HTTPS service configuration.
- Apktool 2.12.1 rebuild, build-tools 36.0.0 alignment and signature verification passed. All 24,912 classes preserved, 332 native/Flutter assets unchanged, manifest semantics identical. Source and final APK contain only ARM64 libraries and the expected debug kernel.
- Debug certificate SHA256: `34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1`, matching the prior installed debug build.
- Final APK SHA256: `e6d3ca84e9420095e2cbc31887b4725e51c6776b8eac19dd468e9c61e0b69a73`.

## Production and device acceptance

The initial isolated script imported the image's old site-packages copy because it ran from `/tmp`. Locking the import to `/opt/business-api` and asserting the actual module location fixed the harness. With production custody behavior and an isolated SQLite database, all original assertions passed: 401/200, official address, funding false, no-store, legacy deposit 503, POST 405 and zero ledger writes. No production gate was weakened.

Production patch image: `sha256:67311a420b6f073a5a23cf68d23899f6d41be33ae0a494d79af29fc967af6290`.

Production deployment succeeded with API health confirmed and Worker unchanged. No schema migration was executed. Database and original container configuration backup: `/opt/starchat-backups/official-address-20260907T144739Z`. All eight existing compose layers were retained; required image and observer-directory interpolation values were derived from the running containers. The release is bound to the exact smoke-verified image, with verified-health rollback support.

MI 6 received 0.3.54-debug (2056) using the existing debug certificate. The streamed transfer stalled and its incomplete session was abandoned; a non-streamed replacement install succeeded without uninstalling the App. Installed APK SHA256 equals the verified final APK. MainActivity started successfully.

The actual authenticated wallet button returned the designated official address; its hash matched the user's fixed address. The funding-closed notice was visible. A live screenshot was decoded in memory with zxing-cpp 2.3.0: one QR was found and matched the same official address. No screenshot, full address or raw UI tree was persisted. Public unauthenticated access returned 401. These checks validate read-only address display, not real funding activation.

Evidence: `docs/verification/artifacts/2026-09-07/official-address-fix/`.
