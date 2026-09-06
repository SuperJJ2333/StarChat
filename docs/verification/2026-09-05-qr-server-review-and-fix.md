# QR server deployment review and fixes

Scope: `services/business-api/app/api/groups.py`, necessary Matrix group invitation interface, and `tests/business_api/groups/`. Parent owns the approved deployment plan, production bundle and deployment. No financial gateway method changed in this work.

## Findings and behavior

- App groups use private rooms. A scanner has no Matrix invitation, so normal client join failed. QR direct joins now invite through the token issuer's current moderator identity before joining as the requester. Approval uses the deciding moderator. Both business account status and current moderator membership/power are checked; banned requesters are rejected. Synapse's ordinary client invite/join authorization remains authoritative. No public join rule or forced administrative join is used.
- Token issuance retries now return 409 rather than mint additional credentials or store token plaintext for replay.
- QR operation records, group database mutations and audit entries now commit together. Failed operations roll back their operation record and can retry with the same key. Successful redeem/revoke/approval replays return the actual response.
- Revoke key conflicts are checked before modifying a token. Actor row locks serialize QR operations for a requester even with different keys, preventing duplicate pending requests; token locks serialize redemption/revocation and request locks serialize competing approval decisions.
- Existing QR enabled/approval defaults and disabled QR issue behavior remain consistent with the Flutter client. Existing auto-join implementation is unchanged.

## Evidence

Initial red run: group suite **7 failed, 9 passed**. Failures reproduced repeated issuance, failed-join false replay, ban/current-inviter checks, and both direct/approval private-room joins after the fake enforced invitation membership. New gateway contract suite initially **4 failed**, each due to the missing invitation method.

Final focused run: `py -3.12 -m pytest tests/business_api/groups tests/business_api/identity/test_matrix_provisioning.py -q` — **30 passed**. Includes HTTP invite-before-join, upstream failure redaction, missing token handling, private room lifecycle, ban/issuer departure/demotion rejection, failed redeem retry, approval failures for inactive/banned users and upstream join failure, accurate success replay, disabled/expired/revoked tokens, and token hash storage. Full output: [qr-server-green.txt](artifacts/2026-09-05/group-qr-video/qr-server-green.txt).

Read-only inspection of the installed Synapse source at `/usr/local/lib/python3.12/site-packages/synapse/`: `event_auth.py` verifies current inviter membership, invitation power and target ban, and requires an invitation for private-room joins. `rest/client/room.py` routes invitations through `update_membership` and passes the join content to the membership handler. Source excerpt: [installed-synapse-invite-join-source.txt](artifacts/2026-09-05/group-qr-video/installed-synapse-invite-join-source.txt).

`ruff` is unavailable in the local Python 3.12 runtime (`No module named ruff`); no lint success claimed. The duplicate full verification run was stopped at the parent's request during Business API/Worker tests; the parent owns the definitive full run. Partial output is recorded separately in [qr-server-verify.txt](artifacts/2026-09-05/group-qr-video/qr-server-verify.txt). PostgreSQL concurrency and live private-room behavior require deployment integration validation; SQLite tests establish the application outcomes, not PostgreSQL lock execution.

## Review

Specification review: credentials remain hash-only, QR sharing requires current moderator authorization, public settings gate redemption, pending approval never immediately joins, and financial/E2EE payload paths are untouched.

Security review: no new administrative forced joins or plaintext logging; invitations are performed by a verified moderator through normal Matrix authorization. Inactive requesters and bans block approval, key conflicts do not mutate state, and failed operations do not persist completion. Temporary credentials remain local variables in the gateway.
