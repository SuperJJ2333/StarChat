---
name: figma-ui-delivery
description: Deliver Flutter, HTML, and Figma UI changes for ChatFlow with an obligatory Figma update, functional implementation, drift checks, and page URL evidence.
---

# ChatFlow Figma UI Delivery

Use for every user-visible UI, interaction, component, navigation, state, or copy change in this repository. It applies equally to a new screen, a visual adjustment, and a bug fix that changes a visible control. Do not use it for non-UI infrastructure-only work.

## Required Figma rule

Every UI change **must use Figma** before code is finalized:

1. Load `figma:figma-use` before any Figma plugin read/write call.
2. For a component library change, also load `figma:figma-generate-library`; for a page/flow change, also load `figma:figma-generate-design`.
3. Inspect the existing file and reuse its variables, component keys, auto-layout, naming and variants. Do not create an unrelated duplicate.
4. Update the affected Figma component, screen, state, or prototype; inspect metadata and a screenshot after the change.
5. Update `design-demo/artifacts/figma-state.json` and `packages/ui-contracts/changliao-component-registry.json` in the same change.

The canonical file is:

- [畅聊 · HTML → Figma 设计系统](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78/%E7%95%85%E8%81%8A-%C2%B7-HTML-%E2%86%92-Figma-%E8%AE%BE%E8%AE%A1%E7%B3%BB%E7%BB%9F?node-id=30-8&t=87RseiFlUNCili4h-0)

Use a concrete node URL in every completion report. Build it as:

`https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78/<encoded-file-name>?node-id=<node-id>`

The ledger is the source for known page node IDs: Profile `19:5`; Contacts/Friend `19:3`; Messages/Chat `18:7`; Discovery/Moments `19:4`; Feedback `19:7`; Components `18:5`; Foundations `18:4`. Obtain a newly created or changed node ID directly from Figma; never invent one.

## Delivery workflow

1. Read `AGENTS.md`, `docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md`, the approved plan, and `docs/ui-development-figma-workflow.md`.
2. Claim the affected files. Add a registry entry or amend it with Flutter file, HTML tag, Figma key, props, variants, states, and token mapping.
3. Run a focused test before implementation and record the observed red result.
4. Update Figma first, then refresh the export ledger and registry.
5. Implement the smallest end-to-end change. UI controls must invoke a real public application gateway/controller and visibly handle saving, success, failure, loading, empty, disabled and destructive confirmation states as applicable. A UI-only route is incomplete.
6. Update Flutter and HTML through registered shared components and tokens. Keep business state authoritative in business APIs and Matrix only in the encrypted communication domain.
7. Run focused green tests, `python scripts/verify_ui_contract.py`, Flutter analysis/tests, HTML tests when affected, and `pwsh -NoProfile -File scripts/verify.ps1`.
8. Record the Figma UI review and exact URL in `docs/verification/<YYYY-MM-DD>-ui-review.md` or the direct-commit verification record. Commit code, ledger, registry, tests and evidence together.

## Functional acceptance

For settings and profile/contact changes, test the complete loop: open → edit → save → API success → immediate return-page update → reload/app restart persistence. Test a failed write and retain the user draft with an explicit error. When a value affects another screen (for example a contact remark in the chat list or a profile nudge in a chat), prove that screen receives the authoritative updated value.

## Completion record

State all of the following in the final response and verification file:

- changed Flutter/HTML/Figma component or page;
- exact Figma page/node URL and the local ledger path;
- registry path and token/variant/state result;
- red and green command results, analyzer/test/contract/verification outcomes;
- functional end-to-end result and any installed build/deployment evidence.

If Figma changed, explicitly say: `Figma 已修改：<Figma URL>`.

## References

- Read [page-links.md](references/page-links.md) when choosing the existing target page or composing a node URL.
- Read `docs/ui-development-figma-workflow.md` for the manual review template and enforced drift checks.
