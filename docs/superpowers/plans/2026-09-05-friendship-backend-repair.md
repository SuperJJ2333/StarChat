# Friendship backend deployment repair

Status: Approved; bounded follow-up to 2026-09-03-friend-system-refactor.md, authorized by root from current user functional fix/deployment request.
Date: 2026-09-05

Owned runtime files:
- services/business-api/app/api/friendship.py
- services/business-api/app/modules/friendship/service.py
- services/business-api/app/modules/moments/visibility.py (root explicitly approved expansion)

Implementation:
1. Test requester visibility of accepted outgoing requests, peer identity and original application greeting, preserving incoming fields and participant-only listing.
2. Add direction INCOMING/OUTGOING and peer projection. Acceptance/rejection authorization remains target-only.
3. Test and correct request contact preferences to the requester's own ContactProfile. Receiver keeps independent preferences.
4. Verify HIDE_BOTH persistence in existing VARCHAR fields (no migration), and test directional moments permissions for author and viewer, including CHAT_ONLY/ONLY_CHAT compatibility.
5. Run friendship and moments suites; root integrates generated OpenAPI and full verification/deployment.

The server does not create or send Matrix greeting messages. Existing friend request introduction remains application metadata; the requesting client owns E2EE greeting delivery.
