# Independent manual wallet activation

Policy decision: [ADR-0056](../adr/0056-wallet-independent-manual-liquidity.md).

The selected production runtime is `manual_tron` with `manual_liquidity` reserve policy. Existing full-backing deficits remain recorded and alerted. They do not prevent confirmed deposit credit or value-preserving conversion. Actual payment instructions still require sufficient freshly reconciled USDT for that payment.

## Configuration

| Environment setting | Meaning |
| --- | --- |
| `BUSINESS_WALLET_DEPOSITS_ENABLED` | Create deposit intents, activate pending bindings, credit confirmed matched receipts |
| `BUSINESS_WALLET_PAYOUT_REQUESTS_ENABLED` | Quote and freeze available user USDT for manual withdrawal |
| `BUSINESS_WALLET_PAYOUT_EXECUTION_ENABLED` | Owner may claim a request and obtain payment instructions |
| `BUSINESS_WALLET_CONVERSIONS_ENABLED` | Atomic USDT/CAIBI conversion of available balances |
| `BUSINESS_WALLET_RESERVE_POLICY` | `full_backing` by default; explicit `manual_liquidity` for approved manual operations |

Set the first three gates explicitly in production; omitted gates retain legacy `BUSINESS_WALLET_REAL_FUNDS_ENABLED` compatibility. Keep that legacy switch false for independent operation. API and Worker must receive the same policy and gates. Preparation mode requires every gate false.

Authenticated retries with an existing matching idempotency key may recover their committed deposit intent, payout quote or request while its new-operation gate is disabled. Changed parameters conflict; a new key remains blocked. This read does not create another hold or consume a new authentication proof. Claiming payment instructions has no such exception.

## Acceptance and operation

1. Preserve the fixed official address, existing activation baseline, original ledger and incident history. Back up database, images and exact runtime settings before rollout.
2. Deploy API and Worker in handover preparation mode with all money gates false. Record root-owned deployment evidence linking the retired monitor to the new monitor. Confirm observation coverage and alert delivery.
3. The owner completes the authenticated legacy incident handover and subsequent safety review/resume. Never substitute a fabricated authentication proof or delete the legacy incidents.
4. After handover, leave preparation mode and inspect a fresh reconciled reserve publication. Enable accepted capabilities independently; verify the public capability response agrees with actual behavior.
5. Deposits require ownership binding, an applicable intent, minimum 10 USDT, confirmed TRON USDT evidence and unique transaction/log identity. Unmatched or ambiguous funds remain in review. Retry and backfill must not credit twice.
6. Payout requests freeze only the user's available USDT. Payment instructions require owner operation-password authentication, fresh actual liquidity, matching immutable terms and no competing unresolved execution. `admin` pays externally in imToken. A submitted hash alone never settles the hold.
7. Maintain observation and reconciliation even with deposit credit disabled. Keep status, cancellation of unclaimed requests, and existing payment reconciliation available when new requests are disabled.
8. Publish only the verified formal APK with the established formal signing identity. The MI 6 debug installation is a separate signature line.

An emergency pause still blocks new financial operations. The exact `MANUAL_BACKING_DEFICIT` advisory is nonblocking under the explicit manual policy; integrity failures, unknown payments, stale evidence and other incidents retain their normal controls. Restoring an old binary after new financial operations needs a compatibility assessment; configuration rollback must not erase holds, receipts, outbox records or reconciliation state.

## Transient handover evidence

Confirmation retries complete evidence reads for the exact pending-source, pending-coverage, busy-monitor, changed-source and changed-reserve results. It uses the original request, a 20-second monotonic retry/commit budget and at most 21 attempts. A slow underlying read can finish after that budget, but cannot commit late. No transaction or monitor lock is held during the one-second waits. The original authorization, manifest and delivered notice are revalidated before commit; authorization freshness is never renewed by the retry.

An exhausted attempt remains `HANDOVER_EVIDENCE_UNAVAILABLE`; `error.fields` contains only an allowlisted evidence reason. Refresh the preparation status before retrying with unchanged parameters and idempotency key. An expired preparation needs a new preparation; the delivered notice is reused only for the identical manifest. Conflicting evidence must be investigated rather than retried automatically.

The isolated handover monitor reports coverage lag as `BLOCKED / MANUAL_COVERAGE_PENDING` to preserve transaction rollback. This exact pair is transient for confirmation retry; other BLOCKED results remain terminal. The admin panel displays structured handover reasons and distinguishes a rejected handover from an unknown payment result. It retains the original request identity for recovery.

Manual control resume is a separate activation transaction. Its pending/changed/busy proof results use the same bounded waiting strategy, with the original owner proof, expected control epoch and snapshot preserved. `MANUAL_CONTROL_EVIDENCE_UNAVAILABLE` includes allowlisted `wallet.control.evidence` fields. A completed handover must never be regenerated to address this error. Refresh the funds control state; a snapshot conflict needs refreshed terms, while a transient evidence retry retains the same original request. No response-time budget or retry bypasses current incidents or actual reserve checks.

Configure the production TronGrid query key as `TRON_WATCH_API_KEY` for the observer and `BUSINESS_WALLET_TRONGRID_API_KEY` for API/Worker. Transfer credentials outside the repository through a protected file, never chat or logs. This key does not grant signing authority. Preserve source identity, official address, baseline, history and all funds gates when configuring it. Verify fresh reconciled cuts afterward; a successful HTTP response alone is not funding acceptance.
