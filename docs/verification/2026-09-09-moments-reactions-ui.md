# Moments reactions UI verification

Work began 2026-09-09 and verification finished 2026-09-10 (Asia/Hong_Kong). Worktree: `.worktrees/redmi-polish-20260909`, branch `codex/redmi-polish-20260909`, base `1d5415d2`.

## Implemented behavior

| Requirement | Implementation and isolated verification |
| --- | --- |
| Dark rounded comments | Shared `WeChatMomentReactions`, #333 background, #292929 selection, 8 px radius; detail padding 14 vs feed 10; faint dividers. Widget layout tests and Flutter/HTML render inspected. |
| Comment identity/time | 30 px avatars, shared viewer remark/avatar resolver, separately clickable avatar/name, muted timestamp, local date formatting. Narrow-width/large-text layout tests pass. |
| Reply and own actions | Other comment stays selected until composer dismissal; self has Copy/Delete. Clipboard and API behavior tested. Emoji/media preview retained. |
| Liker avatars | Horizontal strip, immediate optimistic add/remove. API no longer truncates visible avatars to 20; 25-liker regression passes. |
| Like feedback | 700 ms six-particle/bounce feedback; reduced-motion and disposal covered. |
| Feed separators | Theme-aware thin border and weak shadow; dark-mode regression checks actual decorated surface. |
| Stranger privacy | API filters self/current allowed friends, counts and hidden reply metadata; old signed comment media URLs recheck live relationships. Client filters retained snapshots using current contacts and permissions. |
| Navigation/races | Shared pending write prevents cross-route duplicate likes. Privacy revision rejects pre-block completion/rollback. Reaction-only callbacks preserve newer parent comments after detail is popped. |

## Red / green evidence

- UI first test failed because the reaction group/avatar layout did not exist; final focused UI suite: 10 passed. HTML first tests failed on missing avatars and detail/selection state, then passed.
- API initial five privacy cases failed: 3 likes returned versus 2 visible. Expanded new suite: 9 passed, including 25 visible likers, 80 comments with bounded queries, removed friends, blocks in either direction, local permissions, excluded viewers, closed entry, hidden parents and saved media URLs. Relevant API/media regression: 34 passed; privacy regression: 27 passed.
- State tests reproduced missing optimistic avatar, duplicate pending writes, privacy completion resurrection and a popped detail rollback erasing a newer feed comment. Final focused state suite: 10 passed. Successful block invalidation test failed before the change and passed afterward; rejected block does not invalidate.
- The first full Flutter run found one obsolete `Container.color` assertion after moving the surface into `BoxDecoration`; the corrected dark-mode suite passed. Final source: **1630 Flutter tests passed** in 91 seconds; full static analysis reported **no issues**. Logs: `artifacts/2026-09-09/moments-reactions-ui/flutter-completion.log` and `analyze-completion.log`.

## Repository checks

- `scripts/verify.ps1`: repository/deployment/template policies, infra (60), Getui (28), Matrix Bot (9), Business API/Worker (1510 passed, 37 skipped) passed. It then stopped on the old hard-coded 17-component count.
- Updated that guard to 18, explicitly requiring `WeChatMomentReactions`. Re-ran the unchanged remainder of the original script from Flutter boundaries via an artifact copy with the worktree root set explicitly. Original script was not modified. Boundaries: 66 passed. UI contract: 18 components / 330 screens. API import, AST (197 files), Alembic, OpenAPI and Compose checks passed; remainder ended `Verification: PASS`. Unchanged 11-minute backend suite was not repeated for that assertion update.
- HTML Node tests: 28 passed. Headless Chrome screen/layout contract: passed. Screenshots: `artifacts/2026-09-09/moments-reactions-ui/html-detail.png` and `flutter-reactions.png`.
- Body/name/time contrast against #333: 11.29:1 / 8.30:1 / 6.03:1.
- Baseline warnings remain: Starlette/httpx, Getui Pydantic class config, Alembic path separator, and Flutter SVG filter support. Skips are not counted as passed.

## Review and design evidence

Specification review passed after block invalidation and privacy revision fixes. Independent quality/security review passed after reaction-only parent callbacks fixed the concurrent-comment rollback regression.

Flutter tile and reactions component, HTML `app-moment-reactions`, `frontend/artifacts/figma-state.json`, and `packages/ui-contracts/changliao-component-registry.json` updated together. Existing Figma target: [Moments node 19:4](https://www.figma.com/design/zpzwTbnj1hqx80tyRygX78?node-id=19-4). Remote Figma was **not modified**: no callable editor tools in this session. Local ledger clearly marks synchronization pending; its older complete-export fields are not evidence of this revision's remote synchronization.

This change is source/test delivery. No production API deployment, new APK installation, live-account writes or Redmi runtime/performance claims are included. The previously installed Debug 2075 remains the device build; the new UI and server privacy changes require a subsequent build/deployment before they can be checked on that device.
