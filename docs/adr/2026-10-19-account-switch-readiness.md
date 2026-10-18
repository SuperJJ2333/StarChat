# Retained-account handoff and fresh-credential sync ownership

2026-10-19. DOMAIN and independent QUALITY conditionally approved design before product edits. User-authorized existing lifecycle repair; no new authentication/E2EE policy. Baseline16905e7f/runtime62dc76f2.

## Proven failures

readiness-red-r1 was fixture compilation failure only. readiness-red-r2 compiles and fails two intended behavioral assertions: selection leaves secure.startupProjectionCoordinator null/retired; a real SDK old-token /sync response with M_UNKNOWN_TOKEN delivered after successful retained broker login clears the newly adopted accessToken. No real account credentials or messages were used.

Source also shows softLoggedOut init commits new credentials and returns without restarting sync. The prior old-token error can remain the cached SDK status; MatrixSdkE2eeClient.sync calls the raw HTTP sync API and does not publish/process SDK loop status. This supports a stale-status/first-poll wait hypothesis, but the user's actual10s duration is not yet independently attributed.

## Decision for review

1. After account selection has validated target client identity and continuity and installed _client, bind a new projection coordinator through the same public internal lifecycle wiring used by constructor/resume. It starts unverified; only existing business-authenticated prime may mark verified/write. Old coordinator remains retired. Original startup snapshot fallback remains bound to _originalRoomDisplayOwner, so rebinding cannot revive it. Add A→B→A, same-room-ID, pending SQL/privacy and failed-selection assertions.
2. In retained token login, quiesce the old SDK sync before consuming broker login and adopting credentials. await abortSync must retain actual transaction drain and generation blackholing; it must not clear database/key material. Existing raw server user/device checks, retained Olm upload, authorized device rotation and continuity persistence remain unchanged. A late old error/success must not mutate the newly adopted owner.
3. Only after successful new credentials, key upload/rotation and final continuity persistence, start the normal background SDK loop with an immediate first poll(timeout0), clearing only obsolete retry delay from the retired credentials. Add a narrow SDK startSyncImmediately method; existing backgroundSync setter, watchdog abort/restart behavior and general retry policy stay unchanged. It uses the existing _sync ownership/processing/error handling, not handleSync utility or synthetic connected status. Require exact current client/nonrevoked access before starting. It may run in background and must report genuine current-session failures. Failure before this point cannot start a loop.
4. Preserve logout/selection serialization and asynchronous close safety. Add shared Android/iOS regression coverage for device rotation, temporary secure-storage failure and true fingerprint/database/account mismatch; no mismatch adoption, fresh-device creation or key deletion.

## DOMAIN conditions (2026-10-19)

The reviewer confirmed both RED causes and approved this bounded design for independent QUALITY review. If new-owner binding fails, retire that coordinator and close the replacement client through existing cleanup. Complete abortSync before credential adoption, including its transaction drain. Do not call the backgroundSync setter before the immediate first poll, and do not add a second startup to the new-device init path. Set public credentialsInvalid=false only after continuity persistence succeeds; before restarting, recheck exact client, nonrevoked lifecycle and target identity. Reset only the retired credentials' retry delay; real current errors and subsequent retry policy remain intact. Required implementation coverage includes late old success/401, real new401, persistence/rotation failure, same-room A→B→A isolation and existing iOS credential safeguards. Actual >10s attribution and iOS native verification remain open evidence items.

## Alternatives

QUALITY additionally requires same-client login attempt isolation: serialize the entire token-login operation, not just client acquisition, and compare the finally adopted user/device/token before restart. Tests must hold actual SDK transaction processing before broker login, and prove repeated immediate-start calls do not reset a current session's backoff or create a second loop.

- Adopt the narrow lifecycle wiring above: preserves old E2EE state and avoids a retired request poisoning new credentials.
- Merely hide service feedback or shorten global backoff: does not fix credential loss and would disguise real failures; rejected.
- Clear/recreate client identity: unnecessary data loss/identity replacement; rejected.

## Required evidence

Actual SDK old401/old-success fencing; cached old error followed by immediate new timeout0 sync; genuine new error still reported; no restart on login/rotation/persistence failure or superseded owner. Real encrypted local history/AEAD capture after A→B→A, same room IDs without cross-account content, held deep SQL/cache and disposal. Preserve original cold-start held-preflight/SDK tests, scoped mobile gate and fixed signer Android runtime. iOS native/device verification must be explicitly distinguished from Windows shared fixtures.
