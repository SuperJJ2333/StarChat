# UI Development and HTML Demo Workflow

**Status:** Approved — 2026-09-10. Supersedes `docs/ui-development-figma-workflow.md` (retired): UI changes no longer require Figma synchronization; the HTML design demo is the required visual deliverable.
**Scope:** Flutter mobile UI, the HTML design demo under `frontend/`, the component registry, and user-visible product/content names.

## Required sequence

1. **Classify and register** — Before UI implementation, add or update the component/page entry in `packages/ui-contracts/changliao-component-registry.json`: Flutter name/file, HTML tag, public props, variants, states, and token mappings. The registry is Flutter–HTML only; do not reintroduce a Figma ledger.
2. **HTML demo first** — Update the matching screen in the HTML design demo (`frontend/src/catalog/`, `frontend/src/styles/tokens.css`) so reviewers can open the demo page and see the intended layout, states, and tokens before or alongside the Flutter change. The demo is the visual source of record for review.
3. **Red test** — Add a focused Flutter or contract test for the missing behavior/state and run it to establish the intended failure.
4. **Implement through public components** — Business pages consume widgets in `apps/mobile_flutter/lib/ui/`; they do not create unregistered components or hardcode visual values. Reuse `WeChatPageScaffold` and fixed background/navigation tokens.
5. **Token parity** — Add any new color, typography, spacing, radius, opacity, motion, or elevation token to Flutter, the HTML demo, and the registry in the same change.
6. **Green and drift proof** — Run the focused test, `python scripts/verify_ui_contract.py`, Flutter analysis/tests, and the frontend HTML tests (`npm test` from `frontend/`).
7. **Merge gate** — `pwsh -NoProfile -File scripts/verify.ps1` must pass. It includes the UI-contract drift gate.

## Enforced checks

The UI-contract verifier rejects:

- missing or mismatched Flutter names/files/props and HTML tags;
- HTML/Flutter token drift for mapped colors, typography, spacing, and radius;
- screen-registration-count drift;
- reintroduction of a `figma` section or Figma keys in the registry;
- direct `CupertinoPageScaffold` usage in feature pages, except the explicitly documented auth success-only route.

## Naming rules

- Public product name: **畅聊 ChatFlow**; compact in-product name: **畅聊**; account label: **畅聊号**.
- Public CAIBI asset name: **点钻**; red-packet label: **畅聊点钻红包**.
- `CAIBI` remains internal only: schema, API `asset`, ledger/events, migrations and code identifiers. OpenAPI titles, health `service`, Docker defaults and TOTP issuer require a separate API/operations compatibility review.
- New widgets use `WeChat` purpose-prefixed PascalCase names; HTML custom elements use `app-kebab-case`.

## Functional acceptance

For settings and profile/contact changes, test the complete loop: open → edit → save → API success → immediate return-page update → reload/app restart persistence. Test a failed write and retain the user draft with an explicit error. When a value affects another screen (for example a contact remark in the chat list or a profile nudge in a chat), prove that screen receives the authoritative updated value.

## Completion record

State the following in the final response and `docs/verification/<YYYY-MM-DD>-ui-review.md` (or the direct-commit verification record):

- changed Flutter/HTML demo component or page and the demo page path (for example `frontend/index.html#/...` or the catalog screen id);
- registry path and token/variant/state result;
- red and green command results, analyzer/test/contract/verification outcomes;
- functional end-to-end result and any installed build/deployment evidence.

## Release checklist

- [ ] Agent updated the registry entry and the HTML demo screen; the developer reviewed the demo visually.
- [ ] All default, pressed/hover, disabled, loading, error and empty states represented where applicable.
- [ ] User-visible text uses approved brand/asset terms; internal CAIBI identifiers remain stable.
- [ ] Focused red/green proof, drift verifier, Flutter analysis/test, HTML tests and repository verification recorded.
