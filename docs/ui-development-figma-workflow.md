# UI Development and Figma-Assisted Change Workflow

**Status:** Approved — 2026-08-23
**Scope:** Flutter mobile UI, HTML design demo, Figma export ledger, and user-visible product/content names.

## Required sequence

1. **Classify and register** — Before UI implementation, add or update the component/page entry in `packages/ui-contracts/changliao-component-registry.json`: Flutter name/file, HTML tag, Figma key, public props, variants, states, and token mappings.
2. **Agent-owned Figma synchronization** — The Agent builds or amends the matching Figma component/page with token bindings, then exports/updates `design-demo/artifacts/figma-state.json` before coding. An authenticated Figma API is used whenever available; otherwise the Agent refreshes the versioned export ledger through the configured Figma export path. Developers review Figma UI quality only and do not export, update ledgers, or synchronize contracts.
3. **Red test** — Add a focused Flutter or contract test for the missing behavior/state and run it to establish the intended failure.
4. **Implement through public components** — Business pages consume widgets in `apps/mobile_flutter/lib/ui/`; they do not create unregistered components or hardcode visual values. Reuse `WeChatPageScaffold` and fixed background/navigation tokens.
5. **Token parity** — Add any new color, typography, spacing, radius, opacity, motion, or elevation token to Flutter, HTML, Figma, and the registry in the same change.
6. **Green and drift proof** — Run the focused test, `python scripts/verify_ui_contract.py`, Flutter analysis/tests, and `npm test` from `design-demo`.
7. **Merge gate** — `pwsh -NoProfile -File scripts/verify.ps1` must pass. It includes the UI-contract drift gate.

## Enforced checks

The UI-contract verifier rejects:

- missing or mismatched Flutter names/files/props, HTML tags, and Figma component keys;
- Figma/HTML/Flutter token drift for mapped colors, typography, spacing, and radius;
- screen-registration-count drift;
- direct `CupertinoPageScaffold` usage in feature pages, except the explicitly documented auth success-only route;
- completion ledgers with pending validations.

## Naming rules

- Public product name: **畅聊 ChatFlow**; compact in-product name: **畅聊**; account label: **畅聊号**.
- Public CAIBI asset name: **点钻**; red-packet label: **畅聊点钻红包**.
- `CAIBI` remains internal only: schema, API `asset`, ledger/events, migrations and code identifiers. OpenAPI titles, health `service`, Docker defaults and TOTP issuer require a separate API/operations compatibility review.
- New widgets use `WeChat` purpose-prefixed PascalCase names; HTML custom elements use `app-kebab-case`; Figma component names use the corresponding `app-kebab-case` key.

## Developer Figma visual-review record

The developer adds the following filled template to the PR description. For direct commits, add it to `docs/verification/<YYYY-MM-DD>-ui-review.md` and include that file in the same commit. The Agent links the recorded review in the implementation plan and verification evidence.

```md
## Figma UI Review

- **Figma file / export ledger:** `<URL or design-demo/artifacts/figma-state.json>`
- **Reviewed nodes/pages:** `<Figma keys and page IDs>`
- **Components and states checked:** `<components; default / pressed / disabled / loading / error / empty>`
- **Token and layout result:** PASS / FAIL — `<color, type, spacing, radius, hierarchy findings>`
- **Issues:** None / `<severity, location, required correction>`
- **Reviewer:** `<name>`
- **Reviewed at:** `<ISO-8601 timestamp>`
```

A PASS record is required before merge. This is an **initial manual review gate**: reviewers verify the PR description or direct-commit verification file. When CI can read PR-platform metadata, the repository will add automated validation for both PR descriptions and direct-commit review records. A production hotfix may merge with `Deferred: <reason>`; the review record must be added on the next working day.

## Release checklist

- [ ] Agent updated the registry entry, Figma export ledger and screen registration; the developer completed a visual-design review only.
- [ ] All default, pressed/hover, disabled, loading, error and empty states represented where applicable.
- [ ] User-visible text uses approved brand/asset terms; internal CAIBI identifiers remain stable.
- [ ] Focused red/green proof, drift verifier, Flutter analysis/test, HTML tests and repository verification recorded.
