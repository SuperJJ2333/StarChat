# Worker support recovery compatibility probe

The unchanged Worker maintenance task automatically reconciles existing payout commitments even when new funding is disabled. Its installed `app` package must therefore receive the same final attribution gate as the API.

`worker_probe.py` runs the real `tasks.manual_wallet.ManualWalletMaintenanceTask` with funding, deposits and new payout requests disabled. Only provider evidence and the scanner are synthetic. The real payout application service, wallet ledger, reserve lock, audit and immutable event models execute against four seeded orders:

- Two different users share an official source, destination, amount, execution window and valid solid receipt: both remain UNKNOWN with ORDER_ATTRIBUTION_AMBIGUOUS, both holds remain unchanged, and neither gets an event or settlement transaction.
- A distinct destination has a unique valid solid receipt: exactly one event and settlement debit its hold.
- An empty locator preserves CLAIMED and its hold, without a provider call.

The portable CLI requires an isolated localhost database named `clone`, `support_payout_review` or `support_worker_review`, with public migration head 0094. It creates and drops one random `support_worker_probe_*` schema, copying public table columns, checks and indexes via PostgreSQL LIKE. It never mutates public rows. This is an installed-code settlement regression; migration triggers/foreign keys are covered by the separate migration restoration gate rather than by LIKE copies.

Run in the actual Worker image on the disposable clone's network namespace, from its normal Worker work directory:

```text
SUPPORT_WORKER_PROBE_DATABASE_URL=postgresql+psycopg://postgres@127.0.0.1:5432/clone
python /probe/worker_probe.py --installed --expected-sources /probe/expected_sources.json
```

Do not set PYTHONPATH. `--installed` refuses it and verifies that every business module was imported from `/site-packages/app/`, while the maintenance task came from `/opt/`. `expected_sources.json` is a module-name-to-SHA256 mapping for the six business overlay modules and the unchanged task. Every imported file must match before database writes. The result records those real import paths and SHA values, migration identity, and synthetic case PASS labels; no addresses, keys or database credentials are printed.

The release implementer separately freezes the clone container ID, confirms network isolation, checks the probe SHA and compares the site-packages and `/opt` mirror files. Candidate and rollback Worker images both require the safe six-module overlay. Use each image's separately frozen expected-source manifest for an old-image behavior reproduction; passing a candidate manifest to an old image should fail the SHA check before any database write.

## Local red/green evidence

- The pre-recovery `ManualPayoutService` extracted from Git `fd9ab39d`, driven by this same real maintenance task, exited **1** with `EXPECTED_RED: Worker must reject ambiguous cross-user receipts`. Reproduction: `git show fd9ab39d:services/business-api/app/modules/wallet/manual_payouts.py` to a temporary file below this artifact directory, then `legacy_source_red.py <extracted-file>` using the normal local source test import paths. The extracted copy is a temporary input, not a release overlay.
- The current source probe passed **1/1**. Running it with the adjacent Worker tests initially gave **15 passed / 1 failed** because the old empty-locator expectation still said UNKNOWN.
- After the authorized expectation correction to CLAIMED, `py -3.12 -m pytest tests/business_worker/test_support_recovery_compatibility.py tests/business_worker/test_manual_wallet_task.py -q --tb=short` passed **16/16**, exit **0**, in **2.30 seconds**. `git diff --check` exited **0**.

Actual installed-image evidence is recorded by the release runner. The local green result alone does not establish that an image contains these modules.

## Preserved void baseline

The manifest also asserts the installed payout model version and VOIDED terminal guards. Candidate and safe rollback Workers run against the expanded 0094 clone; 0093 unbroadcast void remains its parent migration. The API-compatible payout methods preserve independent proof, owner actor attribution, immutable original conversion reversal and terminal capability revocation.
