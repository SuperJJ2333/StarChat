# Cache and entry optimization

User-authorized five-item follow-up to 96ef29c. Reuse existing UI tokens, preserve E2EE and authoritative direct-conversation identity. No new approval needed for the requested reversible fixes.

1. Favorites: inspect vault/panel lifecycle; cache bounded compressed previews per account/media version, merge concurrent loads, persist securely where possible, keep GIF original for sending. Long press offers deletion invoking the vault's real encrypted removal flow. Tests cover repeated open, bounded preview, delete failure/success.
2. Member history results: real sender avatars/remarks on all result rows, readable media placeholders ([语音消息], [图片消息], etc.), correct jump retained. Test member filter and multimedia rows.
3. Startup: display Messages shell immediately, restored Matrix local data first; refresh in background without a blocking loading page. Maintain authentication/account isolation and error/retry handling. Prove delayed sync does not block cached list.
4. Friend message entry: measure/trace waiting boundaries, reuse authoritative cached room and enter before optional network hydration; coalesce resolution, preserve creation/permission semantics. No guessing room IDs or duplicate direct rooms. Test slow backend/cache hit/miss.
5. Discovery badge: count unseen newly visible Moments independently of interaction notifications, persist viewing boundary per account, refresh on resume/open; show red numeric badge (99+ cap), clear only on successful feed viewing. Test initial/update/view/error/account switch.

Ownership: root app_home/startup/room navigation/integration; favorites implementer vault/panel/cache files; other agents initially read-only investigate search and Moments, then scoped implementation as assigned. No overlapping file edits.

Verification: focused red/green, independent spec then quality review, full Flutter analyzer/tests and repository verify, truthful local registry/export updates (remote Figma tooling unavailable). Artifacts only docs/verification/artifacts/2026-09-06/cache-entry/. Build/install only under existing authorized Mi 6 workflow, preserve data/signature.
