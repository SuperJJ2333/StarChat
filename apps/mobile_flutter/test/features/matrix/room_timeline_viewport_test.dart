import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_viewport.dart';

void main() {
  RoomTimelineViewport<int> retainedWindow() => RoomTimelineViewport<int>(
      idOf: (id) => '$id',
      project: (id) => RoomMessageViewModel(
          id: '$id',
          senderId: 'synthetic',
          text: 'fixture',
          isOwn: false,
          timestamp: DateTime.utc(2026),
          deliveryState: RoomDeliveryState.sent))
    ..update(List.generate(1000, (i) => i))
    ..anchor('500');

  test('edge retention clips both shifts without exceeding 200 rows', () {
    final window = retainedWindow();
    window.earlier(retainEventId: '550');
    expect(window.snapshot().first.id, '351');
    expect(window.snapshot().last.id, '550');
    window.later(retainEventId: '375');
    expect(window.snapshot().first.id, '375');
    expect(window.retainedModels, 200);
    window.later(retainEventId: '375');
    expect(window.snapshot().first.id, '375',
        reason: 'wait until the visible boundary moves before dropping it');
    window.later(retainEventId: '480');
    expect(window.snapshot().first.id, '475',
        reason: 'history advances when the protected row leaves the trim edge');
  });

  test('missing and out of window retained IDs cannot navigate history', () {
    for (final id in ['absent', '999', '0']) {
      final earlier = retainedWindow()..earlier(retainEventId: id);
      expect(earlier.snapshot().first.id, '300');
      final later = retainedWindow()..later(retainEventId: id);
      expect(later.snapshot().first.id, '500');
    }
  });

  test(
      '50000 references project forty initially and at most 200 across anchors',
      () {
    var projected = 0;
    final recalled = <int>{};
    final window = RoomTimelineViewport<int>(
        idOf: (id) => '$id',
        project: (id) {
          projected++;
          return RoomMessageViewModel(
              id: '$id',
              senderId: 'synthetic',
              text: recalled.contains(id) ? '' : 'fixture',
              isRecalled: recalled.contains(id),
              isOwn: false,
              deliveryState: RoomDeliveryState.sent,
              timestamp: DateTime.utc(2026).add(Duration(seconds: id)));
        });
    final source = List.generate(50000, (i) => i);
    window.update(source);
    expect(window.snapshot().length, 40);
    expect(projected, 40);
    expect(window.retainedModels, 40);
    expect(window.anchor('20000'), isTrue);
    final first = window.snapshot();
    expect(first.length, 200);
    expect(first.any((m) => m.id == '20000'), isTrue);
    recalled.add(49990);
    source.add(50000);
    window.update(source);
    expect(window.snapshot().first.id, first.first.id);
    expect(window.hasLater, isTrue);
    window.earlier();
    expect(window.snapshot().last.id, '19999');
    window.later();
    expect(window.snapshot().first.id, first.first.id);
    window.latest();
    final latest = window.snapshot();
    expect(latest.last.id, '50000');
    expect(latest.firstWhere((m) => m.id == '49990').isRecalled, isTrue);
    expect(window.retainedModels, 200);
    expect(window.find('1')?.id, '1');
    expect(window.find('50000')?.id, '50000');
    expect(window.retainedModels, 200);
    expect(window.all.length, 50001);
    expect(window.retainedModels, 200);
    window.pin();
    window.update(List.generate(100, (i) => i));
    expect(window.snapshot(), isNotEmpty,
        reason:
            'removing the anchored tail must not hide remaining older history');
  });
}
