# Support recharge receipt and financial execution review

Date: 2026-09-23. Scope: local main working tree; no commit, deployment or device build.

## Findings and corrections

- Reserved real-chain receipts cannot enter old manual deposit repair or old intent credit paths. Existing legacy transaction credits and anomalous transactions cannot become support credits.
- Reservation identity and immutable receipt facts cannot be reassigned or deleted. Only reserved verification refresh and one reserved-to-consumed transition are allowed; ORM and migrated PostgreSQL guards agree.
- Execution follows budget → recharge order → adjustment → receipt locks, and transfers pending USDT reserve liability in the same transaction as the CAIBI ledger credit and receipt consumption.
- Verified-order submission has a narrow public transaction-aware application interface; it cannot select an arbitrary recipient or amount and remains pending independent approval. Ordinary adjustment policy is unchanged.
- Support review locks the adjustment, rejects self-approval, and writes audit plus outbox records. Every managed recharge execution requires independent approval, including ordinary adjustments bound to a managed order.
- Managed execution requires the current claim token and scoped authorization callback before domain locks; authorization is rechecked before return. The legacy ledger route cannot supply this context. Historical bindings also retain this protection.

## Verification evidence

Red: two newly added tests initially failed because neither legacy-route execution nor self-approval raised an error. Both passed after the guards were added.

`py -3.12 -m pytest tests/business_api/wallet/test_support_recharge_receipts.py -q`, with the explicitly authorized isolated PostgreSQL URL: **15 passed in 8.54 s**. This creates a unique schema, migrates it to head, exercises actual database triggers, and executes the same adjustment concurrently in two sessions. No shared database is dropped. Tests also cover authorization expiry rollback and approval audit/outbox.

`py -3.12 -m pytest tests/business_api/wallet/test_support_recharge_receipts.py tests/business_api/wallet/test_deposit_receipts.py tests/business_api/wallet/test_manual_deposit_cases.py tests/business_api/ledger -q`: **96 passed, 1 skipped in 34.65 s**. The skipped test is the explicit PostgreSQL test, which passed separately above.

Earlier receipt/repair/ledger regression evidence (110 passed) and PostgreSQL output are retained under `docs/verification/artifacts/2026-09-23/support-order-workflow/mobile/`. The results above supersede the earlier narrower receipt test count. The parent task owns the integrated API, specification/security review and final repository gate.

`py -3.12 -m pytest tests/business_api/wallet/test_admin_deposit_repairs.py -q`: **20 passed in 3.38 s** after the final authorization changes.

Next executable step: integrate root-owned service/workflow authorization and run the final repository checks on the combined source state.

## Independent final integration review

The new `test_support_settlement_boundary_review.py` reproduced an additional issue: a review claim cleared `payment_verified_at`, but an already approved adjustment could still execute without fresh verification. The test initially failed with `DID NOT RAISE`. The parent added the workflow payment check and this review added the same check to the public execution boundary. The original receipt fixture was updated to include its authoritative verification timestamp.

Combined order settlement integration, independent boundary review and real receipt PostgreSQL tests: **20 passed in 4.36 s**. This includes committed financial execution followed by registration failure, worker-only recovery without wallet verifier configuration, repeat recovery without duplicate credit, authorization rollback, and the review re-verification requirement. No unresolved finding remained in the reviewed paths. Final repository gates remain parent-owned.
