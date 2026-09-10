# iOS native calls / session storage (0.3.53)

Minimum iOS/iPadOS: **16.0**. Keep the existing HY9Q7Q35S5 / com.liuhetong.liuhetongMobile signing identity and SQLCipher framework ahead of inherited linker flags. No extra camera entitlement is added; supported iOS16+ capture sessions enable multitasking camera access at runtime.

## Integration

One explicit `chatflow.shared` FlutterEngine starts at process launch, including a PushKit background launch. SceneDelegate attaches that same engine. The Main storyboard remains a resource but has no launch entry, so no implicit duplicate engine/plugins are created. FlutterSceneDelegate continues forwarding scene and plugin events.

`chatflow/ios_calls`: every Dart command requires a per-AppHome `owner` string. start binds that owner; an initial binding preserves cold-start PushKit actions, and a replacement owner clears old calls/actions. Other commands reject mismatched owners, including a delayed stop from an old account. Call UUIDs, cancellation tombstones and action cleanup use both roomId and callId. start/getTokens return nullable voipToken/apnsToken; stop ends calls, clears queued actions and persisted active-registration flag. Tokens are device identifiers, never account credentials. ready/getPending drain `{actions:[...]}` FIFO. Native event method `event` delivers `{owner,action,callId,roomId,at,muted?}`; token changes use `tokensChanged` with `{owner,voipToken,apnsToken}`. Queued actions capture the current owner; only ownerless cold-start actions are assigned the owner of their first ready/getPending drain. `returnToCall` carries `{owner}` and restores the in-app call interface after system PiP restoration.

showIncoming accepts `{callId,roomId,video,expiresAt}` (epoch milliseconds). reportState accepts the same identifiers, phase, video and incoming; outgoing `connecting` with incoming=false creates a CXStartCallAction. Incoming answer is fulfilled only on matching `connected`. Terminal phases ended/idle/failed/permissionDenied clean up. The initial 30-second deadline also bounds waiting for the encrypted session. endCall requires both callId and roomId and rejects missing, invalid or mismatched identifiers. Only stop performs bulk call cleanup.

PushKit payload uses `{aps:{},call_id,room_id,video,expires_at}` (epoch seconds). It is immediately reported to CallKit before PushKit completion. Expired, invalid and logged-out deliveries are reported then ended; duplicate active UUIDs never end the original call. Ordinary APNs cancellation requires `{call_action:'end',call_id,room_id}` and binds both identifiers. No message text or keys enter this channel.

setPipVideo accepts real remote streamId and ownerTag (peer connection ID), rejecting local-stream fallbacks. AVSampleBufferDisplayLayer renders decoded WebRTC frames in the system video-call PiP controller. startPip returns false if unavailable/not yet ready; system lifecycle owns actual start/stop. stopPip stops the presentation. Ending a call removes the track renderer and audio gate. Unsupported capture hardware cannot keep the local camera active.

Ordinary foreground APNs copies are suppressed because existing Matrix foreground local notifications already apply user preferences. Local notification callbacks still delegate to the plugin; ordinary remote callback completion is handled directly. `chatflow/apns` additionally provides getNotificationSettings/openNotificationSettings without changing app UI.

## Secure session bridge (ADR0011)

`chatflow/ios_secure_session` read/write/delete accepts `liuhetong.matrix_database_key.v1`, `liuhetong.business_session.v1`, the fixed account metadata keys `liuhetong.active_matrix_scope.v1` and `liuhetong.matrix_account_slots.v1`, and database keys suffixed with exactly 64 lowercase hexadecimal characters (ADR0063). All use the existing flutter_secure_storage_service and nonsynchronizable generic-password account. No accessibility filter, access group change, or iCloud fallback is used. Only errSecItemNotFound is absence. A legacy successful read updates accessibility in place to AfterFirstUnlockThisDeviceOnly, then verifies identical bytes, identifiers and access group. Failed reads/migration/write/verification return FlutterError and never trigger repair, deletion, rekeying or fallback creation. Only an initial unambiguous absence permits SecItemAdd. delete is explicit and key-scoped.

Before first unlock after reboot, Keychain access can still fail. Old WhenUnlocked items must first be read while unlocked to migrate. No application PIN/recovery policy is changed here.

## Verification status

Native XCTest was authored first in commits ff7ff5d (calls) and 0f3f978 (Keychain), with later owner/binding regression tests. Initial red execution was unavailable on the Windows implementation host. The macOS CI subsequently copied unchanged IOSCallState.swift and IOSSecureSession.swift into a SwiftPM target and ran RunnerTests.swift with only its module import replaced. This executed the real Foundation/CryptoKit/Security core and injected Security failure paths: **24 tests passed, zero failures** (15 Keychain and9 call/owner tests).

GitHub run34160519073, job101861235226, commit5d23aa80d390d48c2da5884060af440b91d752fc successfully compiled and exported the full signed iOS archive, including CallKit/PushKit/AVKit/WebRTC/Flutter/UIKit adapters. IPA verification and artifact preservation passed. Candidate **0.3.53/build58**, IPA SHA256`6428335ad38f7ecc24e25463b43f74bacf7626a65e63f032c1fca3c378c0778c`. The upload step was deliberately skipped; root owns independent artifact review and TestFlight upload. Evidence is retained in docs/verification/artifacts/2026-09-08/ios-0353/native-build-34160519073.log in the parent workspace.

Real PushKit, CallKit audio activation, cold start/locked Keychain, device camera/background duplex audio and PiP still require the user's iPad. A successful native test/archive does not establish those device results.

Sources checked: Flutter UIScene migration and local Flutter engine/scene integration tests; flutter_webrtc0.12.11 public native headers; flutter_secure_storage9.2.4 exact service/query implementation; Apple's AVPictureInPictureVideoCallViewController API. The artifact verifier must inspect the actual IPA for minimum OS, signing, APNs and SQLCipher load order.
