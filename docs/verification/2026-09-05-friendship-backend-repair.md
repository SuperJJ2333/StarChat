# Friendship backend repair verification

Date: 2026-09-05
Plan: docs/superpowers/plans/2026-09-05-friendship-backend-repair.md

Red evidence (executed before corresponding implementations):
- `py -3.12 -m pytest tests/business_api/friendship/test_friend_request_flow.py -q`: 3 failed / 3 passed, 17.07s. Requester lacked saved remark and HIDE_BOTH preference; outgoing accepted request list was empty.
- `py -3.12 -m pytest tests/business_api/friendship/test_friend_request_flow.py -k directional -q`: 8 failed / 3 passed / 6 deselected, 30.58s. Restrictive contact settings incorrectly allowed viewing moments.

Green evidence:
- After projection/ownership implementation: friendship suite 26 passed, 69.57s.
- Final combined friendship + moments suite: 49 passed in 126.90s; see artifacts/2026-09-05/friendship-deploy/backend-friendship-green.txt. Targeted runtime AST parsing also passed.

Specification review:
- Incoming projection retained plus additive direction field; outgoing rows project target business/Matrix identity and original application greeting.
- Listing remains limited to requests where actor is requester or target. Requester cannot accept own outgoing request (404 test); unrelated actor gets empty list.
- Preferences apply to requester-owned contact record. Receiver remains DEFAULT until changing own settings.
- HIDE_BOTH needs no database migration: existing columns are unconstrained VARCHAR(30).
- Moments policy enforces author HIDE_MINE and viewer HIDE_THEIRS; HIDE_BOTH and CHAT_ONLY/ONLY_CHAT deny both directions. Own posts remain visible. Same policy runs before per-post PUBLIC/FRIENDS/INCLUDE/EXCLUDE filtering.

Quality/security review:
- Production-source diff inspected: only three requested runtime files differ, no unrelated WIP in overlay files.
- No authentication/RBAC/token changes, no server Matrix messaging, no financial writes, no migrations, no production writes by this agent.
- Existing cross-module read pattern is preserved; no cross-module table writes added.
- Full verify.ps1 and generated OpenAPI integration delegated to root to avoid concurrent common artifact modifications.
- Existing stored contact preferences are not migrated between owners; fix applies to subsequent accepts. Root may assess historical affected rows separately.

