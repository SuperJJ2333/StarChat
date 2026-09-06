# Call audio route correction

Scope approved by the user's request to fix call echo; bounded task delegated by root.
Own call_controller.dart, its audio-route tests, and evidence in call-echo-scan.

1. Inspect Matrix/flutter_webrtc capture, rendering and Android audio routing defaults.
2. Reproduce route/UI mismatch with failing controller tests for voice/video and incoming/outgoing calls.
3. Apply the existing UI route before starting/answering media, preserving explicit speaker choices.
4. Run focused call tests and analysis; root runs repository verification.
5. Review specification compliance before quality/security and record limitations.

Evidence: Android AudioSwitchManager defaults to speaker before earpiece, retains preferences on deactivate, and activation does not reset preferences. Existing controller defaults speaker=false without applying it before start/answer. Native RTCVideoRenderer binds video only; its muted setter mutes the microphone. Matrix already requests AEC/noise suppression. Do not modify microphone muting or add speculative audio constraints.

This fixes accidental loudspeaker routing, not a proven general echo cause. Actual acoustic echo on video/speaker calls still requires two-device listening validation.
