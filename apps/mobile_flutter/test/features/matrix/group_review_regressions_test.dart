import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/group_announcement_service.dart';
import 'package:liuhetong_mobile/features/matrix/group_chat_info_controller.dart';
import 'package:liuhetong_mobile/features/matrix/group_room_authority.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_notification_event_source.dart';

void main() {
  test(
      'toggle back before sync cannot acknowledge against the unchanged old cache',
      () {
    final overlay = GroupPreferenceOverlay();
    final oldCache = <String, Object?>{'muted': false};
    overlay.read(oldCache);
    overlay.wrote('muted', true);
    overlay.wrote('muted', false);
    expect(overlay.read(oldCache)['muted'], isFalse);
    expect(overlay.read({'muted': true})['muted'], isFalse);
    expect(overlay.read({'muted': false})['muted'], isFalse);
  });
  test(
      'draft image remains local and cannot be serialized as published content',
      () {
    final image = AnnouncementBlock.localImage(
        Uint8List.fromList([1, 2, 3]), 'photo.png');
    expect(image.localBytes, [1, 2, 3]);
    expect(() => GroupAnnouncement([image]).toContent(), throwsStateError);
  });
  test(
      'pending account preference writes survive stale SDK state until acknowledgement',
      () {
    final overlay = GroupPreferenceOverlay();
    overlay.wrote('muted', true);
    expect(overlay.read({'muted': false})['muted'], isTrue);
    overlay.wrote('attention', true);
    expect(overlay.read({'muted': false, 'attention': false}),
        {'muted': true, 'attention': true});
    expect(
        overlay.read({'muted': true, 'attention': false})['attention'], isTrue);
    overlay.read({'muted': true, 'attention': true});
    expect(overlay.read({'muted': false, 'attention': true})['muted'], isFalse);
  });
  test('group name permissions use Matrix state default fallback', () {
    final room = Room(id: '!test:example', client: Client('test'));
    expect(GroupRoomAuthority(room).onlyManagersCanRename, isTrue);
    room.setState(Event(
        type: EventTypes.RoomPowerLevels,
        content: {'state_default': 75, 'events': {}},
        senderId: '@owner:test',
        room: room,
        eventId: r'$pl',
        stateKey: '',
        originServerTs: DateTime(2026)));
    expect(GroupRoomAuthority(room).onlyManagersCanRename, isTrue);
  });
  test('notification recognizes decrypted announcement documents only', () {
    final room = Room(id: '!test:example', client: Client('test'));
    final event = Event(
        type: EventTypes.Message,
        content: {'msgtype': groupAnnouncementMessageType},
        senderId: '@owner:test',
        room: room,
        eventId: r'$doc',
        originServerTs: DateTime(2026),
        originalSource: MatrixEvent(
            type: EventTypes.Encrypted,
            content: {},
            senderId: '@owner:test',
            eventId: r'$doc',
            originServerTs: DateTime(2026)));
    expect(isGroupAnnouncementNotification(event), isTrue);
    expect(isGroupAnnouncementNotification(null), isFalse);
  });
}
