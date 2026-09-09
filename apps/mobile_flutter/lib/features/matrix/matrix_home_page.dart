import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../core/app_config.dart';
import '../../core/business_api_client.dart';
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
import 'matrix_user_avatar.dart';
import 'conversation_avatar_identity.dart';
import 'profile_repository.dart';
import 'conversation_preferences.dart';
import 'conversation_read_state.dart';
import 'conversation_presentation.dart';
import 'decryption_state_controller.dart';
export 'conversation_presentation.dart'
    show directRoomNavigationTitle, groupRoomNavigationTitle;
export 'room_page.dart' show RoomPage;
import '../search/global_search_page.dart';
import 'room_page.dart';
import 'matrix_control_rooms.dart';
import 'message_reminder_service.dart';
import '../statistics/statistics_state_store.dart';
import 'nudge_service.dart';

final class _RoomAvatarSnapshot {
  const _RoomAvatarSnapshot(
      this.nickname, this.fallbackSeed, this.uri, this.profileUrl);
  final String nickname;
  final String fallbackSeed;
  final Uri? uri;
  final String? profileUrl;
}

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
    required this.groupAvatars,
    required this.preference,
    required this.unread,
    required this.muted,
    required this.isDirect,
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
  final List<_RoomAvatarSnapshot> groupAvatars;
  final ConversationPreference preference;
  final int unread;
  final bool muted;
  final bool isDirect;
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
  @override
  State<MatrixHomePage> createState() => _MatrixHomePageState();
}

class _MatrixHomePageState extends State<MatrixHomePage> {
  bool syncing = false;
  StreamSubscription<Object?>? syncSubscription;
  StreamSubscription<MatrixDecryptionUpdate>? decryptionSubscription;
  late final DecryptionStateController decryptionStates =
      DecryptionStateController();
  List<_RoomSnapshot> _rooms = const [];
  String? _vaultRoomId;
  String? _reminderRoomId;
  Timer? _presenceTimer;
  bool _openingRoom = false;
  final ConversationReadState _readState = ConversationReadState.shared();
  bool? _autoAllowGroupJoin;
  final Set<String> _autoJoinInFlight = {};
  final Set<String> _directJoinInFlight = {};
  List<MatrixGroupInviteSnapshot> _invites = const [];
  late ProfileRepository _identityCache =
      widget.identityCache ?? ProfileRepository(widget.api);

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
    if (widget.previewOnly) {
      unawaited(_refreshClientSnapshot());
      return;
    }
    _identityCache.addListener(_identityChanged);
    syncSubscription = widget.matrix.syncEvents.listen((_) {
      unawaited(_refreshClientSnapshot());
      unawaited(_refreshMembers());
      unawaited(_restoreHiddenConversations().catchError((_) {}));
      unawaited(_processPendingGroupInvites());
      unawaited(_processPendingDirectInvites());
      if (mounted) setState(() {});
    });
    unawaited(_loadAutoAllowPreference());
    unawaited(_processPendingGroupInvites());
    unawaited(_processPendingDirectInvites());
    decryptionSubscription = widget.matrix.decryptionUpdates.listen((update) {
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
    unawaited(_identityCache.preload().catchError((_) {}));
    _sendPresenceHeartbeat();
    _presenceTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _sendPresenceHeartbeat();
      // Renew short-lived profile image URLs without clearing visible avatars.
      unawaited(_identityCache.refreshContactsQuietly());
    });
    unawaited(_refreshClientSnapshot());
    unawaited(_refreshMembers());
    unawaited(sync().catchError((_) {}));
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
    await widget.matrix.conversations.restoreHidden();
    await _refreshClientSnapshot();
  }

  int _snapshotEpoch = 0;
  Future<void> _refreshClientSnapshot() async {
    final epoch = ++_snapshotEpoch;
    try {
      final snapshot = await widget.matrix.conversations.snapshot();
      if (!mounted || epoch != _snapshotEpoch) return;
      setState(() {
        _vaultRoomId = snapshot.vaultRoomId;
        _reminderRoomId = snapshot.reminderRoomId;
        _rooms = [for (final room in snapshot.rooms) _snapshotRoom(room)];
      });
    } catch (_) {/* Keep cached presentation during sync/revocation. */}
  }

  Future<void> _refreshMembers() async {
    try {
      await widget.matrix.conversations.refreshMembers();
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
      lastActivity: room.lastEvent?.originServerTs ??
          DateTime.fromMillisecondsSinceEpoch(0),
      avatar: peer.uri,
      avatarSeed: peer.seed,
      avatarProfileUrl: peer.profileUrl,
      groupAvatars: [
        for (final member in members.take(9)) _snapshotMemberAvatar(member),
      ],
      preference: preference,
      unread: _conversationUnread(room),
      muted: preference.muted || !room.notificationsEnabled,
      isDirect: room.isDirect,
      lastEventId: room.lastEvent?.eventId,
      groupName: room.name,
      memberCount: room.members.length,
    );
  }

  ConversationAvatarIdentity _personAvatar(
          String matrixId, Uri? matrixAvatar) =>
      conversationAvatarIdentity(
        matrixUserId: matrixId,
        matrixAvatar: matrixAvatar,
        contact: _identityCache.contactsByMatrixId[matrixId],
        ownProfile:
            matrixId == widget.matrix.userId ? _identityCache.profile : null,
      );

  _RoomAvatarSnapshot _snapshotMemberAvatar(MatrixMemberSnapshot member) {
    final avatar = _personAvatar(member.id, member.avatar);
    return _RoomAvatarSnapshot(
        member.displayName, avatar.seed, avatar.uri, avatar.profileUrl);
  }

  @override
  void dispose() {
    _identityCache.removeListener(_identityChanged);
    syncSubscription?.cancel();
    _presenceTimer?.cancel();
    decryptionSubscription?.cancel();
    decryptionStates.dispose();
    super.dispose();
  }

  void _identityChanged() {
    unawaited(_processPendingDirectInvites());
    unawaited(_refreshClientSnapshot());
  }

  @override
  void didUpdateWidget(covariant MatrixHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.identityCache != null &&
        widget.identityCache != oldWidget.identityCache) {
      _identityCache.removeListener(_identityChanged);
      _identityCache = widget.identityCache!;
      if (!widget.previewOnly) _identityCache.addListener(_identityChanged);
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
    final title = groupConversationTitle(
      room.members.map(_memberIdentity).toList(growable: false),
      groupName: room.name,
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

  Future<void> _showMore() async {
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: const Text('新建会话'),
        actions: [
          _action(
            sheetContext,
            CupertinoIcons.group_solid,
            '发起群聊',
            widget.onCreateGroup,
          ),
          _action(
            sheetContext,
            CupertinoIcons.person_add_solid,
            '添加朋友',
            () => Navigator.push(
              context,
              CupertinoPageRoute(
                  builder: (_) => AddFriendPage(api: widget.api)),
            ),
          ),
          _action(
            sheetContext,
            CupertinoIcons.qrcode_viewfinder,
            '扫一扫',
            // 扫码统一入口：好友码 → 申请页；群码 → 群确认页（BUG2）。
            () => Navigator.of(context, rootNavigator: true).push(
              CupertinoPageRoute(
                fullscreenDialog: true,
                builder: (_) => ScanQrPage(
                  api: widget.api,
                  groupJoinApi: widget.api,
                  onGroupJoined: (roomId) => unawaited(_openRoomById(roomId)),
                ),
              ),
            ),
          ),
          CupertinoActionSheetAction(
            key: const Key('messages-appearance'),
            onPressed: () {
              Navigator.pop(sheetContext);
              showThemePickerSheet(context, widget.themeController);
            },
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.circle_lefthalf_fill, size: 20),
                SizedBox(width: 10),
                Text('外观'),
              ],
            ),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheetContext),
          child: const Text('取消'),
        ),
      ),
    );
  }

  Widget _action(
    BuildContext context,
    IconData icon,
    String label, [
    VoidCallback? action,
  ]) {
    return CupertinoActionSheetAction(
      onPressed: () {
        Navigator.pop(context);
        action?.call();
      },
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 10),
          Text(label),
        ],
      ),
    );
  }

  Future<void> _openRoomById(String roomId) async {
    if (roomId.isEmpty || widget.previewOnly) return;
    try {
      await widget.matrix.conversations.waitForJoinedRoom(roomId);
      await _refreshClientSnapshot();
      final matches = _rooms.where((room) => room.id == roomId);
      if (mounted && matches.isNotEmpty) await _openRoom(matches.first);
    } catch (_) {/* The next sync makes the room available in the list. */}
  }

  Future<void> _warmChatIdentity() async {
    try {
      await _identityCache.preload();
      if (!mounted) return;
      await _identityCache.precacheAvatarImages(context);
    } catch (_) {
      // Keep the last successful identity snapshot while offline.
    }
  }

  Future<void> _openRoom(_RoomSnapshot snapshot) async {
    if (_openingRoom || widget.previewOnly) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    _openingRoom = true;
    MatrixRoomLease? lease;
    _readState.setRoomOpen(snapshot.id, open: true);
    _readState.markCleared(snapshot.id, eventId: snapshot.lastEventId);
    unawaited(widget.matrix.conversations
        .markReadOnOpen(snapshot.id)
        .catchError((_) {}));
    widget.onUnreadChanged?.call();
    unawaited(_warmChatIdentity());
    try {
      lease = await widget.matrix.openRoomLease(snapshot.id);
      if (!mounted) return;
      final openedLease = lease;
      final route = CupertinoPageRoute<void>(
          builder: (_) => RoomPage(
                api: widget.api,
                roomLease: openedLease,
                roomName: snapshot.isDirect
                    ? snapshot.title
                    : groupRoomNavigationTitle(
                        snapshot.groupName, snapshot.memberCount),
                onCreateGroup: widget.onCreateGroup,
                onMessage: widget.onMessage,
                onVoice: widget.onVoice,
                onVideo: widget.onVideo,
                reminderService: widget.reminderService,
                initialIdentityCache: _identityCache,
              ));
      lease.setOnRevoked(() async {
        if (route.isActive) {
          navigator.popUntil((candidate) => identical(candidate, route));
          navigator.removeRoute(route);
        }
        await route.popped;
      });
      await navigator.push(route);
    } finally {
      await lease?.cancel();
      _readState.setRoomOpen(snapshot.id, open: false);
      final latest = _rooms.where((room) => room.id == snapshot.id);
      _readState.markCleared(snapshot.id,
          eventId:
              latest.isEmpty ? snapshot.lastEventId : latest.first.lastEventId);
      _openingRoom = false;
      if (mounted) {
        unawaited(_refreshClientSnapshot());
        widget.onUnreadChanged?.call();
      }
    }
  }

  Future<void> _conversationActions(_RoomSnapshot snapshot) async {
    final action = await showConversationActionSheet(
      context,
      pinned: snapshot.preference.pinned,
      onAction: (_) {},
    );
    if (!mounted || action == null) return;
    var confirmedDelete = false;
    if (action == ConversationAction.delete) {
      confirmedDelete = await showCupertinoDialog<bool>(
            context: context,
            builder: (dialogContext) => CupertinoAlertDialog(
              title: const Text('确定删除该聊天？'),
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
    await widget.matrix.conversations.mutate(snapshot.id, mutation);
    if (action == ConversationAction.delete) {
      await StatisticsStateStore.clear(snapshot.id);
    }
    await _refreshClientSnapshot();
  }

  @override
  Widget build(BuildContext context) {
    final visibleRooms = _rooms
        .where(
          (room) => !isMatrixControlRoom(
            roomId: room.id,
            displayName: room.displayName,
            vaultRoomId: _vaultRoomId,
            reminderRoomId: _reminderRoomId,
          ),
        )
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
                CupertinoPageRoute(
                    builder: (_) => GlobalSearchPage(
                          api: widget.api,
                          matrix: widget.matrix,
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
                          CupertinoPageRoute(
                            builder: (_) => _FoldedGroupChatsPage(
                              rooms: foldedRooms,
                              avatarMedia: widget.matrix,
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
                    final roomName = room.title;
                    final preference = room.preference;
                    return ConversationListTile(
                      key: ValueKey<String>('conversation-${room.id}'),
                      title: roomName,
                      subtitle: room.subtitle,
                      timeLabel: room.timeLabel,
                      avatar: room.isDirect || room.avatar != null
                          ? MatrixUserAvatar(
                              avatarMedia: widget.matrix,
                              nickname: roomName,
                              fallbackSeed: room.avatarSeed,
                              matrixAvatarUri: room.avatar,
                              fallbackAvatarUrl: room.avatarProfileUrl,
                              diagnosticSource: 'messages-conversation',
                              size: WeChatDimensions.conversationAvatar,
                            )
                          : GroupAvatarMosaic(
                              avatars: [
                                for (final member in room.groupAvatars)
                                  MatrixUserAvatar(
                                    avatarMedia: widget.matrix,
                                    nickname: member.nickname,
                                    fallbackSeed: member.fallbackSeed,
                                    matrixAvatarUri: member.uri,
                                    fallbackAvatarUrl: member.profileUrl,
                                    diagnosticSource: 'messages-group-member',
                                  ),
                              ],
                            ),
                      unreadCount: room.unread,
                      muted: room.muted,
                      pinnedGroup: !room.isDirect && preference.pinned,
                      onTap: () => _openRoom(room),
                      onLongPress: () => _conversationActions(room),
                    );
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
    required this.rooms,
    required this.avatarMedia,
    required this.onOpen,
  });
  final List<_RoomSnapshot> rooms;
  final AvatarMediaCapability avatarMedia;
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
                          for (final member in room.groupAvatars)
                            MatrixUserAvatar(
                              avatarMedia: avatarMedia,
                              nickname: member.nickname,
                              fallbackSeed: member.fallbackSeed,
                              matrixAvatarUri: member.uri,
                              fallbackAvatarUrl: member.profileUrl,
                            ),
                        ],
                      ),
                onTap: () => onOpen(room),
              );
            },
          ),
        ),
      );
}
