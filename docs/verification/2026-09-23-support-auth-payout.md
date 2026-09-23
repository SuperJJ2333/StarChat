# Support authentication and payout verification — 2026-09-23

Scope: server-bound staff activation, management login integration, scope-separated support-orders financial verification, support payout coordination. Main branch; no commits or real SMS/email/chain transfers performed by this task.

## Evidence

- Test-first failures observed for missing activation service/router, unactivated admin issuance, missing support grant scope/security router, missing login activation, new payout policy/service/router, and autoflush NULL grant timestamp. Implementations subsequently passed.
- Focused final authentication, worker, payout, original manual payout APIs and evidence expiry regression: **206 passed**, 139.56 seconds. Raw output: `artifacts/2026-09-23/support-auth-payout/focused-final.txt`.
- Frontend login/session/activation gateway: **12 passed**.
- Real PostgreSQL isolated database: migrations 0001 through 0087 applied in per-test random schemas; two OS processes verified exclusive payout claim and exactly-once activation OTP consumption.
- Subsequent expired-unstarted review claim regression: initial missing-method failure verified. Updated payout suite plus real PostgreSQL migrated-schema race suite: **14 passed**, 16.74 seconds. This includes unpublished 0087 review_authorized_at column.
- A prior full identity run had 391 passed, 11 skipped and five import-path failures from worker task imports; corrected PYTHONPATH regression passed all 12 phone review tests. Final focused run includes corrected worker path.
- Existing upstream warning: Starlette TestClient deprecates httpx in favor of httpx2. No new warnings suppressed.

## Security boundaries verified

Activation never accepts a delivery destination or grants roles; contact/verification/role epoch changes invalidate challenges and activated staff access. SUPER_ADMIN existing access remains explicit. OTP limits, purpose separation and single-use consumption are preserved.

Support financial grants require management scope, live activated FINANCE_SUPPORT (or existing configured SUPER_ADMIN owner), own configured password/TOTP, exact grant scope and final authorization. Fixed expiry remains; scope crossover is rejected. Autoflush-enabled session regression checks complete grant timestamps before implicit flush.

New payout policy is server-selected and does not relax legacy owner commands. Lease takeover is possible only before execution. Started/unknown payout cannot transfer ownership or auto-unfreeze. Expired unstarted orders require explicit reason-coded review claim and fresh lease; begin revalidates digest and existing reserve/financial gates. Existing executor may supply late evidence with fresh financial verification. User hold releases only through existing proven cancellation or verified settlement.

## Integration

Parent owns main router wiring, worker expiry call, OpenAPI/docs and full repository verification. Review claim endpoint: POST /api/v1/admin/support-orders/payouts/{order_id}/review-claim with reason_code and Idempotency-Key. Notification audit event wallet.manual_payout_support_review_claim. review_authorized_at was added to unpublished migration0087; any prior local scratch database at0087 must be recreated or locally expanded before running current source.

Independent specification/security review is delegated to sibling support_workbench by parent. No production deployment performed.

Independent review follow-up: sibling found expired review lease remained REVIEWING. Regression first failed as expected; projection now returns NEEDS_REVIEW for an unstarted expired review lease and explicit review claim can renew it. Latest payout suite: 12 passed, 7.36 seconds. Root recharge read-only review delivered: verify-payment completed idempotency replay and prepare-settlement replay lease validation findings; root owns fixes.

Full-gate fixture correction: the existing admin API finance-1 fixture attempted management login without verified contact/activation. Only tests/business_api/admin/test_admin_api.py changed: explicit verified email plus real StaffActivationService request/confirm using deterministic test sender. Runtime and identity negative tests unchanged. Reviewed all issue_admin_pair and admin-login test callsites; no other missing positive staff activation fixture identified. Focused admin/support/groups regression: 132 passed in 217.85 seconds.
