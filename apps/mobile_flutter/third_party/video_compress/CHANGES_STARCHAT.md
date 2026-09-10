# StarChat local video_compress 3.1.4 changes

Source: the workspace's resolved Pub-cache video_compress 3.1.4 package. MIT
license and attribution are retained in LICENSE. Only plugin source, manifests,
and license are vendored; examples and generated build output are excluded.
Dependency remains Transcoder 0.10.5 on Android. The application selects this
directory explicitly through its pubspec path dependency and lockfile.

Local changes (2026-09-10):

- Dart compressVideo passes optional videoBitrate/maxDimension/audioBitrate/
  audioSampleRate/audioChannels. Processing state resets in finally even when
  the platform channel throws.
- Android uses both dimension bounds (the one-argument atMost bounds only the
  shorter side), explicit video bitrate/frame rate and mono AAC settings.
  UUID filenames prevent a second pass overwriting the first within one second.
  Failed/cancelled outputs are removed by their creator.
- iOS adds ChatVideoEncoder (AVAssetReader/AVAssetWriter). H.264 settings control
  bitrate and dimensions; AVVideoComposition controls frame rate, orientation,
  and even output dimensions; audio is decoded/re-encoded as mono AAC using the
  supplied bitrate and sample rate. Success requires reader/writer completion;
  failure/cancellation closes inputs and deletes output. Legacy calls without
  videoBitrate retain the original preset path. Pod minimum iOS is 13 (the app
  itself already requires iOS 16).
- macOS is unchanged and does not implement explicit chat bitrate controls.
  This delivery targets Android/iOS only.

Validation: Dart channel/pipeline tests and local Transcoder 0.10.5 javap API
inspection. Windows cannot compile or execute AVFoundation. No native build or
real-device encoding was performed in this task; native compilation and device
quality/rotation/audio/cancellation checks remain release requirements.
