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


## Retained-rotation marker consistency supplement

The SDK soft-logout branch currently updates only OlmManager.ourDeviceId after durable credentials adoption. Encryption.olmDatabase instead checks Encryption.ourDeviceId against Client.deviceID. A genuine same-account server rotation therefore can disable the retained Olm database facade, including session persistence and last-sent-key replay. This is an independently proven source gap; it is not yet the established cause of the reported B-account message delivery defect. Native inspection taken after user switched to a working account showed equal markers and must not be attributed to B.

The bounded correction captures the exact Encryption, OlmManager, prior nonempty user/device, database and recovery owner before the durable update. Both old encryption markers must equal the same prior device, proving this is the retained nondehydrated owner, and adopted user must remain equal with nonempty target device. After updateClient succeeds, recheck the exact encryption/database/owner and unchanged prior markers, then synchronously update both markers with no intervening await. Wrong-account, mismatched/dehydrated, failed persistence and revoked-owner paths must not promote access. No new Olm account, database clearing, key export, server key custody or weakened identity checks.

Required proof uses real SQLCipher and Olm: rotated client retains the identical database facade, newly updated Olm sessions persist and survive close/reopen while retained identity/history remain unchanged. Test persistence failure and owner revocation. Domain review conditionally approved these boundaries; independent quality approval is required before implementation.

## AS6 missing-key delivery supplement (2026-10-19)

Recipient Android0.4.52 now explicitly reports `the sender has not sent us the session key`. Read-only failing-sender metadata anchors the accepted event and live outbound session to the same account and session. Its intended recipient map includes all8members, while inbound historical authorization metadata is empty. This proves missing-key reception and inconsistent legacy reuse state; it does not identify the original key-loss trigger.

DOMAIN then independent QUALITY conditionally approved a bounded repair: require exact eligible target/public-key coverage for room-key ciphertexts, await every room-key chunk, and rotate future sessions when participant/device eligibility changes or historical authorization proof is missing. Preserve all old inbound sessions and never manufacture index0 authorization. New outbound is usable only after complete encrypted key-sharing and an owner/identity/device-fenced transaction; validate before transaction commit and again before publication. A valid commit preceding later revocation is not claimed rolled back. Reopen/use must revalidate. Serialize room payload preparation and encryption without recursive room-lock acquisition. No new plaintext channel, automatic device trust or secret-server access.

Temporary OTK/network failures retain existing retryable message failure behavior. All-target readiness may delay a group send; it must never silently skip a legitimate target and report success. Already-sent historical ciphertext is not automatically repaired by future-session rotation.
