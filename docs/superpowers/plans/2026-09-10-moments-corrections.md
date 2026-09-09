# Moments reaction and user profile corrections

User request 2026-09-10 supersedes prior hard-coded dark background. Use theme navigation surface for reactions, theme-aware selected/foreground/divider colors. Comment taps operate in-place in feed/personal/detail; only body taps enter detail. Avatar/name targets retain profile routing and viewer-relative interaction privacy. User profile must reuse friend-profile layout with only Add to Contacts action (preserve self/friend/pending permission states).

1. TDD comment action shared controller/helper, in-place selection/composer and own Copy/Delete on feed/personal/detail; prevent blank reaction-area taps bubbling to post detail. Preserve concurrent likes/privacy guards.
2. TDD shared friend/user profile header/layout; bounded avatar, responsive text and exactly one add action for eligible nonfriend. Preserve request page flow and private data boundaries.
3. TDD theme-aware reactions using navigation surface; root owns tokens, shared reactions widget and frontend/registry/ledger/docs.
4. Focused and full Flutter tests, analyzer, HTML/contracts and relevant repository verification; spec then quality review; build/rebuild stable Debug APK, install Redmi preserving data, verify identity/startup. No server deployment or production updates.

Ownership: comment agent features/moments pages/helpers/tests; profile agent contacts user-profile/shared profile layout/tests; root UI reaction tokens/widget/frontend/contracts/docs. Isolated existing worktree redmi-polish-20260909. Artifacts only docs/verification/artifacts/2026-09-10/moments-corrections/. Existing application must not be uninstalled or cleared; do not run Flutter drive against normal package.

Completed: 1643 Flutter tests, clean analyzer, 28 HTML tests, browser contract and full repository verification pass. Both review stages pass. Debug 0.3.73-debug/2077 rebuilt, signature/content verified, installed and started on Redmi with installed SHA256 matching final APK. Evidence: docs/verification/2026-09-10-moments-corrections.md. Remote Figma and prior server enhancements remain outside this device delivery.
