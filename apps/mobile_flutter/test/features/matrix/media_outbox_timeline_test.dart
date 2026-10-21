import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'room_timeline_controller_test.dart' show FakeTimelineAdapter;

MediaOutboxTask _task(String id,
        {MediaOutboxStage stage = MediaOutboxStage.preparing,
        String? eventId,
        int created = 100}) =>
    MediaOutboxTask.fromRow({
      'txid': id,
      'room_id': '!room:test',
      'owner_scope': 'owner',
      'mime_type': 'image/png',
      'filename': 'image',
      'length': 1,
      'stage': stage.name,
      'attempts': 0,
      'created_at': created,
      'event_id': eventId,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'durable task and SDK echo merge by txid then event id without identity change',
      () async {
    final adapter = FakeTimelineAdapter();
    final controller =
        RoomTimelineController(adapter, outboxRoomId: '!room:test');
    controller.projectMediaTasks([_task('stable')]);
    expect(controller.latestLocalSendIntent, isNull,
        reason: 'durable media recovery is not a route-local send');
    expect(controller.messages.single.stableId, 'stable');
    adapter.items.add(RoomMessageViewModel(
        id: 'sdk-local',
        transactionId: 'stable',
        senderId: '@self:test',
        text: 'image',
        isOwn: true,
        deliveryState: RoomDeliveryState.sending,
        timestamp: DateTime.fromMillisecondsSinceEpoch(999),
        kind: RoomMessageKind.image,
        isSdkLocalEcho: true));
    await controller.refresh();
    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.timestamp.millisecondsSinceEpoch, 100);
    controller.projectMediaTasks(
        [_task('stable', stage: MediaOutboxStage.sent, eventId: r'$ack')]);
    adapter.items
      ..clear()
      ..add(RoomMessageViewModel(
          id: r'$ack',
          senderId: '@self:test',
          text: 'image',
          isOwn: true,
          deliveryState: RoomDeliveryState.sent,
          timestamp: DateTime.fromMillisecondsSinceEpoch(200),
          kind: RoomMessageKind.image));
    await controller.refresh();
    expect(controller.messages, hasLength(1));
    expect(controller.messages.single.stableId, 'stable');
    expect(controller.messages.single.id, r'$ack');
    expect(controller.messages.single.timestamp.millisecondsSinceEpoch, 200);
    controller.dispose();
  });

  test(
      'failed recovery preserves creation order and canceled provisional cannot return',
      () async {
    final controller = RoomTimelineController(FakeTimelineAdapter(),
        outboxRoomId: '!room:test');
    controller.projectMediaTasks([
      _task('later', stage: MediaOutboxStage.failed, created: 200),
      _task('first', stage: MediaOutboxStage.ackUnknown),
    ]);
    expect(controller.messages.map((m) => m.stableId), ['first', 'later']);
    expect(controller.messages.first.deliveryState,
        RoomDeliveryState.waitingNetwork);
    controller.projectPreparingMedia(
        txid: 'cancel', kind: RoomMessageKind.video, mimeType: 'video/mp4');
    controller
        .projectMediaTasks([_task('cancel', stage: MediaOutboxStage.canceled)]);
    controller.failPreparingMedia('cancel');
    await controller.refresh();
    expect(controller.messages.where((m) => m.stableId == 'cancel'), isEmpty);
    controller.dispose();
  });

  test(
      'account retirement removes gallery projection without mutating transport',
      () {
    final controller = RoomTimelineController(FakeTimelineAdapter(),
        outboxRoomId: '!room:test');
    controller.projectPreparingMedia(
        txid: 'gallery', kind: RoomMessageKind.image, mimeType: 'image/jpeg');
    controller.projectMediaTasks([_task('gallery')]);
    expect(controller.messages, hasLength(1));
    controller.clearMediaProjection();
    controller.failPreparingMedia('gallery');
    expect(controller.messages, isEmpty);
    controller.dispose();
    controller.projectMediaTasks([_task('late')]);
  });
  test(
      'canceled coordinator failure stays hidden but a submitted server echo remains truthful',
      () async {
    final adapter = FakeTimelineAdapter();
    final controller =
        RoomTimelineController(adapter, outboxRoomId: '!room:test');
    controller
        .projectMediaTasks([_task('cancel', stage: MediaOutboxStage.canceled)]);
    final local = RoomMessageViewModel(
        id: 'outgoing:cancel',
        transactionId: 'cancel',
        senderId: 'self',
        text: 'video',
        isOwn: true,
        deliveryState: RoomDeliveryState.failed,
        timestamp: DateTime(2026),
        kind: RoomMessageKind.video);
    adapter.items.add(local);
    await controller.refresh();
    expect(controller.messages, isEmpty);
    adapter.items
      ..clear()
      ..add(local.copyWith(
          id: r'$delivered', deliveryState: RoomDeliveryState.sent));
    await controller.refresh();
    expect(controller.messages.single.id, r'$delivered');
    controller.dispose();
  });
}
