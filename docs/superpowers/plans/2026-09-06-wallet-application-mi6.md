# Wallet application integration and MI 6 execution plan

**Authorization:** On 2026-09-06 the user explicitly requested execution, integration into the production wallet code, and Android MI 6 verification. The prior no-provider requirement persists: exercise application services with isolated Sandbox assets; no real-money activation or real custody transaction. This supersedes the legacy prohibition on conversion for this implementation only; direct USDT P2P/redpackets remain prohibited.

**Figma exception:** User subsequently explicitly instructed “暂时不需要安装FIgma同步，请直接开始执行”. Figma installation/synchronization is excluded this turn; Flutter implementation and MI 6 validation remain required.

**Architecture:** Existing WalletService, Ledger public APIs, additive database migration, API/client contract, same Flutter wallet screen. Real-money factory remains fail-closed. Test funds and external orders are isolated from real accounts. Preserve old financial history and migration compatibility.

**Scope and ownership:** Root owns plan, ADR/spec authorization, API/settings/wiring, OpenAPI generation, Flutter/HTML/registry, build and MI 6 verification. Core implementation agent owns wallet module, ledger public APIs, custody simulator, additive migration and focused backend tests. Review agents are read-only. No simultaneous edits to a file.

- [x] Domain review: full point liabilities, issuance guard, hold lifecycle, conversion atomicity, finality and recovery; record implementation authorization without go-live approval.
- [x] Test-first backend: integrate real application services with Decimal validation, balances/holds, double-entry atomic conversion/idempotency, full-liability reserve gate, strong withdrawal transitions, independent external lookup, control incidents/reporting; additive migration after current head.
- [x] API integration: authenticated user-scoped conversion query/write, expanded balances/config/history, safe cancellation, explicit pause/errors; retain unconfigured-production 503. Update generated contracts and test ownership/idempotency.
- [x] Mobile: server-led wallet balances/config, bidirectional conversion, persistent user-scoped request intents, visible loading/error/retry; widget tests and registry/drift verification. Figma synchronization waived by the latest explicit user instruction.
- [x] Quality/security review after domain/spec review; fix findings and run focused tests plus repository verification. Record what needs real provider/durability infrastructure rather than emulate production proof.
- [x] ARM64 release build, version increment, Apktool 2.12.1 rebuild, build-tools 36 alignment, existing tested signer, manifest/assets/signature verification. Both standard and isolated audit packages verified. Existing standard signer differs; no upgrade or data deletion attempted. Audit install blocked by MIUI USB-install restriction.
- [x] MI 6: verify installed identity and wallet navigation, balances, conversion success/failure/retry/restart using isolated Sandbox backend or dedicated test harness; preserve screenshots and sanitized evidence under docs/verification/artifacts/2026-09-06/wallet-application-mi6/.

**Completion constraint:** No claim that unavailable real MPC/finality/financial RPO infrastructure or production go-live is verified. Do not expose credentials, mutate real user balances, uninstall or clear data, or weaken TLS/MFA for tests.

**Final verification:** scripts/verify.ps1 PASS (498 passed, 21 skipped); Flutter full suite 1,185 passed. Standard-final APK fully rebuilt and verified. MI 6 interaction remains blocked by INSTALL_FAILED_USER_RESTRICTED; user action requested, no bypass/uninstall. See docs/verification/2026-09-06-wallet-application-mi6.md.

**MI 6 follow-up:** User enabled USB installation; audit install Success, 0.3.47-audit/2049. Actual UI bidirectional conversion, loss-after-commit restart retry (3 total orders), reserve refusal and matching refreshed balances PASS. Original app/data preserved. Prior installation blocker resolved; production and iOS limitations remain.
