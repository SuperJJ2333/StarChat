import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/video_send_stage.dart';

/// 视频发送阶段化（P1）：
/// - 阶段标签（转码带真实进度；加密/上传/发送事件如实显示不定进度）；
/// - SDK 上传伪事件状态（FileSendingStatus）→ 阶段映射；
/// - sendEncryptedMedia 不再做冗余全量拷贝（源码级断言，防回归）。
void main() {
  group('VideoSendState 阶段标签', () {
    test('各阶段文案', () {
      expect(const VideoSendState().label, '发送前将自动压缩（480p）');
      expect(
        const VideoSendState(phase: VideoSendPhase.transcoding).label,
        '转码中…',
      );
      expect(
        const VideoSendState(
          phase: VideoSendPhase.transcoding,
          progress: 0.42,
        ).label,
        '转码中 42%',
      );
      expect(
        const VideoSendState(phase: VideoSendPhase.encrypting).label,
        '加密中…',
      );
      expect(
        const VideoSendState(phase: VideoSendPhase.uploading).label,
        '上传中…',
        reason: 'SDK 上传无进度回调——如实显示不定进度，不伪造百分比',
      );
      expect(
        const VideoSendState(phase: VideoSendPhase.sendingEvent).label,
        '发送中…',
      );
      expect(const VideoSendState(phase: VideoSendPhase.done).label, '已发送');
    });

    test('busy 门控：idle/done/failed 不算发送中', () {
      expect(const VideoSendState().busy, isFalse);
      expect(const VideoSendState(phase: VideoSendPhase.done).busy, isFalse);
      expect(const VideoSendState(phase: VideoSendPhase.failed).busy, isFalse);
      expect(
          const VideoSendState(phase: VideoSendPhase.uploading).busy, isTrue);
    });
  });

  group('SDK FileSendingStatus → 阶段映射', () {
    test('encrypting/uploading 正确映射；未知状态返回 null', () {
      expect(videoPhaseFromFileSendingStatus('encrypting'),
          VideoSendPhase.encrypting);
      expect(videoPhaseFromFileSendingStatus('uploading'),
          VideoSendPhase.uploading);
      expect(videoPhaseFromFileSendingStatus('generatingThumbnail'),
          VideoSendPhase.encrypting,
          reason: '亚秒级准备步骤归入加密桶');
      expect(videoPhaseFromFileSendingStatus(null), isNull);
      expect(videoPhaseFromFileSendingStatus('unknown'), isNull);
    });
  });

  group('sendEncryptedMedia 冗余拷贝消除（源码防回归）', () {
    test('正文与缩略图直接透传，不再 Uint8List.fromList 全量拷贝', () {
      final source = File(
        'lib/features/matrix/matrix_e2ee_client.dart',
      ).readAsStringSync(encoding: utf8);
      final implStart = source.indexOf('final class MatrixSdkE2eeClient');
      final start =
          source.indexOf('Future<String> sendEncryptedMedia', implStart);
      final end = source.indexOf('  @override', start);
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));
      final body = source.substring(start, end);
      expect(body.contains('Uint8List.fromList'), isFalse,
          reason: 'sendEncryptedMedia 不得对正文/缩略图再做全量拷贝'
              '（SDK 加密内部的原生拷贝不在应用层控制范围）');
      expect(body.contains('bytes: plaintext,'), isTrue,
          reason: '正文必须原实例透传给 MatrixFile');
      expect(body.contains('bytes: thumbnailBytes,'), isTrue,
          reason: '缩略图必须原实例透传给 MatrixImageFile');
    });
  });
}
