import 'package:matrix/matrix.dart' show Event;

import 'room_timeline_controller.dart';

/// 成员事件的本地投影（从真实 Matrix Event 提炼的最小事实集）。
final class MembershipEventFacts {
  const MembershipEventFacts({
    required this.eventId,
    required this.stateKey,
    required this.senderId,
    required this.membership,
    this.prevMembership,
    this.joinSource,
    required this.timestamp,
  });

  final String eventId;
  final String? stateKey;
  final String senderId;
  final String membership;
  final String? prevMembership;

  /// com.changliao.join_source（服务端扫码代加入标记）。
  final String? joinSource;
  final DateTime timestamp;
}

/// 真实 Matrix Event → 投影（推导函数只依赖这些字段，便于纯函数测试）。
MembershipEventFacts projectMemberEvent(Event event) => MembershipEventFacts(
      eventId: event.eventId,
      stateKey: event.stateKey,
      senderId: event.senderId,
      membership: (event.content['membership'] ?? '').toString(),
      prevMembership: event.prevContent?['membership']?.toString(),
      joinSource: event.content['com.changliao.join_source']?.toString(),
      timestamp: event.originServerTs.toLocal(),
    );

/// 一条推导出的入群通知（锚定真实 join 成员事件）。
final class GroupJoinNotice {
  const GroupJoinNotice({
    required this.eventId,
    required this.timestamp,
    required this.text,
  });

  /// 锚定的 join 成员事件 id（决定通知在时间线中的位置与去重键）。
  final String eventId;
  final DateTime timestamp;
  final String text;
}

/// BUG3：从成员事件推导入群通知（纯函数，本地推导、不发事件）。
///
/// 以 Matrix m.room.member 为唯一权威：
/// - 只认"真正 join"的转变（prev != join → join）；仅 invite 未 join
///   绝不显示"已加入"；join→join 是资料/权力变更，不产生通知；
/// - invite→join：A = invite 事件 sender → "A邀请B加入群聊"；
/// - join 带 com.changliao.join_source='qr'（服务端扫码代加标记）
///   → "B通过扫描二维码加入群聊"；
/// - 自邀自 join（建群首成员）不产生通知；每个 join 转变至多一条。
List<GroupJoinNotice> deriveGroupJoinNotices(
  Iterable<MembershipEventFacts> events, {
  required String Function(String matrixUserId) resolveName,
}) {
  final inviteSenders = <String, String>{};
  for (final event in events) {
    if (event.membership == 'invite' && event.stateKey != null) {
      inviteSenders[event.stateKey!] = event.senderId;
    }
  }
  final notices = <GroupJoinNotice>[];
  for (final event in events) {
    final joiner = event.stateKey;
    if (joiner == null || event.membership != 'join') continue;
    if (event.prevMembership == 'join') continue; // 资料/权力变更。
    final viaQr = event.joinSource == 'qr';
    final inviter = inviteSenders[joiner];
    if (!viaQr && (inviter == null || inviter == joiner)) continue;
    final joinerName = resolveName(joiner);
    notices.add(GroupJoinNotice(
      eventId: event.eventId,
      timestamp: event.timestamp,
      text: viaQr
          ? '$joinerName通过扫描二维码加入群聊'
          : '${resolveName(inviter!)}邀请$joinerName加入群聊',
    ));
  }
  return notices;
}

/// 通知并入消息流：按时间戳插入；连续的"同邀请者"邀请通知合并为
/// "A邀请B、C加入群聊"；扫码文案独立不合并。
List<RoomMessageViewModel> mergeNoticesIntoTimeline(
  List<RoomMessageViewModel> messages,
  List<GroupJoinNotice> notices,
) {
  final sorted = notices.toList()
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  final invitePattern = RegExp('^(.+)邀请(.+)加入群聊\$');
  final inviterNames = <String>[];
  final joinerNames = <String>[];
  final entries = <(DateTime, String, String)>[];
  var batchAt = DateTime.fromMillisecondsSinceEpoch(0);
  var batchFirstId = '';

  void flushInviteBatch() {
    if (inviterNames.isEmpty) return;
    final joined = joinerNames.join('、');
    entries.add(
        (batchAt, batchFirstId, '${inviterNames.first}邀请$joined加入群聊'));
    inviterNames.clear();
    joinerNames.clear();
  }

  for (final notice in sorted) {
    final match = invitePattern.firstMatch(notice.text);
    if (match == null) {
      flushInviteBatch();
      entries.add((notice.timestamp, notice.eventId, notice.text));
      continue;
    }
    final inviter = match.group(1)!;
    final joiner = match.group(2)!;
    if (inviterNames.isNotEmpty && inviterNames.last == inviter) {
      joinerNames.add(joiner);
    } else {
      flushInviteBatch();
      inviterNames.add(inviter);
      joinerNames.add(joiner);
      batchAt = notice.timestamp;
      batchFirstId = notice.eventId;
    }
  }
  flushInviteBatch();
  entries.sort((a, b) => a.$1.compareTo(b.$1));

  RoomMessageViewModel toViewModel((DateTime, String, String) entry) =>
      RoomMessageViewModel(
        id: entry.$2,
        senderId: '',
        text: entry.$3,
        isOwn: false,
        deliveryState: RoomDeliveryState.sent,
        timestamp: entry.$1,
        kind: RoomMessageKind.system,
      );

  final result = <RoomMessageViewModel>[];
  var index = 0;
  for (final message in messages) {
    while (index < entries.length &&
        !entries[index].$1.isAfter(message.timestamp)) {
      result.add(toViewModel(entries[index++]));
    }
    result.add(message);
  }
  while (index < entries.length) {
    result.add(toViewModel(entries[index++]));
  }
  return result;
}
