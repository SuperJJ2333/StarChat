# Ledger module rules
- CAIBI has exactly two decimal places; never use float.
- Transactions and entries are append-only and balanced.
- Corrections use linked reversals only.
- Every write requires idempotency, reason, actor, audit, and Outbox.
