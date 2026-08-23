# ChatFlow UI Workflow and Brand Migration Plan

**Status:** Approved — user decisions on 2026-08-23
**Goal:** Establish enforceable Figma-assisted UI delivery and migrate user-visible branding to “畅聊 ChatFlow” and CAIBI display text to “点钻”, without changing protected internal financial identifiers.

## Boundaries

- Preserve `CAIBI`, ledger schemas, migrations, event schemas and OpenAPI `asset` values.
- Preserve two decimal places for CAIBI/点钻 and six for USDT.
- Keep OpenAPI title, health-check `service`, Docker default service names, and TOTP issuer unchanged; changes require a separate approved API/operations compatibility review.

## Roles

- **Agent:** Owns Figma edits, exports, registry updates, drift validation, implementation, and verification evidence.
- **Developer:** Reviews Figma visual UI quality and reports design defects; does not synchronize or export Figma artifacts.

## Review gate

The initial merge gate is manual: reviewers require a completed PASS Figma UI Review in the PR description or direct-commit verification record. Automated enforcement is deferred until CI can read PR-platform metadata; it will then validate both record locations.

## Tasks

- [x] Add shared display constants and migrate all user-visible Flutter, HTML, email and admin content to approved terms.
- [x] Update UI design specification, Figma export ledger labels, screen fixtures and tests.
- [x] Extend the UI registry verifier with name/asset terminology checks and CI workflow enforcement.
- [x] Agent recorded the prescribed direct-commit Figma export-ledger review in `docs/verification/2026-08-23-ui-review.md`; developer visual sign-off remains the manual merge gate; then run full verification.
