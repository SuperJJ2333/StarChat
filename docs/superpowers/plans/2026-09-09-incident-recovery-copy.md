# Incident recovery wording correction

User approved the proposed confirmation wording with “好的，请你修复”. Root owns panel wording, its existing regression test, cache entrypoints and scoped release evidence.

- [x] Assert confirmation explains the next recovery location in the existing incident workflow test.
- [x] Replace ambiguous pause confirmation and give explicit post-closure directions to 资金启停 → 核验并恢复资金. No behavior, authorization or state-transition changes.
- [ ] Run frontend regression and syntax checks; publish three versioned static entrypoints with prior-file rollback and public hash checks.

This is a copy-only continuation of the approved incident simplification and interaction polish plans. Their full repository verification passed immediately before this change; no backend or mobile code is changed here.

Frontend 113 passed and production static publication/server hash checks passed. Public HTTPS verification remains incomplete due repeated connection closure during TLS handshake; see verification/2026-09-09-incident-recovery-copy.md.
