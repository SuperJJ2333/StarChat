# Flutter–HTML–Figma UI Contract Implementation Plan

**Status:** Approved — user request on 2026-08-23  
**Goal:** Establish a checked three-way UI registry, complete the six priority feedback/contact components, remove named style literals, and make the four tab roots consume one page scaffold contract.

**Architecture:** `packages/ui-contracts/changliao-component-registry.json` is the source-of-truth mapping Flutter public widgets to HTML custom-element contracts and the checked-in Figma export ledger. Flutter stays independent of JSON at runtime; Python and Node verification read the registry. Figma drift validation is export-ledger based because this workspace has no callable authenticated Figma API. It validates every declared token, component mapping and screen count against the checked-in Figma artifact.

## File ownership

- `packages/ui-contracts/`, `tests/mobile/test_ui_component_registry.py`, `design-demo/tests/ui-component-registry.test.mjs`, `scripts/verify_ui_contract.py`: registry and executable drift checks.
- `apps/mobile_flutter/lib/ui/foundation/wechat_tokens.dart`, `apps/mobile_flutter/lib/ui/components/`: UI primitives and named styles.
- `apps/mobile_flutter/lib/features/{matrix,contacts,discovery,profile,auth}/`: public component/scaffold adoption only.
- `apps/mobile_flutter/test/ui/`, `apps/mobile_flutter/test/features/contacts/`: red/green proof.
- `docs/verification/`: exact non-Git verification evidence.

## Tasks

- [x] 1. Write focused failing Flutter, Python and Node tests for the six public components, named token consumption, scaffold adoption and three-way registry.
- [x] 2. Create the shared registry plus export-ledger drift verifier; clean stale Figma ledger completion metadata and add package scripts/tests.
- [x] 3. Add `WeChatDialog`, `WeChatToast`, `WeChatEmptyState`, `WeChatComposer`, `WeChatContactTile`, and `WeChatContactIndex` with UI_DESIGN.md props, variants, states and semantics.
- [x] 4. Move named visual values for `ModernActionButton`, `UserAvatar`, `NetworkStatusCapsule`, and auth validation feedback into `WeChatTokens`.
- [x] 5. Extend `WeChatPageScaffold` with explicit fixed background/navigation options and migrate the messages, contacts, discovery and profile roots plus their immediate empty/error states to it.
- [x] 6. Run focused tests, Flutter analyze/test, HTML registry tests, all drift checks and `scripts/verify.ps1`; record output and commit the verified change.


