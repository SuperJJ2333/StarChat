# Moments reactions UI implementation

User-authorized scope: shared dark rounded reactions area in feed/detail/personal feed; avatar/name/profile links, subtle separators, detail comment spacing, timestamps, selected reply highlight, own comment Copy/Delete, immediate like avatars and restrained 700 ms feedback. Preserve shared viewer remark/avatar resolver, emoji/media widgets, privacy and cache behavior.

1. UI: shared tile/reactions component using #333 background, #292929 selection, high contrast text, white 10% dividers; horizontal liker avatars, adaptive comment layout; reduced-motion-safe like feedback. Tests first.
2. State/navigation: optimistic like/unlike includes current user's avatar projection, rollback preserves concurrent comments, prevent duplicate writes; detail propagation; comment selection and Copy/Delete; unified person navigation; optional comment timestamp parsing. Tests first.
3. API: only viewer/self and viewer's current friends may appear in likes/comments, including replies and comment media access. Add comment timestamps. Cover friend, stranger, removed friend, blocked/hidden and parent privacy in isolated tests. Preserve post privacy, public-only identity DTO, E2EE boundaries.
4. Align local HTML and component registry/design ledger; remote Figma unavailable, record pending truthfully.
5. Focused tests, analyzer, repository verification, spec-compliance then quality/privacy review, verification report. No production API deployment in this UI-only request.

Ownership: UI implementer owns lib/ui/moments/wechat_moment_tile.dart, new reactions widgets and their tests; state implementer owns lib/features/moments/ pages/models and tests; API implementer owns moments API/service/media access and backend tests; root owns frontend, contracts, docs and integration verification. Shared worktree: .worktrees/redmi-polish-20260909. No app uninstall/data clear. No live account writes.

Completed 2026-09-10: all implementation steps and isolated verification complete; independent specification and quality/privacy reviews passed after race fixes. Root also owns the successful-block privacy invalidation in business_api_client.dart and its core regression test. Source retained on the existing work branch. See docs/verification/2026-09-09-moments-reactions-ui.md for full results and remote Figma/runtime deployment limitations.
