# Mi 6 user feedback implementation

User authorized these eight concrete fixes. Preserve existing WeChat-style tokens and public controllers. Implementation uses independent file ownership and test-first regressions.

1. Root: GIF send path and display memory budget. Identify GIF by bytes, preserve original animation, bypass unsupported native JPEG compression, bound decode sizes and concurrent work; use previews for static media and avoid eager original downloads. Own room_page.dart, media_thumbnail.dart, bounded image widgets and root integration tests.
2. Retry task: failed messages retain timestamp position; red exclamation retries once, removes old failed local entry and creates a new outgoing entry; preserve payload/reply/mentions, prevent duplicate taps and avoid resending acknowledged events. Own Matrix timeline adapter/controller and delivery-state tests.
3. Search UI task: group picker uses avatar and authoritative remark > nickname > username, image/video filter becomes date-grouped grid with preview/play semantics. Own chat_search_page.dart and optional search-model fields, its tests. Root wires actual room metadata/loaders and correct navigator route to room before message positioning.
4. Profile task: Discovery moments first, scan second; move invitation entry into personal information above nickname; filled nickname/signature right aligned with left-aligned placeholders; add an explicit personal information row on Me while retaining header entry. Own discovery/profile files and tests.
5. Root integration: accurate local UI contract/export ledger updates and functional tests; Figma MCP/skills unavailable in this session, so do not claim remote Figma edits. No fabricated remote synchronization evidence.
6. Independent specification and quality review; full analyze/test, UI contract and repository verification. Source commit and validated debug delivery following the APK rebuild runbook if delivering to Mi 6. Signing must preserve installed data and any applicable explicit user authorization.

Artifacts: docs/verification/artifacts/2026-09-06/mi6-feedback/ only. No real message bodies, auth credentials or signing secrets in logs/Git. User-facing errors remain generic.
