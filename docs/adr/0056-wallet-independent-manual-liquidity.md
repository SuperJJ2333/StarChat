# Independent wallet gates and manual liquidity policy

Status: accepted policy change under the user's explicit 2026-09-08 instruction.

The global full-backing requirement currently blocks incoming confirmed credit, conversion and manual payout together. The owner explicitly defers replenishing existing backing while requesting these flows to operate independently.

Adopt separate deposit, payout-request, payout-execution and conversion gates. Record the policy as manual_liquidity, preserving full_backing as the default outside this selected production runtime. Never relabel a deficit as full backing. The monitor retains actual observed balance, total liabilities and deficit, with durable alerts.

Confirmed incoming deposits may become user USDT credit without historical full backing; binding, intent matching, finality, unique receipt identity and balanced append-only entries remain mandatory. Value-preserving internal conversion can change the asset denomination of an existing liability, but cannot create a negative user balance or fictitious chain funds.

Manual withdrawal requests reserve the user's available USDT. Issuing payment instructions requires admin owner authentication, a fresh reconciled balance sufficient for the exact payout and no unresolved execution competing for that liquidity. Insufficient actual liquidity leaves the request unpaid, not failed/settled. imToken remains external; the server cannot prevent an owner making an unrelated transfer in that wallet. Only independently observed matching final chain results settle the hold.

Global emergency pause, chain-integrity failures, stale evidence, conflicting events, binding authorization and payout recovery remain enforced. No old balances, liabilities, baseline or prior incidents are silently deleted. Alerting and production acceptance remain required.
