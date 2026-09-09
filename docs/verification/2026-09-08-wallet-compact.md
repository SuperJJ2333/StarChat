# Compact TRON wallet review

## Approved scope

User requested filled history/help buttons, adjacent address-copy icons, top-right refresh icon, friendly recharge wording, and a more compact WeChat-style page. User subsequently deferred the reported integer amount submission error. This revision changes Flutter presentation and adds authenticated own-address reading for copying; numeric parsing, balance checks, fund gates and ledger writes are unchanged. Figma synchronization remains deferred under prior user authorization; registry and local ledger describe the revision without claiming remote edits.

## Specification review

Replaced the oversized green header with a white network/address row; grouped white cards on the existing gray background; history/help are filled shortcuts with icons. Refresh is in the navigation bar, with accessible label and activity indicator. Full addresses have adjacent copy icons; masked header values are never copied as if complete. Recharge terminology is “下一步 / 本次充值 / 充值申请”; detailed payout identifiers are expandable. Address ownership warning is one line, and detailed network/minimum/fee/manual payment rules remain in Help.

## Quality/security review

Existing authenticated gateways and command idempotency are unchanged. Refresh/copy have busy guards. The official recharge QR and copy icon remain unavailable after expiration or deposit disablement; the copy callback rechecks validity at click time. Unknown commands retain original payload/key; no draft reset was added for uncertain financial responses. No credentials or wallet ownership claim added.

Red: compact navigation test failed because refresh was outside the navigation bar. Integer recharge/payout tests already passed before edits (10 is serialized as 10.000000); this does not reproduce or resolve the user's reported real server error. Green: 56 wallet Flutter tests passed, including full-address clipboard capture and expiry protection; analyzer no issues; UI contract PASS (17 components, 330 screens). Existing copy assertions were updated to the icon's key and text assertions to the new wording, preserving checks of amount/destination/fees/idempotency.

Build target: 0.3.62-debug / 2065, ARM64, production HTTPS API/Matrix/Getui endpoints. Conventional Apktool rebuild, signature/zipalign/manifest/DEX/native/assets verification passed. SHA256 `23f1ab08fb086b3979774c4c2bbbd7e40aefb21f2d193bc63f80265a5308b4c2`. Debug signer `34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1` matches the previous device-tested line. No formal release popup or server deployment is needed for this debug-only UI revision.

Artifacts: `artifacts/2026-09-08/wallet-compact/`. Complete regression and actual-device review results are recorded after completion.

Device review follow-up: the header previously had only a masked address, so copying the registered address needed a read-only response extension. `binding.status` now includes optional full address for the authenticated subject; router retains no-store and session verification, and the default null field preserves older-client compatibility. Domain review confirms no mutation; security review confirms no arbitrary-user selector, no public directory and no full-address logs. Red observed KeyError for missing address; green 51 binding/router tests, including active Alice address and no Bob disclosure. Optional Flutter decoder feeds the header icon; clipboard test verifies the full value instead of the masked text. Two backend source files are deployed with configuration-preserving backups/rollback. This supersedes the earlier presentation-only deployment statement above; amount behavior remains untouched.

## Final acceptance

- Full verification PASS: 1363 backend tests passed, 31 skipped; 66 Flutter boundary tests passed; migrations/OpenAPI/Compose PASS. Own-address extension independently passed 51 binding/router tests. Final wallet suite 56 passed; analyzer no issues and UI contracts PASS. Existing Starlette/httpx deprecation and Kotlin migration advisories remain unchanged.
- Production API image `sha256:93a816199b3f1c6d32c79998f3959f7d8aceb9d49e9cac13c270c732d1f2eb94`; Worker `sha256:a70c01ac0ebed748e7f84dd27d94bae038d036f773a3c52b1820ecd227779048`. Deployment returned DEPLOYED with prior environment/mounts preserved. Protected backup/rollback under `/opt/starchat/releases/wallet-independent-20260908/wallet-compact`.
- Final **0.3.63-debug / 2066** replaces intermediate 2065. Rebuilt APK SHA256 `c198927df3df0cc051d285374138c644a777c3fa65df18b24ef60eb3409447d4`; same debug signer above. Rebuild, manifest/DEX/assets checks and installation Success; device package reports 2066/0.3.63-debug. Data retained.
- Redmi Note 7: opening wallet, compact header/filled shortcuts, navigation refresh, Help dialog and registered-address copy reviewed. Copy showed “地址已复制”. Recharge page showed new wording and an existing expired application; no application/transfer was submitted or altered. Initial session restore again required one retry, then recovered; this unrelated intermittent behavior is not claimed fixed. Final screenshot `final-build/device.png` contains only a masked address. Full-address UI dumps were removed after checking.
- User-deferred integer submission error is **not fixed or claimed fixed** in this iteration. No formal-user update popup was published.

## Final inline-status refinement

User requested moving address status into the wallet card. The same state is now rendered as 12px secondary text under the masked address; the standalone “地址状态” row is removed. Placement regression failed before the move and passed afterward; final wallet suite 56 passed and analyzer no issues. UI contract rechecked PASS. The full regression above completed before this final presentation-only adjustment; backend code is unchanged by it. Next debug delivery is 0.3.64-debug/2067 with the same rebuild/signing procedure.

Delivered 0.3.64-debug/2067 to Redmi Note 7 via install -r (Success), installed version verified. Final rebuilt APK SHA256 `0e013d546b7d7dc4351048043d985755b47f376889e5f9114f7db5f435fd6a6a`; debug signer unchanged. Real-device screenshot `status-build/device.png` confirms the smaller “已登记” text inside the summary under the masked address, with no standalone status row. No financial action was performed. This is the latest delivered package, superseding 2066.

## Recharge rows and warning refinement

Approved subsequent request: next-rebind time is now a small local-time line inside the wallet card; tabs are Recharge, Withdrawal, Binding, retaining internal IDs and default selection. Detail text is 13px; address rows show one line with ellipsis and retain exact full clipboard values. Recharge expiry shows date and minutes, removing fractional seconds from presentation. Warnings use dynamic system red text/icon/border and a translucent red background; caught errors use the warning style while copy success remains neutral. Expired and closed-by-rebind applications explicitly warn not to transfer; QR and copy eligibility remain unchanged. No amount processing, ledger or server-policy changes.

Red: test failed on next-rebind placement before moving it. Green: 56 wallet tests passed, including ordered tabs, location inside summary, and red expiration warning plus hidden QR/copy. Final analyzer and device evidence follow. Full project regression above remains the baseline; these subsequent changes only affect presentation and warning display.

Delivered latest 0.3.65-debug / 2068 to Redmi Note 7 using install -r: Success; installed version verified. APK SHA256 `3b13688392d81e52f843a7313b1e8a9329d9b1208c2a6172e3697b7e556660af`; unchanged debug signer `34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1`. Conventional rebuild, alignment, certificate, manifest/DEX/resources/native/assets verification passed. Final analyzer: no issues; wallet suite: 56 passed; UI contract PASS. This supersedes 2067.

Actual device review: `rows-build/header.png` confirms the next-rebind date inside the wallet summary and Recharge / Withdrawal / Binding tab order. `rows-build/device.png` confirms compact status, amount, one-line truncated source address with copy icon, minute-resolution expiry, and red icon/text/border/background on an existing expired recharge warning. No QR or official-address copy is displayed for the expired application. No financial command was submitted during this review. An unrelated foreground-app capture was removed before retaining wallet-only evidence. No formal-user update popup published.
