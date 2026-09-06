import 'package:matrix/matrix.dart';

const groupSettingsStateType = 'com.changliao.group.settings';
const groupAnnouncementStateType = 'com.changliao.group.announcement';

/// Shared authority comes exclusively from server-authenticated room state.
final class GroupRoomAuthority {
  GroupRoomAuthority(this.room);
  final Room room;
  String get ownerId {
    final users = room.getState(EventTypes.RoomPowerLevels)?.content['users'];
    if (users is Map) {
      final owners = users.entries
          .where((e) => e.value is num && e.value >= 100)
          .map((e) => e.key.toString())
          .toList()
        ..sort();
      final creator = room.getState(EventTypes.RoomCreate)?.senderId;
      if (owners.contains(creator)) return creator!;
      return owners.isEmpty ? '' : owners.first;
    }
    return room.getState(EventTypes.RoomCreate)?.senderId ?? '';
  }

  Future<void> refresh() async {
    final events = await room.client.getRoomState(room.id);
    for (final event in events) {
      room.setState(Event.fromMatrixEvent(event, room));
    }
  }

  bool get onlyManagersCanRename {
    final power = room.getState(EventTypes.RoomPowerLevels)?.content ?? {};
    final events = power['events'];
    final explicit = events is Map ? events[EventTypes.RoomName] : null;
    return (explicit as num? ?? power['state_default'] as num? ?? 50) >= 50;
  }

  bool get isOwner =>
      room.client.userID != null && room.client.userID == ownerId;
  bool get canManage => room.client.userID != null && room.ownPowerLevel >= 50;
  void requireManager() {
    if (!canManage) throw StateError('仅群主或管理员可操作');
  }

  void requireOwner() {
    if (!isOwner) throw StateError('仅群主可操作');
  }

  Future<void> protectState({bool protectRoles = false}) async {
    requireManager();
    final current = Map<String, dynamic>.from(
        room.getState(EventTypes.RoomPowerLevels)?.content ?? {});
    final events = Map<String, dynamic>.from(current['events'] as Map? ?? {});
    if ((events[groupSettingsStateType] as num? ??
                current['state_default'] as num? ??
                50) >=
            50 &&
        (events[groupAnnouncementStateType] as num? ??
                current['state_default'] as num? ??
                50) >=
            50 &&
        (!protectRoles ||
            (events[EventTypes.RoomPowerLevels] as num? ??
                    current['state_default'] as num? ??
                    50) >=
                100)) {
      return;
    }
    if (protectRoles) requireOwner();
    for (final type in [groupSettingsStateType, groupAnnouncementStateType]) {
      final threshold =
          events[type] as num? ?? current['state_default'] as num? ?? 50;
      if (threshold < 50) events[type] = 50;
    }
    if (protectRoles &&
        (events[EventTypes.RoomPowerLevels] as num? ??
                current['state_default'] as num? ??
                50) <
            100) {
      events[EventTypes.RoomPowerLevels] = 100;
    }
    await room.client.setRoomStateWithKey(room.id, EventTypes.RoomPowerLevels,
        '', {...current, 'events': events});
    await refresh();
  }
}
