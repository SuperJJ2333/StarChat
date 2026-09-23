# 2161反馈修复与流程补齐 Implementation Plan

> Use bounded parallel domains under dispatching-parallel-agents; detached worktree, final integration to main, no new permanent branch.

Goal: restore staff email, valid payout, phone usability; automate bound-wallet recharge matching and verified phone onboarding per user instructions.
Architecture: existing OTP/registration/Matrix outbox, wallet observer/receipt evidence, RechargeService and ledger public application interfaces. No new UI components or second balance system.
Baseline:7140ace2; detached .worktrees/support-feedback-20260923. User explicitly confirms transfers originate from APP bound wallet. Existing design2026-09-23 amended by latest user requirements; original payment proof entry superseded by automatic observer matching. Prior production/APK delivery authorization persists for these corrections.

## Specification
- Chain scan records authoritative USDT receipt from official TRON wallet. Identify user through binding effective at chain block; unique pending user order after request creation and exact requested amount. If ambiguous, mismatched, cancelled/late or unsupported source, preserve receipt and NEEDS_REVIEW; never guess or auto-credit. One tx/log consumed once. Refresh evidence before financial commit.
- User only amount/address/QR/wait. Existing evidence endpoint retained for legacy clients but new UI removes input. CS auto-confirmed payment→reference USD/CNY snapshot default→+-1/5% relative to immutable displayed base→editable final rate, balanced point credit via existing approval/execution.
- Existing minimum10USDT and Decimal precisions retained unless user changes policy. Fix raw error and retry state only once root cause proven.
- China+86 phone input normalization/realtime validation, green eligible button/explicit consent feedback. Proof first then auto-onboard unknown phone with a valid invitation (user explicitly confirmed); no password derived from phone, no phone exposed as public handle. Existing locked accounts never recreated. Existing Matrix provisioning and session rules preserved.
- Staff email dedicated OTP mail contract, never misuse wallet alert API. No real mail/SMS/funds for tests without specific need.

## Ownership / red-green tasks
- [ ] Email agent: worker identity/email adapter and tests; actual adapter validation/outbox integration, preserve alert contract.
- [ ] Payout agent: manual payout/page/store API retry and relevant tests; no other auth/recharge edits until reassignment.
- [ ] Root: recharge automatic attribution/service/worker wiring and protected ADR, integration/OpenAPI/docs.
- [ ] Auth/UI next bounded task: phone backend registration plus auth page and tests, assigned after diagnosis slot freed; avoid worker identity owned by email until coordinated.
- [ ] Recharge admin/Flutter UI delegated after payout diagnostic complete; root no edits to those until ownership updated.
- [ ] Spec then quality/security independent review, PG matching races/idempotency, focused tests, fullverify once preflight complete. Flutter full/analyze/frontend on frozen final; reuse unchanged prior evidence.
- [ ] Integrate only owned code to main, production backup/isolated migration as needed, incremental deploy then next fixed-signature Debug/retained-data Mi6 install. Preserve other task files.
