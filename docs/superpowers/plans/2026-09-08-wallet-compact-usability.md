# Wallet compact usability correction

User's six-item review is the approved revision of the wallet UI plan. Scope: manual_wallet_page.dart, wallet_page.dart, wallet amount transport/entry only if root-cause evidence warrants it, corresponding Flutter tests and verification. Keep server fund policy and ledger semantics unchanged. Figma remains deferred per prior user instruction.

1. Reproduce integer 10 submissions in recharge, payout quote and conversion with captured string payloads; distinguish backend failures from numeric input validation. Obtain actual error text if existing tests already pass.
2. Replace oversized green header with compact white address/network section. Add pale-green filled shortcuts, top-right refresh icon with accessible label, and adjacent copy icons only for available full addresses. Never copy a masked address as a real address.
3. Use recharge application terminology, concise status/amount/fee text; move detailed rules to Help and technical identifiers to expandable details. Preserve expired-address copy/QR restrictions and pending-command recovery.
4. Add focused interaction tests, run wallet tests/analyzer/UI contracts/full verify, inspect the final real-device UI. Build/rebuild/verify and install the next debug version with the existing device signer; preserve user data. No real financial transactions during automated verification.

User subsequently deferred item 6 (integer submission errors). Existing integer submission tests capture 10.000000 for both recharge and payout and pass before changes; no amount handling, keyboard or service validation changes are made in this iteration. The reported production submission error remains unverified and unresolved, not claimed fixed.

Device review revealed the active address was only available in masked form. Extend the authenticated binding-status response with optional own full address, retain no-store and token-subject scoping, and expose a header copy icon. Own backend binding status/router plus optional Flutter decoder property; deploy source-hash-pinned read-only response extension with existing configuration preserved. ADR-0058 records the additive scope. Test self/other-user isolation and exact clipboard value.

Final user review requests merging the separate address-status label into the wallet summary. Move the existing status text to a 12px secondary line below the masked address; remove the outside row. No state logic or request changes. Verify card placement and wallet interactions, then rebuild and replace the debug device package.

Next approved refinement: move next-rebind time into the same card; order tabs Recharge, Withdrawal, Binding without changing internal IDs or default selection. Render recharge status/amount/address/expiry as compact single-line rows, preserving exact amounts and full clipboard payloads. Red icon, border and light-red background distinguish warning states and failed operations; successful copy feedback stays neutral. Amount processing stays deferred. Own manual_wallet_page.dart plus tests/registry/evidence; no server changes.
