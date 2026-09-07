# iOS native calls / session storage (0.3.53)

Minimum iOS/iPadOS: **16.0**. Keep the existing HY9Q7Q35S5 / com.liuhetong.liuhetongMobile signing identity and SQLCipher framework ahead of inherited linker flags. No extra camera entitlement is added; supported iOS16+ capture sessions enable multitasking camera access at runtime.

## Integration

One explicit `chatflow.shared` FlutterEngine starts at process launch, including a PushKit background launch. SceneDelegate attaches that same engine. The Main storyboard remains a resource but has no launch entry, so no implicit duplicate engine/plugins are created. FlutterSceneDelegate continues forwarding scene and plugin events.

`chatflow/ios_calls`: start/getTokens return nullable voipToken/apnsToken; stop ends calls, clears queued actions and persisted active-registration flag. Tokens are device identifiers, never account credentials. ready/getPending drain `{actions:[...]}` FIFO. Native event method `event` delivers `{action,callId,roomId,at,muted?}`; token changes use `tokensChanged`. `returnToCall` restores the in-app call interface after system PiP restoration.

showIncoming accepts `{callId,roomId,video,expiresAt}` (epoch milliseconds). reportState accepts the same identifiers, phase, video and incoming; outgoing `connecting` with incoming=false creates a CXStartCallAction. Incoming answer is fulfilled only on matching `connected`. Terminal phases ended/idle/failed/permissionDenied clean up. The initial 30-second deadline also bounds waiting for the encrypted session. endCall accepts an optional callId.

PushKit payload uses `{aps:{},call_id,room_id,video,expires_at}` (epoch seconds). It is immediately reported to CallKit before PushKit completion. Expired, invalid and logged-out deliveries are reported then ended; duplicate active UUIDs never end the original call. Ordinary APNs cancellation requires `{call_action:'end',call_id,room_id}` and binds both identifiers. No message text or keys enter this channel.

setPipVideo accepts real remote streamId and ownerTag (peer connection ID), rejecting local-stream fallbacks. AVSampleBufferDisplayLayer renders decoded WebRTC frames in the system video-call PiP controller. startPip returns false if unavailable/not yet ready; system lifecycle owns actual start/stop. stopPip stops the presentation. Ending a call removes the track renderer and audio gate. Unsupported capture hardware cannot keep the local camera active.

Ordinary foreground APNs copies are suppressed because existing Matrix foreground local notifications already apply user preferences. Local notification callbacks still delegate to the plugin; ordinary remote callback completion is handled directly. `chatflow/apns` additionally provides getNotificationSettings/openNotificationSettings without changing app UI.

## Secure session bridge (ADR0011)

`chatflow/ios_secure_session` read/write/delete accepts only `liuhetong.matrix_database_key.v1` and `liuhetong.business_session.v1`, under the existing flutter_secure_storage_service and nonsynchronizable generic-password account. No accessibility filter, access group change, or iCloud fallback is used. Only errSecItemNotFound is absence. A legacy successful read updates accessibility in place to AfterFirstUnlockThisDeviceOnly, then verifies identical bytes, identifiers and access group. Failed reads/migration/write/verification return FlutterError and never trigger repair, deletion, rekeying or fallback creation. Only an initial unambiguous absence permits SecItemAdd. delete is explicit and key-scoped.

Before first unlock after reboot, Keychain access can still fail. Old WhenUnlocked items must first be read while unlocked to migrate. No application PIN/recovery policy is changed here.

## Verification status

Native XCTest was authored first in commits ff7ff5d (calls) and 0f3f978 (Keychain). The Windows implementation host has no xcodebuild/Apple SDK; **no native red/green execution or iOS compile is claimed**. The CI workflow copies the unchanged IOSCallState.swift and IOSSecureSession.swift core files into a temporary macOS SwiftPM target and runs RunnerTests.swift after replacing its module import. This executes the real Foundation/CryptoKit/Security core and injected Security failure paths, without Flutter/Pods simulator setup. IOSSecureSessionBridge.swift alone maps native errors to FlutterError. The real signed iOS archive must then compile all CallKit, PushKit, AVKit, WebRTC, Flutter and UIKit adapters.

The Windows implementation host cannot run either stage. Real PushKit, CallKit audio activation, cold start/locked Keychain, device camera/background duplex audio and PiP require the user's iPad. Do not infer those results from entitlements or a successful compile.

Sources checked: Flutter UIScene migration and local Flutter engine/scene integration tests; flutter_webrtc0.12.11 public native headers; flutter_secure_storage9.2.4 exact service/query implementation; Apple's AVPictureInPictureVideoCallViewController API. The artifact verifier must inspect the actual IPA for minimum OS, signing, APNs and SQLCipher load order.
