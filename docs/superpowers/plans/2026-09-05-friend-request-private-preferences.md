# Friend request private preferences repair

Status: approved through the user’s explicit privacy bug repair instruction; bounded task delegated by Root.

Owner: friend_privacy agent. Files: friendship/service.py and optional api/friendship.py; friendship API regression tests; Flutter friend_request_review_page.dart, friend_acceptance_coordinator.dart and their tests. No forwarding files, builds, deployment or commits.

1. Reproduce incoming request remark/tag disclosure and acceptance cache copying with failing tests.
2. Keep request response fields compatible but return null remark / empty tags to recipient; requester retains own values. Verify unrelated actors cannot read requests, contacts or tags.
3. Remove private preference presentation from review page, including old API payloads. Acceptance uses only existing current-account contact preferences.
4. Run focused Python and Flutter tests, format/analyze changed Dart files. Root owns full verification and deployment.
5. Record red/green and specification then quality/security review under docs/verification/artifacts/2026-09-05/privacy-forward/.

No schema, authentication, financial or E2EE changes. Figma work deferred per user authorization relayed by Root.
