import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:matrix/matrix.dart';

import '../../core/app_config.dart';
import '../../core/business_api_client.dart';
import '../contacts/contact_models.dart';
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
import 'profile_repository.dart';
import 'conversation_preferences.dart';
import 'conversation_read_state.dart';
import 'conversation_presentation.dart';
import '../search/global_search_page.dart';
import 'room_page.dart';
import 'matrix_emoji_vault.dart';
import 'matrix_control_rooms.dart';
import 'matrix_message_reminder_backend.dart';
import 'message_reminder_service.dart';
import '../statistics/statistics_state_store.dart';
import 'nudge_service.dart';
import 'group_invitation_auto_join.dart';

List<User> orderedJoinedMembers(Room room) {
  final joined = room.getParticipants([Membership.join]);
  final byId = {for (final member in joined) member.id: member};
  final order = reconcileMemberOrder(
    preferenceForRoom(room).memberOrderIds,
    joined.map((member) => member.id),
  );
  return [
    for (final id in order)
      if (byId[id] != null) byId[id]!
  ];
}

String directRoomNavigationTitle({
  required String? peerMatrixUserId,
  required Map<String, ContactDetails> contactsByMatrixId,
  required String fallbackRoomName,
}) {
  final contact = contactsByMatrixId[peerMatrixUserId];
  if (contact == null) return fallbackRoomName;
  return directConversationTitle(ConversationIdentity(
    matrixUserId: contact.matrixUserId,
    remark: contact.remark,
    nickname: contact.nickname,
    username: contact.username,
  ));
}

Future<List<User>> loadOrderedJoinedMembers(Room room) async {
  await room.requestParticipants([Membership.join]);
  return orderedJoinedMembers(room);
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
  @override
  State<MatrixHomePage> createState() => _MatrixHomePageState();
}

class _MatrixHomePageState extends State<MatrixHomePage> {
  bool syncing = false;
  StreamSubscription<Object?>? syncSubscription;
  Timer? _presenceTimer;
  bool _openingRoom = false;
  final ConversationReadState _readState = ConversationReadState.shared();
  final Map<String, List<User>> _groupMembersByRoom = {};
  final Set<String> _groupMemberLoadsInFlight = {};

  /// BUG1（被邀端）：auto_allow_group_join 设置（null=未知，按开处理并
  /// 惰性校正）；实时 onSync 收到新群邀请时按设置分流。
  bool? _autoAllowGroupJoin;
  final Set<String> _autoJoinInFlight = {};
  late final ProfileRepository _identityCache =
      widget.identityCache ?? ProfileRepository(widget.api);

  Future<void> _loadAutoAllowPreference() async {
    if (_autoAllowGroupJoin != null) return;
    try {
      _autoAllowGroupJoin = await widget.api.autoAllowGroupJoin();
    } catch (_) {
      _autoAllowGroupJoin = true; // 查询失败按默认开处理（与历史行为一致）。
    }
    if (mounted) setState(() {});
  }

  /// BUG1（被邀端）：按设置分流处理待处理群邀请。
  /// 开启自动入群 → 立即 join（实时/冷启动/断网恢复一致）；
  /// 关闭 → 保留为待处理邀请（会话列表顶部可接受/拒绝，不自动加入）。
  Future<void> _processPendingGroupInvites() async {
    await _loadAutoAllowPreference();
    if (_autoAllowGroupJoin != true) return;
    final client = widget.matrix.sdkClient;
    final pending = client.rooms
        .where((room) =>
            room.membership == Membership.invite &&
            !room.isDirectChat &&
            !_autoJoinInFlight.contains(room.id))
        .map((room) => room.id)
        .toList(growable: false);
    if (pending.isEmpty) return;
    _autoJoinInFlight.addAll(pending);
    try {
      final result = await autoJoinInvitedRoomIds(
        invitedRoomIds: pending,
        joinRoom: client.joinRoom,
      );
      _autoJoinInFlight.removeAll(pending);
      if (result.joinedRoomIds.isNotEmpty) {
        await client.oneShotSync();
      }
      if (mounted) setState(() {});
    } catch (_) {
      _autoJoinInFlight.removeAll(pending);
      // 下一次 sync 重试。
    }
  }

  /// 待处理群邀请（设置关闭自动入群时展示接受/拒绝入口）。
  List<Room> get _pendingInviteRooms => _autoAllowGroupJoin == false
      ? widget.matrix.sdkClient.rooms
          .where((room) =>
              room.membership == Membership.invite && !room.isDirectChat)
          .toList(growable: false)
      : const <Room>[];

  Future<void> _acceptGroupInvite(Room room) async {
    try {
      await widget.matrix.sdkClient.joinRoom(room.id);
      await widget.matrix.sdkClient.oneShotSync();
    } catch (_) {
      if (mounted) {
        showCupertinoDialog<void>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: const Text('加入失败'),
            content: const Text('请稍后重试。'),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('好的'),
              ),
            ],
          ),
        );
      }
      return;
    }
    if (mounted) setState(() {});
  }

  Future<void> _declineGroupInvite(Room room) async {
    try {
      await room.leave();
    } catch (_) {
      // 拒绝失败保留邀请；下次可再拒绝。
    }
    if (mounted) setState(() {});
  }

  Future<void> sync() async {
    if (syncing) return;
    setState(() => syncing = true);
    try {
      await widget.matrix.sync();
      _ensureGroupMembersLoaded(widget.matrix.sdkClient.rooms);
      await _reconcileConversationMetadata();
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  void _ensureGroupMembersLoaded(Iterable<Room> rooms) {
    for (final room in rooms.where((room) => !room.isDirectChat)) {
      if (_groupMemberLoadsInFlight.contains(room.id)) continue;
      _groupMemberLoadsInFlight.add(room.id);
      unawaited(() async {
        try {
          final members = await loadOrderedJoinedMembers(room);
          if (mounted) setState(() => _groupMembersByRoom[room.id] = members);
        } catch (_) {
          // Preserve currently known members; the next sync retries loading.
        } finally {
          _groupMemberLoadsInFlight.remove(room.id);
        }
      }());
    }
  }

  Future<void> _reconcileConversationMetadata() async {
    final base = DateTime.now().toUtc();
    var offset = 0;
    for (final room in widget.matrix.sdkClient.rooms) {
      final preference = preferenceForRoom(room);
      final memberOrder = room.isDirectChat
          ? preference.memberOrderIds
          : reconcileMemberOrder(
              preference.memberOrderIds,
              room.getParticipants([Membership.join]).map(
                  (member) => member.id),
            );
      final needsPinTime = preference.pinned && preference.pinnedAt == null;
      final orderChanged = memberOrder.join('\u0000') !=
          preference.memberOrderIds.join('\u0000');
      if (!needsPinTime && !orderChanged) continue;
      try {
        await writeConversationPreference(
          room,
          preference.copyWith(
            pinnedAt: needsPinTime
                ? base.add(Duration(microseconds: offset++))
                : preference.pinnedAt,
            memberOrderIds: memberOrder,
          ),
        );
      } catch (_) {
        // Matrix sync will retry reconciliation without losing local state.
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _identityCache.addListener(_identityChanged);
    syncSubscription = widget.matrix.sdkClient.onSync.stream.listen((_) {
      unawaited(_restoreHiddenConversations());
      unawaited(_processPendingGroupInvites());
      if (mounted) setState(() {});
    });
    unawaited(_loadAutoAllowPreference());
    unawaited(_processPendingGroupInvites());
    unawaited(_identityCache.preload().catchError((_) {}));
    _sendPresenceHeartbeat();
    _presenceTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _sendPresenceHeartbeat();
    });
    sync();
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
    final currentUserId = widget.matrix.sdkClient.userID;
    for (final room in widget.matrix.sdkClient.rooms) {
      final preference = preferenceForRoom(room);
      final event = room.lastEvent;
      if (!preference.hidden || event == null) continue;
      final restored = restoreForIncomingEvent(
        preference,
        eventAt: event.originServerTs,
        isIncoming: event.senderId != currentUserId,
      );
      if (!restored.hidden) {
        await writeConversationPreference(room, restored);
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _identityCache.removeListener(_identityChanged);
    syncSubscription?.cancel();
    _presenceTimer?.cancel();
    super.dispose();
  }

  void _identityChanged() {
    if (mounted) setState(() {});
  }

  String _roomTime(Room room) {
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

  ConversationIdentity _memberIdentity(User member) {
    // 会话标题/摘要按用户要求备注优先（备注仅查看者本人可见，无泄露面）。
    final own = member.id == widget.matrix.sdkClient.userID;
    final contact = _identityCache.contactsByMatrixId[member.id];
    final profile = own ? _identityCache.profile : null;
    return ConversationIdentity(
      matrixUserId: member.id,
      remark: contact?.remark,
      nickname: profile?.nickname ?? contact?.nickname,
      username: profile?.username ?? contact?.username,
      matrixDisplayName: member.calcDisplayname(),
    );
  }

  String _conversationTitle(Room room) {
    if (room.isDirectChat) {
      final peerId = room.directChatMatrixID!;
      final peer = room.unsafeGetUserFromMemoryOrFallback(peerId);
      return directConversationTitle(_memberIdentity(peer));
    }
    // 群聊名称（m.room.name）优先于成员清单拼接；成员顺序保持加入顺序。
    final members = _groupMembersByRoom[room.id] ?? orderedJoinedMembers(room);
    final title = groupConversationTitle(
      members.map(_memberIdentity).toList(growable: false),
      groupName: room.name,
    );
    return title.isEmpty ? '未命名' : title;
  }

  int _conversationUnread(Room room) {
    final preference = preferenceForRoom(room);
    return _readState.unreadCount(
      roomId: room.id,
      serverUnreadCount: room.notificationCount,
      lastEventId: room.lastEvent?.eventId,
      lastEventSenderId: room.lastEvent?.senderId,
      currentUserId: widget.matrix.sdkClient.userID,
      manualUnread: preference.manualUnread,
    );
  }

  String _conversationSubtitle(Room room) {
    final event = room.lastEvent;
    if (event == null) return '端到端加密消息';
    // 媒体/通话类消息摘要用固定标签（[图片]/[语音]/[视频]/[语音通话]/[视频通话]）。
    final mediaSummary = conversationEventSummaryLabel(
      messageType: event.messageType,
      content: event.content,
      eventType: event.type,
    );
    final messageContent = mediaSummary ??
        safeConversationMessageContent(
          undecrypted: event.type == EventTypes.Encrypted,
          messageContent: event.text,
        );
    if (room.isDirectChat) return messageContent;
    final sender = conversationSenderName(
      _memberIdentity(event.senderFromMemoryOrFallback),
    );
    final isSenderMessage = event.type == EventTypes.Message ||
        event.type == EventTypes.Encrypted ||
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

  /// BUG2：扫码入群成功后按 roomId 打开会话（等待首次同步带回房间）。
  Future<void> _openRoomById(String roomId) async {
    if (roomId.isEmpty) return;
    var room = widget.matrix.sdkClient.getRoomById(roomId);
    if (room == null || room.membership != Membership.join) {
      try {
        await widget.matrix.sdkClient
            .waitForRoomInSync(roomId)
            .timeout(const Duration(seconds: 10));
        room = widget.matrix.sdkClient.getRoomById(roomId);
      } catch (_) {
        // 下次同步后用户可从会话列表进入。
      }
    }
    final joined = room;
    if (joined != null && joined.membership == Membership.join && mounted) {
      await _openRoom(joined);
    }
  }

  /// 聊天页后台预热（身份快照 + 头像解码；失败不影响已打开的会话）。
  Future<void> _warmChatIdentity() async {
    try {
      await _identityCache.preload();
      if (!mounted) return;
      if (!mounted) return;
      await _identityCache.precacheAvatarImages(context);
    } catch (_) {
      // 保留上一次成功快照；页面内自身会重试资料刷新。
    }
  }

  Future<void> _openRoom(Room room) async {
    if (_openingRoom) return;
    // Navigator 先行捕获：后续任何 await 之后都不再触碰 context。
    final navigator = Navigator.of(context, rootNavigator: true);
    _openingRoom = true;
    try {
      final preference = preferenceForRoom(room);
      _readState.setRoomOpen(room.id, open: true);
      _readState.markCleared(room.id, eventId: room.lastEvent?.eventId);
      if (preference.manualUnread) {
        try {
          await writeConversationPreference(
            room,
            clearUnreadOnOpen(preference),
          );
        } catch (_) {
          // A failed account-data write is retried by the next sync.
        }
      }

      // 规格§七（P0）：打开聊天页绝不等待身份预载/头像预解码——
      // 先用本地已有数据渲染，资料与头像在后台补齐（原实现在此处
      // 串行 await preload + precache，正是"点开聊天等 5 秒"的根因）。
      unawaited(_warmChatIdentity());
      final roomName = room.isDirectChat
          ? _conversationTitle(room)
          : groupRoomNavigationTitle(
              room.name,
              orderedJoinedMembers(room).length,
            );
      await navigator.push(
        CupertinoPageRoute(
          builder: (_) => RoomPage(
            api: widget.api,
            room: room,
            roomName: roomName,
            onCreateGroup: widget.onCreateGroup,
            onMessage: widget.onMessage,
            onVoice: widget.onVoice,
            onVideo: widget.onVideo,
            reminderService: widget.reminderService,
            initialIdentityCache: _identityCache,
          ),
        ),
      );
    } finally {
      // 退出聊天页：解除"查看中"，并把清零位点推进到最后一条已知事件，
      // 抑制服务器计数同步滞后造成的自己消息红点回显。
      _readState.setRoomOpen(room.id, open: false);
      _readState.markCleared(room.id, eventId: room.lastEvent?.eventId);
      _openingRoom = false;
    }
  }

  Future<void> _conversationActions(Room room) async {
    final preference = preferenceForRoom(room);
    final action = await showConversationActionSheet(
      context,
      pinned: preference.pinned,
      onAction: (_) {},
    );
    if (!mounted || action == null) return;
    switch (action) {
      case ConversationAction.markUnread:
        await writeConversationPreference(room, markUnread(preference));
      case ConversationAction.togglePin:
        final next = preference.pinned
            ? preference.copyWith(pinned: false, clearPinnedAt: true)
            : preference.copyWith(
                pinned: true,
                pinnedAt: DateTime.now().toUtc(),
              );
        await writeConversationPreference(room, next);
      case ConversationAction.hide:
        await writeConversationPreference(
          room,
          hideConversation(preference, DateTime.now().toUtc()),
        );
      case ConversationAction.delete:
        final confirmed = await showCupertinoDialog<bool>(
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
        );
        if (confirmed == true) {
          await room.leave();
          await room.forget();
          // 删除会话时清理该会话的统计工具缓存
          await StatisticsStateStore.clear(room.id);
        }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final vaultRoomId = widget.matrix.sdkClient
        .accountData[emojiVaultAccountDataType]?.content['room_id']
        ?.toString();
    final reminderRoomId = widget.matrix.sdkClient
        .accountData[messageReminderAccountDataType]?.content['room_id']
        ?.toString();
    final visibleRooms = widget.matrix.sdkClient.rooms
        .where(
          (room) =>
              // 会话最后一条消息尚未解密（如密钥尚未同步）时隐藏整个
              // 会话；密钥就绪后消息可解密，会话自动重新出现（不删数据）。
              room.lastEvent?.type != EventTypes.Encrypted &&
              !isMatrixControlRoom(
                roomId: room.id,
                displayName: room.getLocalizedDisplayname(),
                vaultRoomId: vaultRoomId,
                reminderRoomId: reminderRoomId,
              ),
        )
        .toList(growable: false);
    final roomById = {for (final room in visibleRooms) room.id: room};
    final ordered = orderConversations([
      for (final room in visibleRooms)
        ConversationProjection(
          roomId: room.id,
          isGroup: !room.isDirectChat,
          lastActivity: room.lastEvent?.originServerTs ??
              DateTime.fromMillisecondsSinceEpoch(0),
          preference: preferenceForRoom(room),
        ),
    ]);
    final orderedRooms = [for (final item in ordered) roomById[item.roomId]!];
    final activeRooms = orderedRooms
        .where((room) => !preferenceForRoom(room).hidden)
        .toList(growable: false);
    final foldedRooms = activeRooms.where((room) {
      final value = preferenceForRoom(room);
      return !room.isDirectChat && value.muted && value.folded;
    }).toList(growable: false);
    final rooms = activeRooms
        .where((room) => !foldedRooms.contains(room))
        .toList(growable: false);
    final pinnedCount =
        rooms.where((room) => preferenceForRoom(room).pinned).length;
    return WeChatPageScaffold.navigation(
      backgroundColor: WeChatColors.tabRootPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.chatNavigationBackground,
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
                  separatorBuilder: (_, __) => const Padding(
                    padding: EdgeInsets.only(
                      left: WeChatSpacing.lg +
                          WeChatDimensions.conversationAvatar +
                          WeChatSpacing.md,
                    ),
                    child: SizedBox(
                      height: 0.5,
                      child: ColoredBox(color: WeChatColors.divider),
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
                        avatar: const ColoredBox(
                          color: WeChatColors.lightSurface,
                          child: Icon(CupertinoIcons.tray_full, size: 25),
                        ),
                        onTap: () => Navigator.push<void>(
                          context,
                          CupertinoPageRoute(
                            builder: (_) => _FoldedGroupChatsPage(
                              rooms: foldedRooms,
                              titleFor: _conversationTitle,
                              subtitleFor: _conversationSubtitle,
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
                    _ensureGroupMembersLoaded([room]);
                    final roomName = _conversationTitle(room);
                    final preference = preferenceForRoom(room);
                    return ConversationListTile(
                      key: ValueKey<String>('conversation-${room.id}'),
                      title: roomName,
                      subtitle: _conversationSubtitle(room),
                      timeLabel: _roomTime(room),
                      avatar: room.isDirectChat || room.avatar != null
                          ? MatrixUserAvatar(
                              client: widget.matrix.sdkClient,
                              nickname: roomName,
                              fallbackSeed: room.id,
                              matrixAvatarUri: room.avatar,
                              size: WeChatDimensions.conversationAvatar,
                            )
                          : GroupAvatarMosaic(
                              avatars: [
                                for (final member
                                    in (_groupMembersByRoom[room.id] ??
                                            orderedJoinedMembers(room))
                                        .take(9))
                                  MatrixUserAvatar(
                                    client: widget.matrix.sdkClient,
                                    nickname: member.calcDisplayname(),
                                    fallbackSeed: member.id,
                                    matrixAvatarUri: member.avatarUrl,
                                  ),
                              ],
                            ),
                      unreadCount: _conversationUnread(room),
                      muted: preference.muted ||
                          room.pushRuleState != PushRuleState.notify,
                      pinnedGroup: !room.isDirectChat && preference.pinned,
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
                  color: CupertinoColors.systemBackground,
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
    required this.onOpen,
    required this.titleFor,
    required this.subtitleFor,
  });
  final List<Room> rooms;
  final ValueChanged<Room> onOpen;
  final String Function(Room room) titleFor;
  final String Function(Room room) subtitleFor;

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
              final members = orderedJoinedMembers(room).take(9);
              return ConversationListTile(
                title: titleFor(room),
                subtitle: subtitleFor(room),
                timeLabel: '',
                muted: true,
                avatar: room.avatar != null
                    ? MatrixUserAvatar(
                        client: room.client,
                        nickname: room.getLocalizedDisplayname(),
                        fallbackSeed: room.id,
                        matrixAvatarUri: room.avatar,
                      )
                    : GroupAvatarMosaic(
                        avatars: [
                          for (final member in members)
                            MatrixUserAvatar(
                              client: room.client,
                              nickname: member.calcDisplayname(),
                              fallbackSeed: member.id,
                              matrixAvatarUri: member.avatarUrl,
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
