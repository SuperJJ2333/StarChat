# Published void and recovery compatibility

Authoritative source: immutable API 902eaefcb capture under support-source-drift-v2/api-source. The payout model file remains byte identical; `_result` and `_valid_void_evidence` remain AST identical. The live void method is preserved with the current public conversion API's authenticated owner actor and MANUAL_PAYOUT_VOIDED reason arguments.

Recovery excludes VOIDED from leases, expiry review, capabilities, address/discovery/reconciliation authorization, and owner takeover replay. Independent legacy UNKNOWN fixtures preserve published void eligibility. Empty-locator reconciliation still preserves CLAIMED.

## Test-first evidence

- Initial new terminal compatibility test failed because the current service lacked void_unbroadcast.
- After method integration, it failed because cached owner evidence takeover replay remained accessible after VOIDED. The terminal guard now runs before replay.
- Final payout + discovery + takeover + published void focused suite: 148 passed, 26.37 seconds.
- PostgreSQL random-schema suite: 12 passed, 1 stale expected migration-head assertion failed. Corrected expected head to 0094_support_finance_order_recovery; affected 0092 row-retention migration case passed 1/1, 4.06 seconds. The new terminal takeover/void case passed in the first run.
- Worker source compatibility + maintenance task suite: 16 passed, 2.08 seconds.
- Scoped git diff --check passed.

Published void tests preserve proof rejection, intent/version/owner rejection, locator/event exclusion, idempotent replay, financial release, audit/Outbox and terminal model immutability. An additional adjusted-rate CAIBI case proves original 20 USDT / 142.40 CAIBI mirroring, restored balances, and authenticated owner attribution on wallet release, wallet conversion reversal and linked CAIBI reversal.

The portable Worker probe now asserts six business sources including manual_payout_models, plus the actual installed maintenance task. Its SHA256 is 93d4756a6f8019c8ecce6ef9c17264f7f6a73450fe5af2827731bde71293b4c8. Candidate and safe rollback probes require a disposable expanded 0094 clone and installed-code imports. Actual image results are owned by the release runner; source tests do not establish image contents.
