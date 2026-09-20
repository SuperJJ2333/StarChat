import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_outgoing_work_coordinator.dart';

MatrixOutgoingWorkItem _videoItem({
  required String id,
  required String roomId,
  required String txid,
  Future<void> Function(MatrixOutgoingWorkAttempt attempt)? prepare,
  required Future<String> Function(MatrixOutgoingWorkAttempt attempt) send,
}) =>
    MatrixOutgoingWorkItem(
      id: id,
      targetRoomId: roomId,
      txid: txid,
      prepare: prepare,
      send: send,
      presentation: MatrixOutgoingWorkPresentation(
        kind: MatrixOutgoingPresentationKind.video,
        text: '[视频消息]',
        createdAt: DateTime.now(),
      ),
    );

void main() {
  test('BUG-35：转码进度按 jobId 回报并投影到房间摘要', () async {
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    final preparation = Completer<void>();
    final sent = Completer<void>();
    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'gallery-video-1',
      items: [
        _videoItem(
          id: 'video',
          roomId: '!room:test',
          txid: 'tx-1',
          prepare: (_) => preparation.future,
          send: (_) {
            sent.complete();
            return Future.value('evt');
          },
        ),
      ],
    ));

    coordinator.reportPreparationProgress('gallery-video-1', 0.45);
    expect(coordinator.preparationProgressOf('gallery-video-1'), 0.45);
    final summary = coordinator.videoWorkSummaryForRoom('!room:test');
    expect(summary.preparing, 1);
    expect(summary.progress, 0.45);
    expect(summary.busy, isTrue);
    expect(summary.label, contains('45'), reason: '转码中必须显示百分比（D5 验收口径）');

    preparation.complete();
    await sent.future;
    await coordinator.drain();
    expect(coordinator.videoWorkSummaryForRoom('!room:test').busy, isFalse,
        reason: '发送完成后进度胶囊必须消失');
  });

  test('BUG-35：上传阶段与失败阶段如实投影', () async {
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    final sendGate = Completer<void>();
    final failed = Completer<void>();
    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'upload-1',
      items: [
        _videoItem(
          id: 'v-sending',
          roomId: '!room:test',
          txid: 'tx-2',
          send: (_) => sendGate.future.then((_) => 'evt'),
        ),
        _videoItem(
          id: 'v-failed',
          roomId: '!room:test',
          txid: 'tx-3',
          send: (_) {
            failed.complete();
            throw StateError('upload failed');
          },
        ),
      ],
    ));
    await failed.future;
    final summary = coordinator.videoWorkSummaryForRoom('!room:test');
    expect(summary.sending, 1, reason: '上传中（SDK 发送阶段）必须可见');
    expect(summary.failed, 1, reason: '失败必须可见并提示可重试');
    expect(summary.label, '视频发送失败，可重试');
    sendGate.complete();
    await coordinator.drain();
  });

  test('BUG-35：其他房间的视频工作不串扰', () async {
    final coordinator = MatrixOutgoingWorkCoordinator(accountId: '@me:test');
    final preparation = Completer<void>();
    final sent = Completer<void>();
    await coordinator.enqueue(MatrixOutgoingWorkJob(
      id: 'other-room-video',
      items: [
        _videoItem(
          id: 'v',
          roomId: '!other:test',
          txid: 'tx-4',
          prepare: (_) => preparation.future,
          send: (_) {
            sent.complete();
            return Future.value('evt');
          },
        ),
      ],
    ));
    coordinator.reportPreparationProgress('other-room-video', 0.5);
    final summary = coordinator.videoWorkSummaryForRoom('!room:test');
    expect(summary.busy, isFalse);
    expect(summary.label, isEmpty);
    preparation.complete();
    await sent.future;
    await coordinator.drain();
  });
}
