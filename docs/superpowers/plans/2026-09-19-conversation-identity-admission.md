# Conversation identity admission implementation plan

Goal: enforce identity admission before message-list rows are exposed.
Architecture: pure local evidence classifier and durable account cache before existing identity resolver; pending count on snapshot; one UI recovery notice; asynchronous convergence completion refresh. Flutter/Dart, Matrix metadata, SharedPreferences, HTML demo.
Authorization: [accepted specification](../specs/2026-09-19-conversation-identity-admission.md); user explicitly requested further repair after the described design.

- [x] Root owns new conversation_identity_admission.dart and tests, matrix_e2ee_client.dart snapshot/model integration, conversation_identity_resolver.dart fallback guard, matrix_group_chat_adapter.dart explicit type metadata, docs. Write failing tests and confirm red before implementation.
- [x] UI owner owns matrix_home_page.dart, separate widget test, frontend demo/registry. Single recovery notice with retry, no physical room names, completion refresh/account guard. Test first and HTML parity.
- [x] Verify real SDK missing-identity → pending → metadata → single-row, restart/offline retention, group preservation, no mutation; run focused then full Flutter/analyze.
- [x] Specification compliance followed by quality/security review. Preflight/run relevant verify/UI/frontend gates; document reused backend evidence for unchanged inputs where workflow permits.
- [ ] Merge/push only reviewed source, preserve unrelated root edits. Build and publish new mobile version under existing authorization, verify fixed Android signer; provide updated iOS candidate for enterprise re-sign. Never label 2137 as containing later changes.
