import 'package:matrix/matrix.dart'
    show Event, EventStatusExtension, fileSendingStatusKey;

/// 视频发送阶段（P1：把"黑盒发送中"拆成可见阶段）。
///
/// 阶段来源：
/// - transcoding：应用层转码（VideoCompress，带真实进度 0..1）；
/// - encrypting/uploading：SDK 在上传伪事件的 unsigned
///   （`fileSendingStatusKey`）里写入的细分状态，此前被时间线适配层
///   折叠成一个"发送中"；
/// - sendingEvent：上传完成、事件落库前的收尾（SDK 无进一步细分）。
enum VideoSendPhase {
  idle,
  transcoding,
  encrypting,
  uploading,
  sendingEvent,
  done,
  failed
}

final class VideoSendState {
  const VideoSendState({this.phase = VideoSendPhase.idle, this.progress});

  final VideoSendPhase phase;

  /// 转码进度 0..1（其余阶段 SDK 无进度回调——如实显示不定进度）。
  final double? progress;

  bool get busy =>
      phase != VideoSendPhase.idle &&
      phase != VideoSendPhase.done &&
      phase != VideoSendPhase.failed;

  VideoSendState copyWith({VideoSendPhase? phase, double? progress}) =>
      VideoSendState(
        phase: phase ?? this.phase,
        progress: progress ?? this.progress,
      );

  String get label => switch (phase) {
        VideoSendPhase.idle => '发送前将自动压缩（480p）',
        VideoSendPhase.transcoding =>
          progress == null ? '转码中…' : '转码中 ${(progress! * 100).round()}%',
        VideoSendPhase.encrypting => '加密中…',
        VideoSendPhase.uploading => '上传中…',
        VideoSendPhase.sendingEvent => '发送中…',
        VideoSendPhase.done => '已发送',
        VideoSendPhase.failed => '发送失败，可重试',
      };
}

/// SDK `FileSendingStatus` 名 → 视频发送阶段。
///
/// generatingThumbnail 归入 encrypting 桶（亚秒级准备步骤，避免再设一档；
/// 我们的视频路径已自带封面帧，通常不会出现该状态）。
VideoSendPhase? videoPhaseFromFileSendingStatus(String? statusName) =>
    switch (statusName) {
      'generatingThumbnail' => VideoSendPhase.encrypting,
      'encrypting' => VideoSendPhase.encrypting,
      'uploading' => VideoSendPhase.uploading,
      _ => null,
    };

/// 读取时间线中"发送中"事件当前的细分阶段；全部发送中事件都已脱离
/// 细分状态（上传完成、等事件落库）时返回 [VideoSendPhase.sendingEvent]；
/// 无发送中事件返回 null。
VideoSendPhase? videoUploadPhaseFromTimeline(Iterable<Event> events) {
  for (final event in events) {
    if (!event.status.isSending) continue;
    final status = event.unsigned?[fileSendingStatusKey]?.toString();
    final phase = videoPhaseFromFileSendingStatus(status);
    if (phase != null) return phase;
    return VideoSendPhase.sendingEvent;
  }
  return null;
}
