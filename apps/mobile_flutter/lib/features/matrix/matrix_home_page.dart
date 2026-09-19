import '../contacts/contact_actions.dart';
import '../../ui/components/top_more_menu.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';

import '../../core/app_config.dart';
import '../../core/business_api_client.dart';
import '../../core/support_identity_repository.dart';
import '../contacts/contacts_page.dart';
import '../contacts/scan_qr_page.dart';
import '../../ui/chat/group_avatar_mosaic.dart';
import '../../ui/components/conversation_list_tile.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/components/wechat_nav_title.dart';
import '../../ui/chat/conversation_action_sheet.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../../ui/theme/theme_controller.dart';
import '../../ui/theme/theme_picker_sheet.dart';
import 'matrix_e2ee_client.dart';
import 'matrix_home_snapshot_refresh_coordinator.dart';
import 'matrix_user_avatar.dart';
import 'conversation_avatar_identity.dart';
import 'profile_repository.dart';
import 'conversation_preferences.dart';
import 'conversation_read_state.dart';
import 'conversation_presentation.dart';
import 'decryption_state_controller.dart';
import 'direct_room_coordination_storage.dart';
export 'conversation_presentation.dart'
    show directRoomNavigationTitle, groupRoomNavigationTitle;
export 'room_page.dart' show RoomPage;
import '../search/global_search_page.dart';
import 'room_navigation_coordinator.dart';
import 'room_visibility_policy.dart';
import 'room_mention_store.dart';
import 'message_reminder_service.dart';
import '../statistics/statistics_state_store.dart';
import 'nudge_service.dart';
import '../../ui/motion/motion_page_route.dart';

final class _RoomAvatarSnapshot {
  const _RoomAvatarSnapshot(
      this.nickname, this.fallbackSeed, this.uri, this.profileUrl);
  final String nickname;
  final String fallbackSeed;
  final Uri? uri;
  final String? profileUrl;
}

final class _RoomProjectionCacheEntry {
  const _RoomProjectionCacheEntry(this.signature, this.snapshot);
  final _RoomInputSignature signature;
  final _RoomSnapshot snapshot;
}

final class _ConversationRowCacheEntry {
  const _ConversationRowCacheEntry(this.snapshot, this.hasMention, this.widget);
  final _RoomSnapshot snapshot;
  final bool hasMention;
  final Widget widget;
}

/// Every value that can alter a room row is represented here.  Member lists
/// are intentionally compared by their immutable SDK projection reference:
/// C1 changes that reference on membership changes, while an unchanged sync
/// keeps it stable without walking a thousand members.
final class _RoomInputSignature {
  const _RoomInputSignature(this._values);
  final Object _values;

  factory _RoomInputSignature.fromRoom(
      MatrixConversationRoomSnapshot room,
      String timeLabel,
      int effectiveUnread,
      MessageDecryptionState? localDecryptionState) {
    final preference = room.preference;
    final event = room.lastEvent;
    return _RoomInputSignature((
      room.id,
      room.displayName,
      room.avatar?.toString(),
      room.isDirect,
      room.directPeerId,
      room.members,
      room.name,
      room.isJoined,
      room.notificationCount,
      effectiveUnread,
      room.notificationsEnabled,
      preference.muted,
      preference.attention,
      preference.pinned,
      preference.saved,
      preference.folded,
      preference.notifyMentionMe,
      preference.notifyMentionAll,
      preference.notifyAnnouncement,
      _canonicalValue(preference.followedMemberIds),
      _canonicalValue(preference.memberOrderIds),
      preference.pinnedAt,
      preference.manualUnread,
      preference.hidden,
      preference.hiddenAt,
      event?.eventId,
      event?.type,
      event?.text,
      event?.body,
      event?.originServerTs,
      event?.senderId,
      event?.sender.id,
      event?.sender.displayName,
      event?.sender.avatar?.toString(),
      event?.redacted,
      event?.messageType,
      _canonicalValue(event?.content),
      event?.decryptionState,
      localDecryptionState,
      timeLabel,
    ));
  }

  @override
  bool operator ==(Object other) =>
      other is _RoomInputSignature && other._values == _values;
  @override
  int get hashCode => _values.hashCode;
}

String _canonicalValue(Object? value) {
  Object? normalize(Object? candidate) {
    if (candidate is Map) {
      final keys = candidate.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: normalize(candidate[key])};
    }
    if (candidate is Iterable) {
      return [for (final item in candidate) normalize(item)];
    }
    if (candidate is DateTime) {
      return candidate.toUtc().toIso8601String();
    }
    return candidate;
  }

  return jsonEncode(normalize(value));
}

/// 「消息」页排序锚点（与 [orderConversations] 配套）。
///
/// 优先用可见的最后事件时间；当最后一条事件被「清空聊天记录」隐藏时，退回到
/// 清空前的最后活动时间（快照里的 `lastActivityAt`）。这样清空历史只隐藏正文，
/// 该会话在列表里的位置保持不变，而不会因为缺少可见事件被排到末尾。
DateTime conversationSortAnchor(MatrixConversationRoomSnapshot room) =>
    room.lastEvent?.originServerTs ??
    room.lastActivityAt ??
    DateTime.fromMillisecondsSinceEpoch(0);

final class _RoomSnapshot {
  const _RoomSnapshot({
    required this.id,
    required this.displayName,
    required this.title,
    required this.subtitle,
    required this.timeLabel,
    required this.lastBody,
    required this.lastActivity,
    required this.avatar,
    required this.avatarSeed,
    required this.avatarProfileUrl,
    required this.groupMembers,
    required this.preference,
    required this.unread,
    required this.muted,
    required this.isDirect,
    required this.directPeerId,
    required this.lastEventId,
    required this.groupName,
    required this.memberCount,
  });
  final String id;
  final String displayName;
  final String title;
  final String subtitle;
  final String timeLabel;
  final String lastBody;
  final DateTime lastActivity;
  final Uri? avatar;
  final String avatarSeed;
  final String? avatarProfileUrl;

  /// Kept as the SDK's immutable member projection.  Avatar identities are
  /// deliberately resolved only when ListView builds a visible row.
  final List<MatrixMemberSnapshot> groupMembers;
  final ConversationPreference preference;
  final int unread;
  final bool muted;
  final bool isDirect;
  final String? directPeerId;
  final String? lastEventId;
  final String groupName;
  final int memberCount;
}

class MatrixHomePage extends StatefulWidget {
  const MatrixHomePage({
    super.key,
    required this.api,
    required this.matrix,
    required this.themeController,
    required this.onCreateGroup,
    this.reminderService,
    this.onMessage,
    this.onVoice,
    this.onVideo,
    this.identityCache,
    this.previewOnly = false,
    this.onUnreadChanged,
    this.onOpenRoom,
    this.snapshotLoader,
    this.onRoomProjection,
    this.onIdentityProjection,
    this.onConversationRowBuild,
  });
  final BusinessApiClient api;
  final MatrixSdkE2eeClient matrix;
  final ThemeController themeController;
  final VoidCallback onCreateGroup;
  final MessageReminderService? reminderService;
  final ContactAction? onMessage;
  final ContactAction? onVoice;
  final ContactAction? onVideo;
  final ProfileRepository? identityCache;
  final bool previewOnly;
  final VoidCallback? onUnreadChanged;

  /// 房间页面的统一打开入口（AppHome 注入）。消息列表只负责等待动画、
  /// 已读/未读与展示数据，RoomLease 与 RoomPage 路由由 AppHome 的
  /// RoomNavigationCoordinator 持有（同一 roomId 只有一个活动 RoomPage）。
  /// 为空时不打开房间（如启动期的只读占位页）。
  final Future<void> Function(RoomOpenRequest request)? onOpenRoom;
  @visibleForTesting
  final Future<MatrixConversationSnapshot> Function()? snapshotLoader;

  /// Test-only workload probe.  Production callers never receive room data.
  @visibleForTesting
  final void Function(String roomId)? onRoomProjection;
  @visibleForTesting
  final void Function(String matrixUserId)? onIdentityProjection;
  @visibleForTesting
  final void Function(String roomId)? onConversationRowBuild;
  @override
  State<MatrixHomePage> createState() => _MatrixHomePageState();
}

class _MatrixHomePageState extends State<MatrixHomePage> {
  bool syncing = false;
  StreamSubscription<Object?>? syncSubscription;
  StreamSubscription<MatrixDecryptionUpdate>? decryptionSubscription;
  final SnapshotRefreshCoordinator<MatrixConversationSnapshot>
      _snapshotRefresh = SnapshotRefreshCoordinator();
  var _snapshotOwnerEpoch = 0;
  late DecryptionStateController decryptionStates;
  List<_RoomSnapshot> _rooms = const [];
  final Map<String, _RoomProjectionCacheEntry> _roomProjectionCache = {};
  final Map<String, _ConversationRowCacheEntry> _conversationRows = {};
  String? _vaultRoomId;
  String? _reminderRoomId;
  Timer? _presenceTimer;

  /// 正在打开（等待动画已显示）的 roomId：只对同一房间去重，跨房间不阻塞。
  final Set<String> _openingRooms = <String>{};
  final ConversationReadState _readState = ConversationReadState.shared();
  bool? _autoAllowGroupJoin;
  final Set<String> _autoJoinInFlight = {};
  final Set<String> _directJoinInFlight = {};
  List<MatrixGroupInviteSnapshot> _invites = const [];
  late ProfileRepository _identityCache;
  late SupportIdentityRepository _supportIdentities;
  Timer? _supportTimer;

  Future<void> _loadAutoAllowPreference() async {
    if (_autoAllowGroupJoin != null) return;
    try {
      _autoAllowGroupJoin = await widget.api.autoAllowGroupJoin();
    } catch (_) {
      _autoAllowGroupJoin = true;
    }
    if (mounted) setState(() {});
  }

  Future<void> _processPendingGroupInvites() async {
    if (widget.previewOnly) return;
    try {
      await _loadAutoAllowPreference();
      if (_autoAllowGroupJoin == true) {
        await widget.matrix.conversations
            .autoJoinGroupInvites(_autoJoinInFlight);
      }
      final invites = await widget.matrix.conversations.pendingGroupInvites();
      if (mounted) setState(() => _invites = invites);
    } catch (_) {/* Retry after the next sync. */}
  }

  Future<void> _processPendingDirectInvites() async {
    if (widget.previewOnly) return;
    try {
      await _identityCache.preload();
      await widget.matrix.conversations.autoJoinDirectInvites(
          _identityCache.contactsByMatrixId.keys.toSet(), _directJoinInFlight);
      // m.direct 目录收敛（同一好友单条目，绝不 leave）：canonical 查询走
      // 业务 API 权威目录，断网时在收敛服务内回退本地规则；失败静默，下次
      // sync 重试。列表唯一性另有 ConversationIdentityResolver 兜底。
      unawaited(widget.matrix.conversations.convergeDirectRoomDirectory(
              canonicalRoomIdOf:
                  ApiDirectRoomCoordinator(widget.api).canonicalRoomId)
          .catchError((_) {}));
      await _refreshClientSnapshot();
    } catch (_) {/* Contact availability is required; retry after sync. */}
  }

  List<MatrixGroupInviteSnapshot> get _pendingInviteRooms =>
      _autoAllowGroupJoin == false ? _invites : const [];

  Future<void> _acceptGroupInvite(MatrixGroupInviteSnapshot room) async {
    try {
      await widget.matrix.conversations.acceptGroupInvite(room.id);
      await _processPendingGroupInvites();
      await _refreshClientSnapshot();
    } catch (_) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
                  title: const Text('加入失败'),
                  content: const Text('请稍后重试。'),
                  actions: [
                    CupertinoDialogAction(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('好的'))
                  ]));
    }
  }

  Future<void> _declineGroupInvite(MatrixGroupInviteSnapshot room) async {
    try {
      await widget.matrix.conversations.declineGroupInvite(room.id);
      await _processPendingGroupInvites();
    } catch (_) {/* Preserve the invitation so it can be retried. */}
  }

  Future<void> sync() async {
    if (syncing) return;
    setState(() => syncing = true);
    try {
      await widget.matrix.syncIfActive();
      await _reconcileConversationMetadata();
      await _refreshClientSnapshot();
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  Future<void> _reconcileConversationMetadata() async {
    await widget.matrix.conversations.reconcileMetadata();
  }

  @override
  void initState() {
    super.initState();
    decryptionStates = DecryptionStateController();
    _identityCache = widget.identityCache ?? ProfileRepository(widget.api);
    _supportIdentities = SupportIdentityRepository(widget.api);
    conversationPreferencesChanged.addListener(_preferencesChanged);
    if (widget.previewOnly) {
      unawaited(_refreshClientSnapshot());
      return;
    }
    _identityCache.addListener(_identityChanged);
    RoomMentionStore.shared.addListener(_mentionsChanged);
    _scanMentions();
    _attachMatrixListeners();
    unawaited(_loadAutoAllowPreference());
    unawaited(_processPendingGroupInvites());
    unawaited(_processPendingDirectInvites());
    unawaited(_identityCache.preload().catchError((_) {}));
    _sendPresenceHeartbeat();
    _presenceTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _sendPresenceHeartbeat();
      // Renew short-lived profile image URLs without clearing visible avatars.
      unawaited(_identityCache.refreshContactsQuietly());
    });
    _supportTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _warmSupportIdentities(_rooms, force: true);
    });
    unawaited(_refreshClientSnapshot());
    unawaited(_refreshMembers());
    unawaited(sync().catchError((_) {}));
  }

  void _attachMatrixListeners() {
    final matrix = widget.matrix;
    syncSubscription = matrix.syncEvents.listen((_) {
      if (!mounted || !identical(widget.matrix, matrix)) return;
      _scanMentions();
      unawaited(_refreshClientSnapshot());
      unawaited(_refreshMembers());
      unawaited(_restoreHiddenConversations().catchError((_) {}));
      unawaited(_processPendingGroupInvites());
      unawaited(_processPendingDirectInvites());
    });
    decryptionSubscription = matrix.decryptionUpdates.listen((update) {
      if (!mounted || !identical(widget.matrix, matrix)) return;
      switch (update.state) {
        case MessageDecryptionState.decrypted:
          decryptionStates.lateKeyReceived(update.eventId);
        case MessageDecryptionState.missingKey:
          decryptionStates.markMissingKey(update.eventId,
              eventCode: update.eventCode ?? 'MISSING_ROOM_KEY');
        case MessageDecryptionState.decrypting:
          decryptionStates.markDecrypting(update.eventId);
        case MessageDecryptionState.failed:
          decryptionStates.markFailed(update.eventId,
              eventCode: update.eventCode ?? 'DECRYPTION_FAILED');
      }
      unawaited(_refreshClientSnapshot());
    });
  }

  void _detachMatrixListeners() {
    unawaited(syncSubscription?.cancel() ?? Future<void>.value());
    syncSubscription = null;
    unawaited(decryptionSubscription?.cancel() ?? Future<void>.value());
    decryptionSubscription = null;
  }

  Future<void> _sendPresenceHeartbeat() async {
    try {
      await widget.api.sendPresenceHeartbeat(
          clientVersion:
              'flutter-${AppConfig.appVersionName}+${AppConfig.appBuildNumber}');
    } catch (_) {
      // Presence is best-effort and never blocks encrypted messaging.
    }
  }

  Future<void> _restoreHiddenConversations() async {
    final matrix = widget.matrix;
    await matrix.conversations.restoreHidden();
    if (!mounted || !identical(widget.matrix, matrix)) return;
    await _refreshClientSnapshot();
  }

  void _preferencesChanged() {
    unawaited(_refreshClientSnapshot());
    widget.onUnreadChanged?.call();
  }

  Future<void> _refreshClientSnapshot() async {
    final ownerEpoch = _snapshotOwnerEpoch;
    final matrix = widget.matrix;
    final loader = widget.snapshotLoader ?? matrix.conversations.snapshot;
    try {
      await _snapshotRefresh.request(loader, onValue: (snapshot) {
        if (!mounted ||
            ownerEpoch != _snapshotOwnerEpoch ||
            !identical(widget.matrix, matrix)) {
          return;
        }
        final nextRooms = <_RoomSnapshot>[];
        final liveRoomIds = <String>{};
        for (final room in snapshot.rooms) {
          liveRoomIds.add(room.id);
          final signature = _RoomInputSignature.fromRoom(
              room,
              _roomTime(room),
              _conversationUnread(room),
              room.lastEvent == null
                  ? null
                  : decryptionStates
                      .knownStateFor(room.lastEvent!.eventId)
                      ?.state);
          final cached = _roomProjectionCache[room.id];
          if (cached != null && cached.signature == signature) {
            nextRooms.add(cached.snapshot);
          } else {
            final projected = _snapshotRoom(room);
            _roomProjectionCache[room.id] =
                _RoomProjectionCacheEntry(signature, projected);
            nextRooms.add(projected);
            widget.onRoomProjection?.call(room.id);
          }
        }
        _roomProjectionCache.removeWhere((id, _) => !liveRoomIds.contains(id));
        _conversationRows.removeWhere((id, _) => !liveRoomIds.contains(id));
        _conversationKeys.removeWhere((id, _) => !liveRoomIds.contains(id));
        final changed = _vaultRoomId != snapshot.vaultRoomId ||
            _reminderRoomId != snapshot.reminderRoomId ||
            !_sameRoomSnapshots(_rooms, nextRooms);
        if (!changed) return;
        setState(() {
          _vaultRoomId = snapshot.vaultRoomId;
          _reminderRoomId = snapshot.reminderRoomId;
          _rooms = List.unmodifiable(nextRooms);
        });
        _warmSupportIdentities(nextRooms);
      });
    } catch (_) {/* Keep cached presentation during sync/revocation. */}
  }

  Future<void> _refreshMembers() async {
    try {
      final matrix = widget.matrix;
      await matrix.conversations.refreshMembers();
      if (!mounted || !identical(widget.matrix, matrix)) return;
      await _refreshClientSnapshot();
    } catch (_) {/* Retry on a later sync. */}
  }

  _RoomSnapshot _snapshotRoom(MatrixConversationRoomSnapshot room) {
    final preference = room.preference;
    final members =
        room.isDirect ? const <MatrixMemberSnapshot>[] : room.members;
    final peer = room.isDirect && room.directPeerId != null
        ? _personAvatar(room.directPeerId!, room.avatar)
        : (seed: room.id, uri: room.avatar, profileUrl: null);
    return _RoomSnapshot(
      id: room.id,
      displayName: room.displayName,
      title: _conversationTitle(room),
      subtitle: _conversationSubtitle(room),
      timeLabel: _roomTime(room),
      lastBody: room.lastEvent?.body ?? '',
      lastActivity: conversationSortAnchor(room),
      avatar: peer.uri,
      avatarSeed: peer.seed,
      avatarProfileUrl: peer.profileUrl,
      groupMembers: members,
      preference: preference,
      unread: _conversationUnread(room),
      muted: preference.muted || !room.notificationsEnabled,
      isDirect: room.isDirect,
      directPeerId: room.directPeerId,
      lastEventId: room.lastEvent?.eventId,
      groupName: room.name,
      memberCount: room.members.length,
    );
  }

  ConversationAvatarIdentity _personAvatar(String matrixId, Uri? matrixAvatar) {
    final identity = _identityCache.resolveIdentity(
        matrixUserId: matrixId,
        username: matrixId == widget.matrix.userId
            ? _identityCache.profile?.username
            : null);
    return (
      seed: identity.cacheKey,
      uri: identity.avatarIsKnown ? null : matrixAvatar,
      profileUrl: identity.avatarUrl
    );
  }

  _RoomAvatarSnapshot _snapshotMemberAvatar(MatrixMemberSnapshot member) {
    final avatar = _personAvatar(member.id, member.avatar);
    return _RoomAvatarSnapshot(
        _identityCache
            .resolveIdentity(
                matrixUserId: member.id, displayName: member.displayName)
            .displayName,
        avatar.seed,
        avatar.uri,
        avatar.profileUrl);
  }

  void _mentionsChanged() {
    if (mounted) setState(() {});
  }

  void _scanMentions() {
    unawaited(widget.matrix.scanMentions().catchError((_) {}));
  }

  @override
  void dispose() {
    _snapshotOwnerEpoch++;
    conversationPreferencesChanged.removeListener(_preferencesChanged);
    RoomMentionStore.shared.removeListener(_mentionsChanged);
    _identityCache.removeListener(_identityChanged);
    _detachMatrixListeners();
    _presenceTimer?.cancel();
    _supportTimer?.cancel();
    _supportIdentities.dispose();
    decryptionStates.dispose();
    super.dispose();
  }

  void _warmSupportIdentities(Iterable<_RoomSnapshot> rooms,
      {bool force = false}) {
    unawaited(_supportIdentities.warm([
      for (final room in rooms)
        if (room.isDirect && room.directPeerId != null) room.directPeerId,
    ], force: force));
  }

  void _identityChanged() {
    // A repository refresh can publish an equivalent projection.  Until the
    // keyed identity subscription lands, correctness requires invalidation.
    _roomProjectionCache.clear();
    _conversationRows.clear();
    unawaited(_processPendingDirectInvites());
    unawaited(_refreshClientSnapshot());
  }

  @override
  void didUpdateWidget(covariant MatrixHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final accountChanged = !identical(widget.matrix, oldWidget.matrix) &&
        oldWidget.matrix.userId != widget.matrix.userId;
    if (!identical(widget.api, oldWidget.api)) {
      _supportIdentities.dispose();
      _supportIdentities = SupportIdentityRepository(widget.api);
      _conversationRows.clear();
      _warmSupportIdentities(_rooms);
    }
    if (accountChanged && identical(widget.api, oldWidget.api)) {
      _supportIdentities.dispose();
      _supportIdentities = SupportIdentityRepository(widget.api);
      _conversationRows.clear();
    }
    final replacementIdentity = widget.identityCache;
    var identityChanged = false;
    if (replacementIdentity != null && replacementIdentity != _identityCache) {
      _identityCache.removeListener(_identityChanged);
      _identityCache = replacementIdentity;
      identityChanged = true;
      if (!widget.previewOnly) _identityCache.addListener(_identityChanged);
    } else if (accountChanged && replacementIdentity == null) {
      _identityCache.removeListener(_identityChanged);
      _identityCache = ProfileRepository(widget.api);
      identityChanged = true;
      if (!widget.previewOnly) _identityCache.addListener(_identityChanged);
    }
    if (identityChanged) {
      _roomProjectionCache.clear();
      _conversationRows.clear();
      if (!widget.previewOnly) {
        unawaited(_identityCache.preload().catchError((_) {}));
      }
      unawaited(_refreshClientSnapshot());
    }
    if (!identical(widget.matrix, oldWidget.matrix)) {
      _snapshotOwnerEpoch++;
      _roomProjectionCache.clear();
      _conversationRows.clear();
      _conversationKeys.clear();
      _detachMatrixListeners();
      if (accountChanged) {
        decryptionStates.dispose();
        decryptionStates = DecryptionStateController();
        setState(() {
          _rooms = const [];
          _roomProjectionCache.clear();
          _conversationRows.clear();
          _conversationKeys.clear();
          _vaultRoomId = null;
          _reminderRoomId = null;
        });
      }
      if (!widget.previewOnly) _attachMatrixListeners();
      unawaited(_refreshClientSnapshot());
    }
  }

  String _roomTime(MatrixConversationRoomSnapshot room) {
    final timestamp = room.lastEvent?.originServerTs.toLocal();
    if (timestamp == null) return '';
    final now = DateTime.now();
    if (timestamp.year == now.year &&
        timestamp.month == now.month &&
        timestamp.day == now.day) {
      return '${timestamp.hour.toString().padLeft(2, '0')}:'
          '${timestamp.minute.toString().padLeft(2, '0')}';
    }
    return '${timestamp.month}/${timestamp.day}';
  }

  ConversationIdentity _memberIdentity(MatrixMemberSnapshot member) {
    widget.onIdentityProjection?.call(member.id);
    final own = member.id == widget.matrix.userId;
    final contact = _identityCache.contactsByMatrixId[member.id];
    final profile = own ? _identityCache.profile : null;
    return ConversationIdentity(
      matrixUserId: member.id,
      remark: contact?.remark,
      nickname: profile?.nickname ?? contact?.nickname,
      username: profile?.username ?? contact?.username,
      matrixDisplayName: member.displayName,
    );
  }

  String _conversationTitle(MatrixConversationRoomSnapshot room) {
    if (room.isDirect) {
      final peerId = room.directPeerId ?? room.displayName;
      final peer = room.members.firstWhere(
        (member) => member.id == peerId,
        orElse: () => MatrixMemberSnapshot(
          id: peerId,
          displayName: room.displayName,
          avatar: room.avatar,
        ),
      );
      return directConversationTitle(_memberIdentity(peer));
    }
    final explicitName = room.name.trim();
    if (explicitName.isNotEmpty) return explicitName;
    final title = groupConversationTitle(
      room.members.map(_memberIdentity).toList(growable: false),
      groupName: explicitName,
    );
    return title.isEmpty ? '未命名' : title;
  }

  int _conversationUnread(MatrixConversationRoomSnapshot room) {
    final preference = room.preference;
    return _readState.unreadCount(
      roomId: room.id,
      serverUnreadCount: room.notificationCount,
      lastEventId: room.lastEvent?.eventId,
      lastEventSenderId: room.lastEvent?.senderId,
      currentUserId: widget.matrix.userId,
      manualUnread: preference.manualUnread,
    );
  }

  String _conversationSubtitle(MatrixConversationRoomSnapshot room) {
    final event = room.lastEvent;
    if (event == null) return '';
    final state = decryptionStates.knownStateFor(event.eventId)?.state ??
        event.decryptionState;
    if (state != MessageDecryptionState.decrypted) return '';
    final messageContent = conversationEventSummaryLabel(
          messageType: event.messageType,
          content: event.content,
          eventType: event.type,
        ) ??
        safeConversationMessageContent(
            decryptionState: state, messageContent: event.text);
    if (room.isDirect) return messageContent;
    final sender = conversationSenderName(
      _memberIdentity(event.sender),
    );
    final isSenderMessage = event.type == 'm.room.message' ||
        event.type == 'm.room.encrypted' ||
        event.type == changliaoNudgeEventType;
    return groupConversationSubtitle(
      unreadCount: _conversationUnread(room),
      senderName: sender,
      messageContent: messageContent,
      redacted: event.redacted,
      systemSummary: isSenderMessage ? null : event.text,
    );
  }

  Future<void> _showMore() => showTopMoreMenu(context,
      onCreateGroup: widget.onCreateGroup,
      onAddFriend: () => Navigator.push(
          context,
          MotionPageRoute(
              builder: (_) => AddFriendPage(
                  contactActions: ContactActions(
                    onMessage: widget.onMessage,
                    onVoice: widget.onVoice,
                    onVideo: widget.onVideo,
                  ),
                  api: widget.api,
                  identityCache: _identityCache))),
      onScan: () => Navigator.of(context, rootNavigator: true).push(
          MotionPageRoute(
              fullscreenDialog: true,
              builder: (_) => ScanQrPage(
                  api: widget.api,
                  groupJoinApi: widget.api,
                  identityCache: _identityCache,
                  onGroupJoined: (roomId) => unawaited(
                      _openRoomById(roomId, source: RoomOpenSource.scan))))),
      onAppearance: () => showThemePickerSheet(context, widget.themeController),
      appearanceKey: const Key('messages-appearance'));
  Future<void> _openRoomById(
    String roomId, {
    String? roomName,
    String? anchorEventId,
    RoomOpenSource source = RoomOpenSource.search,
  }) async {
    if (roomId.isEmpty || widget.previewOnly) return;
    // 离线优先：本地会话列表里已经有这个房间时**立即**走统一入口打开，
    // 不再先 `waitForJoinedRoom`（旧实现在离线/弱网下让用户点了没反应，
    // 并且是最长 12 秒的静默等待）。
    final matches = _rooms.where((room) => room.id == roomId);
    final local = matches.isEmpty ? null : matches.first;
    if (local != null) {
      await _openRoom(local, anchorEventId: anchorEventId, source: source);
      return;
    }
    // 本地未知（刚入群 / 冷启动尚未同步）：交给组合根的 RoomOpeningPolicy
    // 做有界网络等待；失败由组合根统一提示，这里绝不静默吞错。
    final openRoom = widget.onOpenRoom;
    if (openRoom == null) return;
    await openRoom(RoomOpenRequest(
      roomId: roomId,
      roomName: roomName ?? '',
      anchorEventId: anchorEventId,
      source: source,
      onRoomClosed: () {
        if (mounted) unawaited(_refreshClientSnapshot());
      },
    ));
  }

  Future<void> _warmChatIdentity(
      [Iterable<String> matrixUserIds = const []]) async {
    final cache = _identityCache;
    final matrix = widget.matrix;
    try {
      await cache.preload();
      if (!mounted ||
          !identical(cache, _identityCache) ||
          !identical(matrix, widget.matrix)) {
        return;
      }
      await cache.precacheAvatarImages(context,
          matrixUserIds: matrixUserIds,
          shouldContinue: () =>
              mounted &&
              identical(cache, _identityCache) &&
              identical(matrix, widget.matrix));
    } catch (_) {
      // Keep the last successful identity snapshot while offline.
    }
  }

  Future<void> _openRoom(_RoomSnapshot snapshot,
      {String? anchorEventId,
      RoomOpenSource source = RoomOpenSource.conversationList}) async {
    // 只读占位页（启动期缓存列表）与未注入统一导航时不打开房间。
    final openRoom = widget.onOpenRoom;
    if (widget.previewOnly || openRoom == null) return;
    // 同一房间的重复点击只保留一次等待动画；跨房间不互相阻塞
    // （旧实现用全局 bool，关掉房间后取消租约期间会吞掉下一个会话）。
    if (!_openingRooms.add(snapshot.id)) return;
    // 立即反馈：取租约期间（弱网/低端机可达数秒）显示悬浮转圈。
    // 必须用 Overlay 而非 modal route——低端机（荣耀50 Plus）上
    // “开 modal→pop→push”三者同帧竞争路由动画会吞掉房间 push，
    // 表现为点击永远无响应；Overlay 不进路由栈，无此竞态。
    final overlay = OverlayEntry(
      builder: (_) => const Positioned.fill(
        child: ColoredBox(
          color: Color(0x33000000),
          child: Center(child: CupertinoActivityIndicator(radius: 16)),
        ),
      ),
    );
    var overlayRemoved = false;
    void removeOverlay() {
      if (overlayRemoved) return;
      overlayRemoved = true;
      overlay.remove();
    }

    Overlay.of(context, rootOverlay: true).insert(overlay);
    unawaited(_warmChatIdentity(
        snapshot.groupMembers.take(9).map((member) => member.id)));
    try {
      await openRoom(RoomOpenRequest(
        roomId: snapshot.id,
        roomName: snapshot.isDirect
            ? snapshot.title
            : groupRoomNavigationTitle(
                snapshot.groupName, snapshot.memberCount),
        anchorEventId: anchorEventId,
        source: source,
        // 租约已取、页面尚未 push：先收起等待动画，再完成本房间的
        // 已读/未读收尾。
        onRoomReady: () {
          removeOverlay();
          _readState.setRoomOpen(snapshot.id, open: true);
          _readState.markCleared(snapshot.id, eventId: snapshot.lastEventId);
          unawaited(widget.matrix.conversations
              .markReadOnOpen(snapshot.id)
              .catchError((_) {}));
          widget.onUnreadChanged?.call();
        },
        // 页面退出（或打开失败）后恢复列表态。
        onRoomClosed: () {
          _readState.setRoomOpen(snapshot.id, open: false);
          final latest = _rooms.where((room) => room.id == snapshot.id);
          _readState.markCleared(snapshot.id,
              eventId: latest.isEmpty
                  ? snapshot.lastEventId
                  : latest.first.lastEventId);
          if (mounted) {
            unawaited(_refreshClientSnapshot());
            widget.onUnreadChanged?.call();
          }
        },
      ));
    } catch (_) {
      // 房间打开失败由统一入口负责租约与登记清理；列表侧只需收尾等待动画。
      // （旧实现把错误抛成未捕获异步异常，用户同样看不到任何反馈。）
    } finally {
      removeOverlay();
      _openingRooms.remove(snapshot.id);
    }
  }

  final Map<String, GlobalKey> _conversationKeys = {};

  bool _sameRoomSnapshots(
      List<_RoomSnapshot> previous, List<_RoomSnapshot> next) {
    if (previous.length != next.length) return false;
    for (var index = 0; index < previous.length; index++) {
      if (!identical(previous[index], next[index])) return false;
    }
    return true;
  }

  Widget _conversationRow(_RoomSnapshot room) {
    final hasMention = widget.matrix.hasPendingMentions(room.id);
    final cached = _conversationRows[room.id];
    if (cached != null &&
        identical(cached.snapshot, room) &&
        cached.hasMention == hasMention) {
      return cached.widget;
    }
    final row = KeyedSubtree(
      key: _conversationKeys.putIfAbsent(room.id, () => GlobalKey()),
      child: ConversationListTile(
        key: ValueKey<String>('conversation-${room.id}'),
        title: room.title,
        supportIdentities: room.isDirect ? _supportIdentities : null,
        matrixUserId: room.isDirect ? room.directPeerId : null,
        subtitle: room.subtitle,
        hasPendingMention: hasMention,
        timeLabel: room.timeLabel,
        avatar: room.isDirect || room.avatar != null
            ? MatrixUserAvatar(
                avatarMedia: widget.matrix,
                nickname: room.title,
                fallbackSeed: room.avatarSeed,
                matrixAvatarUri: room.avatar,
                fallbackAvatarUrl: room.avatarProfileUrl,
                diagnosticSource: 'messages-conversation',
                size: WeChatDimensions.conversationAvatar)
            : GroupAvatarMosaic(avatars: [
                for (final member in room.groupMembers.take(9))
                  _memberAvatarWidget(member),
              ]),
        unreadCount: room.unread,
        muted: room.muted,
        pinnedGroup: room.preference.pinned,
        onTap: () => _openRoom(room),
        onLongPress: () =>
            _conversationActions(room, _conversationAnchor(room.id)),
      ),
    );
    _conversationRows[room.id] =
        _ConversationRowCacheEntry(room, hasMention, row);
    widget.onConversationRowBuild?.call(room.id);
    return row;
  }

  Widget _memberAvatarWidget(MatrixMemberSnapshot member) {
    final avatar = _snapshotMemberAvatar(member);
    return MatrixUserAvatar(
      avatarMedia: widget.matrix,
      nickname: avatar.nickname,
      fallbackSeed: avatar.fallbackSeed,
      matrixAvatarUri: avatar.uri,
      fallbackAvatarUrl: avatar.profileUrl,
      diagnosticSource: 'messages-group-member',
    );
  }

  Rect? _conversationAnchor(String roomId) {
    final box = _conversationKeys[roomId]?.currentContext?.findRenderObject();
    return box is RenderBox ? box.localToGlobal(Offset.zero) & box.size : null;
  }

  Future<void> _conversationActions(_RoomSnapshot snapshot,
      [Rect? anchor]) async {
    final action = await showConversationActionSheet(
      context,
      pinned: snapshot.preference.pinned,
      anchor: anchor,
      onAction: (_) {},
    );
    if (!mounted || action == null) return;
    var confirmedDelete = false;
    if (action == ConversationAction.delete) {
      confirmedDelete = await showCupertinoDialog<bool>(
            context: context,
            builder: (dialogContext) => CupertinoAlertDialog(
              title: const Text('确定删除该聊天？'),
              content: const Text('删除此设备上的聊天记录，不会退出群聊'),
              actions: [
                CupertinoDialogAction(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('取消'),
                ),
                CupertinoDialogAction(
                  isDestructiveAction: true,
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('删除'),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmedDelete) return;
    }
    final mutation = switch (action) {
      ConversationAction.markUnread => MatrixConversationMutation.markUnread,
      ConversationAction.togglePin => MatrixConversationMutation.togglePin,
      ConversationAction.hide => MatrixConversationMutation.hide,
      ConversationAction.delete => MatrixConversationMutation.delete,
    };
    try {
      await widget.matrix.conversations.mutate(snapshot.id, mutation);
      if (action == ConversationAction.delete) {
        await StatisticsStateStore.clear(snapshot.id);
      }
      await _refreshClientSnapshot();
    } catch (_) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
          context: context,
          builder: (dialogContext) =>
              CupertinoAlertDialog(title: const Text('操作失败，请重试'), actions: [
                CupertinoDialogAction(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('好'))
              ]));
    }
  }

  @override
  Widget build(BuildContext context) {
    // 控制房间过滤统一走 RoomVisibilityPolicy（accountData 引用的 roomId），
    // 不再按展示名判定；同一条规则也用于"是否允许打开"。
    final roomVisibility =
        RoomVisibilityPolicy.forRoomIds([_vaultRoomId, _reminderRoomId]);
    final visibleRooms = _rooms
        .where((room) => roomVisibility.isVisible(room.id))
        .toList(growable: false);
    final roomById = {for (final room in visibleRooms) room.id: room};
    final ordered = orderConversations([
      for (final room in visibleRooms)
        ConversationProjection(
          roomId: room.id,
          isGroup: !room.isDirect,
          lastActivity: room.lastActivity,
          preference: room.preference,
        ),
    ]);
    final orderedRooms = [for (final item in ordered) roomById[item.roomId]!];
    final activeRooms = orderedRooms
        .where((room) => !room.preference.hidden)
        .toList(growable: false);
    final foldedRooms = activeRooms.where((room) {
      final value = room.preference;
      return !room.isDirect && value.muted && value.folded;
    }).toList(growable: false);
    final rooms = activeRooms
        .where((room) => !foldedRooms.contains(room))
        .toList(growable: false);
    final pinnedCount = rooms.where((room) => room.preference.pinned).length;
    return WeChatPageScaffold.navigation(
      backgroundColor: WeChatColors.pageBackground(context),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.navigationBackground(context),
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        transitionBetweenRoutes: false,
        middle: const WeChatNavTitle('消息'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          CupertinoButton(
            key: const Key('messages-search'),
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.push(
                context,
                MotionPageRoute(
                    builder: (_) => GlobalSearchPage(
                          contactActions: ContactActions(
                            onMessage: widget.onMessage,
                            onVoice: widget.onVoice,
                            onVideo: widget.onVideo,
                          ),
                          api: widget.api,
                          matrix: widget.matrix,
                          identityCache: _identityCache,
                          // 房间打开复用消息列表既有的 RoomLease/RoomPage 生命周期
                          // （含 anchor 定位），搜索页不复制一套开会话实现；
                          // 网络姿态由 RoomOpeningPolicy 按 source=search 决定
                          // （离线优先：本地已知的会话不再等待同步）。
                          onOpenRoom: (room, {anchorEventId}) =>
                              _openRoomById(room.roomId,
                                  roomName: room.displayName,
                                  anchorEventId: anchorEventId,
                                  source: RoomOpenSource.search),
                        ))),
            child: const Icon(CupertinoIcons.search, size: 22),
          ),
          CupertinoButton(
            key: const Key('messages-more'),
            padding: EdgeInsets.zero,
            onPressed: _showMore,
            child: const Icon(ChangliaoIcons.more, size: 22),
          ),
        ]),
      ),
      child: SafeArea(
        child: Builder(builder: (context) {
          final invites = _pendingInviteRooms;
          final body = rooms.isEmpty && foldedRooms.isEmpty && invites.isEmpty
              ? const _MessagesEmptyState()
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: invites.length +
                      rooms.length +
                      (foldedRooms.isEmpty ? 0 : 1),
                  separatorBuilder: (_, __) => Padding(
                    padding: EdgeInsets.only(
                      left: WeChatSpacing.lg +
                          WeChatDimensions.conversationAvatar +
                          WeChatSpacing.md,
                    ),
                    child: SizedBox(
                      height: 0.5,
                      child: ColoredBox(
                          color: WeChatColors.resolve(
                              context, WeChatColors.divider)),
                    ),
                  ),
                  itemBuilder: (context, index) {
                    if (index < invites.length) {
                      final invite = invites[index];
                      return KeyedSubtree(
                        key: ValueKey<String>('pending-invite-${invite.id}'),
                        child: PendingGroupInviteTile(
                          roomId: invite.id,
                          roomName: invite.name.trim(),
                          onAccept: () => _acceptGroupInvite(invite),
                          onDecline: () => _declineGroupInvite(invite),
                        ),
                      );
                    }
                    final adjustedIndex = index - invites.length;
                    if (foldedRooms.isNotEmpty &&
                        adjustedIndex == pinnedCount) {
                      return ConversationListTile(
                        key: const Key('folded-group-chats'),
                        title: '折叠的群聊',
                        subtitle: '${foldedRooms.length} 个聊天',
                        timeLabel: '',
                        avatar: ColoredBox(
                          color: WeChatColors.resolve(
                              context, WeChatColors.lightSurface),
                          child: Icon(CupertinoIcons.tray_full, size: 25),
                        ),
                        onTap: () => Navigator.push<void>(
                          context,
                          MotionPageRoute(
                            builder: (_) => _FoldedGroupChatsPage(
                              hasPendingMention:
                                  widget.matrix.hasPendingMentions,
                              rooms: foldedRooms,
                              avatarMedia: widget.matrix,
                              memberAvatar: _snapshotMemberAvatar,
                              onOpen: (room) {
                                Navigator.pop(context);
                                _openRoom(room);
                              },
                            ),
                          ),
                        ),
                      );
                    }
                    var roomIndex = adjustedIndex;
                    if (foldedRooms.isNotEmpty && adjustedIndex > pinnedCount) {
                      roomIndex = adjustedIndex - 1;
                    }
                    final room = rooms[roomIndex];
                    return _conversationRow(room);
                  },
                );
          return Column(
            children: [
              // BUG1（被邀端，关闭自动入群）：会话列表顶部可接受/拒绝的
              // 待处理群邀请——绝不静默停留在隐藏 invite 状态。
              if (invites.isNotEmpty)
                Container(
                  key: const Key('pending-group-invites'),
                  color: WeChatColors.elevatedSurface(context),
                  padding: const EdgeInsets.symmetric(
                      horizontal: WeChatSpacing.md, vertical: WeChatSpacing.xs),
                  child: Row(
                    children: [
                      const Icon(CupertinoIcons.person_3_fill,
                          size: 18, color: WeChatColors.textSecondary),
                      const SizedBox(width: WeChatSpacing.sm),
                      Expanded(
                        child: Text(
                          '群聊邀请（${invites.length}）',
                          style: const TextStyle(
                            fontSize: 13,
                            color: WeChatColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(child: body),
            ],
          );
        }),
      ),
    );
  }
}

/// 单条待处理群邀请 tile：群名 + 邀请文案 + 接受/拒绝（公开、数据
/// 驱动，便于 widget 测试）。
final class PendingGroupInviteTile extends StatelessWidget {
  const PendingGroupInviteTile({
    super.key,
    required this.roomId,
    required this.roomName,
    required this.onAccept,
    required this.onDecline,
  });

  final String roomId;
  final String roomName;
  final VoidCallback? onAccept;
  final VoidCallback? onDecline;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: WeChatSpacing.md, vertical: WeChatSpacing.xs),
        child: Row(
          children: [
            const Icon(CupertinoIcons.person_3_fill,
                size: 40, color: WeChatColors.textSecondary),
            const SizedBox(width: WeChatSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    roomName.trim().isEmpty ? '群聊邀请' : roomName.trim(),
                    style: const TextStyle(fontSize: 15),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    '邀请你加入群聊',
                    style: TextStyle(
                        fontSize: 12, color: WeChatColors.textSecondary),
                  ),
                ],
              ),
            ),
            CupertinoButton(
              key: ValueKey<String>('accept-invite-$roomId'),
              padding: EdgeInsets.zero,
              minimumSize: const Size(44, 32),
              onPressed: onAccept,
              child: const Text('接受',
                  style: TextStyle(color: WeChatColors.socialLink)),
            ),
            CupertinoButton(
              key: ValueKey<String>('decline-invite-$roomId'),
              padding: EdgeInsets.zero,
              minimumSize: const Size(44, 32),
              onPressed: onDecline,
              child: const Text('拒绝',
                  style: TextStyle(color: WeChatColors.textSecondary)),
            ),
          ],
        ),
      );
}

final class _MessagesEmptyState extends StatelessWidget {
  const _MessagesEmptyState();

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              ChangliaoIcons.messages,
              size: 48,
              color: WeChatColors.textSecondary,
            ),
            const SizedBox(height: WeChatSpacing.md),
            Text(
              '暂无消息',
              style: CupertinoTheme.of(context).textTheme.navTitleTextStyle,
            ),
            const SizedBox(height: WeChatSpacing.sm),
            const Text(
              '新的端到端加密会话会显示在这里',
              style: TextStyle(color: WeChatColors.textSecondary),
            ),
          ],
        ),
      );
}

final class _FoldedGroupChatsPage extends StatelessWidget {
  const _FoldedGroupChatsPage({
    required this.hasPendingMention,
    required this.rooms,
    required this.avatarMedia,
    required this.memberAvatar,
    required this.onOpen,
  });
  final List<_RoomSnapshot> rooms;
  final AvatarMediaCapability avatarMedia;
  final _RoomAvatarSnapshot Function(MatrixMemberSnapshot) memberAvatar;
  final bool Function(String) hasPendingMention;
  final ValueChanged<_RoomSnapshot> onOpen;

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text('折叠的群聊')),
        child: SafeArea(
          child: ListView.separated(
            itemCount: rooms.length,
            separatorBuilder: (_, __) => const SizedBox(height: .5),
            itemBuilder: (context, index) {
              final room = rooms[index];
              return ConversationListTile(
                title: room.title,
                subtitle: room.subtitle,
                hasPendingMention: hasPendingMention(room.id),
                timeLabel: '',
                muted: true,
                avatar: room.avatar != null
                    ? MatrixUserAvatar(
                        avatarMedia: avatarMedia,
                        nickname: room.displayName,
                        fallbackSeed: room.avatarSeed,
                        matrixAvatarUri: room.avatar,
                        fallbackAvatarUrl: room.avatarProfileUrl,
                      )
                    : GroupAvatarMosaic(
                        avatars: [
                          for (final member in room.groupMembers.take(9))
                            Builder(builder: (_) {
                              final avatar = memberAvatar(member);
                              return MatrixUserAvatar(
                                avatarMedia: avatarMedia,
                                nickname: avatar.nickname,
                                fallbackSeed: avatar.fallbackSeed,
                                matrixAvatarUri: avatar.uri,
                                fallbackAvatarUrl: avatar.profileUrl,
                              );
                            }),
                        ],
                      ),
                onTap: () => onOpen(room),
              );
            },
          ),
        ),
      );
}
