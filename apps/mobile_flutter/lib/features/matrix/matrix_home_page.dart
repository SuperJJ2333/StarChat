import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/business_api_client.dart';
import '../../core/local_notification_scheduler.dart';
import '../contacts/contact_models.dart';
import '../contacts/contacts_page.dart';
import '../profile/profile_controller.dart';
import '../redpacket/red_packet_detail_sheet.dart';
import '../../ui/chat/chat_composer_bar.dart';
import '../../ui/chat/chat_composer_state.dart';
import '../../ui/chat/chat_emoji_panel.dart';
import '../../ui/chat/chat_more_panel.dart';
import '../../ui/chat/group_avatar_mosaic.dart';
import '../../ui/chat/message_action.dart';
import '../../ui/chat/message_action_sheet.dart';
import '../../ui/chat/wechat_attachment_tile.dart';
import '../../ui/chat/wechat_message_bubble.dart';
import '../../ui/chat/wechat_nudge_notice.dart';
import '../../ui/chat/wechat_voice_bubble.dart';
import '../../ui/components/conversation_list_tile.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/chat/conversation_action_sheet.dart';
import '../../ui/finance/wechat_red_packet_card.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../../ui/theme/theme_controller.dart';
import '../../ui/theme/theme_picker_sheet.dart';
import 'matrix_e2ee_client.dart';
import 'matrix_user_avatar.dart';
import 'chat_identity_cache.dart';
import 'matrix_room_timeline_adapter.dart';
import 'chat_red_packet_adapters.dart';
import 'chat_red_packet_controller.dart';
import 'chat_red_packet_sheet.dart';
import 'group_chat_info_controller.dart';
import 'group_chat_info_page.dart';
import 'conversation_preferences.dart';
import 'conversation_presentation.dart';
import 'direct_chat_info_page.dart';
import 'chat_history_search.dart';
import '../search/global_search_page.dart';
import 'matrix_emoji_vault.dart';
import 'matrix_control_rooms.dart';
import 'matrix_message_reminder_backend.dart';
import 'media_message_service.dart';
import 'message_reminder_service.dart';
import 'message_interaction_service.dart';
import 'nudge_service.dart';
import 'local_hidden_events.dart';
import 'room_timeline_controller.dart';
import 'voice_composer.dart';

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

String groupRoomNavigationTitle(String customName, int memberCount) {
  final normalizedName = customName.trim();
  if (normalizedName.isEmpty) return '群聊($memberCount)';

  final characters = normalizedName.characters;
  final suffix = '($memberCount)';
  // The navigation bar has room for at most 20 grapheme clusters including
  // the count. Keep the mandated 8…3 form whenever the full label overflows.
  final needsMiddleEllipsis = characters.length > 20 ||
      characters.length + suffix.characters.length > 20;
  final label = needsMiddleEllipsis
      ? '${characters.take(8).toString()}...'
          '${characters.skip(characters.length - 3).toString()}'
      : normalizedName;
  return '$label$suffix';
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
    this.onVoice,
    this.onVideo,
    this.identityCache,
  });
  final BusinessApiClient api;
  final MatrixSdkE2eeClient matrix;
  final ThemeController themeController;
  final VoidCallback onCreateGroup;
  final MessageReminderService? reminderService;
  final ContactAction? onVoice;
  final ContactAction? onVideo;
  final ChatIdentityCache? identityCache;
  @override
  State<MatrixHomePage> createState() => _MatrixHomePageState();
}

class _MatrixHomePageState extends State<MatrixHomePage> {
  bool syncing = false;
  StreamSubscription<Object?>? syncSubscription;
  final Map<String, List<User>> _groupMembersByRoom = {};
  final Set<String> _groupMemberLoadsInFlight = {};
  late final ChatIdentityCache _identityCache =
      widget.identityCache ?? ChatIdentityCache(widget.api);

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
      if (mounted) setState(() {});
    });
    unawaited(_identityCache.preload());
    sync();
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
    final members = _groupMembersByRoom[room.id] ?? orderedJoinedMembers(room);
    final title = groupConversationTitle(
      members.map(_memberIdentity).toList(growable: false),
    );
    return title.isEmpty ? '未命名' : title;
  }

  int _conversationUnread(Room room) {
    final preference = preferenceForRoom(room);
    return preference.manualUnread ? 1 : room.notificationCount;
  }

  String _conversationSubtitle(Room room) {
    final event = room.lastEvent;
    if (event == null) return '端到端加密消息';
    if (room.isDirectChat) return event.text;
    final sender = conversationSenderName(
      _memberIdentity(event.senderFromMemoryOrFallback),
    );
    final isSenderMessage = event.type == EventTypes.Message ||
        event.type == EventTypes.Encrypted ||
        event.type == changliaoNudgeEventType;
    return groupConversationSubtitle(
      unreadCount: _conversationUnread(room),
      senderName: sender,
      messageContent: event.text,
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
          _action(sheetContext, CupertinoIcons.qrcode_viewfinder, '扫一扫'),
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

  Future<void> _openRoom(Room room) async {
    final preference = preferenceForRoom(room);
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
    await _identityCache.preload();
    if (!mounted) return;
    await _identityCache.precacheAvatarImages(context);
    if (!mounted) return;
    final roomName = room.isDirectChat
        ? room.getLocalizedDisplayname()
        : groupRoomNavigationTitle(
            room.name,
            orderedJoinedMembers(room).length,
          );
    Navigator.of(context, rootNavigator: true).push(
      CupertinoPageRoute(
        builder: (_) => RoomPage(
          api: widget.api,
          room: room,
          roomName: roomName,
          onCreateGroup: widget.onCreateGroup,
          onVoice: widget.onVoice,
          onVideo: widget.onVideo,
          reminderService: widget.reminderService,
          initialIdentityCache: _identityCache,
        ),
      ),
    );
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
          (room) => !isMatrixControlRoom(
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
        middle: const Text('消息'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          CupertinoButton(
            key: const Key('messages-search'),
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.push(
                context,
                CupertinoPageRoute(
                    builder: (_) => GlobalSearchPage(
                          api: widget.api,
                          rooms: visibleRooms
                              .map((room) => room.getLocalizedDisplayname())
                              .toList(),
                          messages: [
                            for (final room in visibleRooms)
                              room.lastEvent?.body ?? ''
                          ],
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
        child: rooms.isEmpty && foldedRooms.isEmpty
            ? const _MessagesEmptyState()
            : ListView.separated(
                padding: EdgeInsets.zero,
                itemCount: rooms.length + (foldedRooms.isEmpty ? 0 : 1),
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
                  if (foldedRooms.isNotEmpty && index == pinnedCount) {
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
                  final roomIndex =
                      foldedRooms.isNotEmpty && index > pinnedCount
                          ? index - 1
                          : index;
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
              ),
      ),
    );
  }
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
            backgroundColor: WeChatColors.chatNavigationBackground,
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

class RoomPage extends StatefulWidget {
  const RoomPage({
    super.key,
    required this.api,
    required this.roomName,
    required this.room,
    this.initialContact,
    required this.onCreateGroup,
    this.reminderService,
    this.onVoice,
    this.onVideo,
    this.initialIdentityCache,
  });

  final BusinessApiClient api;
  final String roomName;
  final Room room;
  final ContactDetails? initialContact;
  final VoidCallback onCreateGroup;
  final MessageReminderService? reminderService;
  final ContactAction? onVoice;
  final ContactAction? onVideo;
  final ChatIdentityCache? initialIdentityCache;

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  final input = TextEditingController();
  final messageScrollController = ScrollController();
  final messageKeys = <String, GlobalKey>{};
  final recalledDrafts = <String, String>{};
  final selection = MessageSelectionController();
  RoomTimelineController? controller;
  Timeline? roomTimeline;
  LocalHiddenEvents? hiddenEvents;
  final mentionDraft = MentionDraft();
  RoomMessageViewModel? replyingTo;
  MatrixEmojiVault? emojiVault;
  List<CustomEmojiItem> customEmojiItems = const [];
  MessageReminderService? reminderService;
  String nudgeSuffix = '';
  Map<String, ContactDetails> contactsByMatrixId = const {};
  ProfileData? ownProfile;
  late final ChatIdentityCache _identityCache =
      widget.initialIdentityCache ?? ChatIdentityCache(widget.api);
  ContactDetails? peer;
  bool loading = true;
  bool mediaBusy = false;
  ComposerPanel composerPanel = ComposerPanel.none;
  String? errorMessage;
  String? mediaMessage;
  Timer? mediaMessageTimer;
  bool mediaMessageVisible = false;
  late int joinedMemberCount;
  int? readAnnouncementVersion;
  String? highlightedMessageId;

  bool get isGroup => !widget.room.isDirectChat;

  @override
  void initState() {
    super.initState();
    peer = widget.initialContact;
    joinedMemberCount = orderedJoinedMembers(widget.room).length;
    ownProfile = _identityCache.profile;
    contactsByMatrixId = _identityCache.contactsByMatrixId;
    unawaited(_identityCache.preload());
    unawaited(_refreshJoinedMemberCount());
    unawaited(_loadAnnouncementReadState());
    _load();
  }

  Future<void> _refreshJoinedMemberCount() async {
    if (!isGroup) return;
    try {
      await widget.room.requestParticipants([Membership.join]);
      final count = orderedJoinedMembers(widget.room).length;
      if (mounted) setState(() => joinedMemberCount = count);
    } catch (_) {
      // Preserve the synchronized local count if a transient member request
      // fails; the next room sync refreshes the title.
    }
  }

  String get _navigationTitle => isGroup
      ? groupRoomNavigationTitle(widget.room.name, joinedMemberCount)
      : widget.roomName;

  int get _announcementVersion =>
      widget.room.roomAccountData[groupChatAccountDataType]
          ?.content['announcement_version'] as int? ??
      0;

  String get _announcement => isGroup ? widget.room.topic.trim() : '';

  bool get _showAnnouncement =>
      _announcement.isNotEmpty &&
      _announcementVersion > readAnnouncementVersion!;

  Future<void> _loadAnnouncementReadState() async {
    final preferences = await SharedPreferences.getInstance();
    final version =
        preferences.getInt('announcement-read:${widget.room.id}') ?? 0;
    if (mounted) setState(() => readAnnouncementVersion = version);
  }

  Future<void> _openAnnouncement() async {
    final version = _announcementVersion;
    await Navigator.push<void>(
      context,
      CupertinoPageRoute(
        builder: (_) => GroupAnnouncementPage(
          title: _navigationTitle,
          announcement: _announcement,
        ),
      ),
    );
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt('announcement-read:${widget.room.id}', version);
    if (mounted) setState(() => readAnnouncementVersion = version);
  }

  Future<void> _load() async {
    try {
      final accountId = widget.room.client.userID;
      if (accountId == null) throw StateError('Matrix 账号尚未登录');
      hiddenEvents = SharedPreferencesLocalHiddenEvents(
        preferences: await SharedPreferences.getInstance(),
        accountId: accountId,
      );
      final timeline =
          await widget.room.getTimeline(onUpdate: () => controller?.refresh());
      if (!mounted) {
        timeline.cancelSubscriptions();
        return;
      }
      controller = RoomTimelineController(
        MatrixRoomTimelineAdapter(widget.room, timeline),
      )..addListener(_changed);
      roomTimeline = timeline;
      setState(() => loading = false);
      await controller!.markRead();
      await _loadEmojiVault();
      await _loadReminderService();
      await _loadIdentities();
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          errorMessage = '会话加载失败，请检查网络后重试';
        });
      }
    }
  }

  Future<void> _loadIdentities() async {
    try {
      await _identityCache.preload();
      final contacts = _identityCache.contacts;
      final profile = _identityCache.profile;
      final mapped = _identityCache.contactsByMatrixId;
      final participantIds = widget.room
          .getParticipants()
          .map((participant) => participant.id)
          .where((id) => id != widget.room.client.userID)
          .toSet();
      ContactDetails? resolvedPeer;
      for (final contact in contacts) {
        if (participantIds.contains(contact.matrixUserId)) {
          resolvedPeer = contact.toDetails();
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        contactsByMatrixId = mapped;
        ownProfile = profile ?? ownProfile;
        peer ??= resolvedPeer;
      });
    } catch (_) {
      // The encrypted timeline remains usable when optional profile metadata
      // is temporarily unavailable. Avatar and name fallbacks stay local.
    }
  }

  Future<void> _loadEmojiVault() async {
    try {
      final session = await MatrixEmojiVault.open(
        MatrixSdkEmojiVaultBackend(widget.room.client),
      );
      final items = <CustomEmojiItem>[];
      for (final item in session.vault.items) {
        items.add(
          CustomEmojiItem(
            id: item.id,
            bytes: await session.loadBytes(item),
            isAnimated: item.isAnimated,
            mimeType: item.mimeType,
          ),
        );
      }
      if (!mounted) return;
      setState(() {
        emojiVault = session;
        customEmojiItems = items;
      });
    } catch (_) {
      if (mounted) setState(() => mediaMessage = '我的表情同步失败，可稍后重试');
    }
  }

  Future<void> _loadReminderService() async {
    try {
      final provided = widget.reminderService;
      final MessageReminderService service;
      if (provided != null) {
        service = provided;
      } else {
        final backend =
            await MatrixMessageReminderBackend.open(widget.room.client);
        service = MessageReminderService(
          backend: backend,
          scheduler: FlutterLocalNotificationScheduler(),
        );
        await service.applyIncoming(await backend.load());
      }
      reminderService = service;
    } catch (_) {
      // Chat remains available; choosing reminder will surface a retry state.
    }
  }

  Future<void> _addMessageToEmoji(RoomMessageViewModel message) async {
    final session = emojiVault;
    final timeline = controller;
    if (session == null || timeline == null) {
      setState(() => mediaMessage = '表情仓库尚未就绪');
      return;
    }
    try {
      final bytes = await timeline.loadAttachment(message.id);
      final item = await session.vault.add(
        bytes,
        mimeType: message.mimeType ?? 'image/png',
      );
      final custom = CustomEmojiItem(
        id: item.id,
        bytes: bytes,
        isAnimated: item.isAnimated,
        mimeType: item.mimeType,
      );
      if (!mounted) return;
      setState(() {
        customEmojiItems = [
          custom,
          ...customEmojiItems.where((existing) => existing.id != item.id),
        ];
        mediaMessage = '已添加到我的表情';
      });
    } catch (_) {
      if (mounted) setState(() => mediaMessage = '添加表情失败，请重试');
    }
  }

  Future<void> _sendCustomEmoji(CustomEmojiItem item) async {
    try {
      await widget.room.sendFileEvent(
        MatrixFile.fromMimeType(
          bytes: item.bytes,
          name: item.isAnimated ? '畅聊表情.gif' : '畅聊表情.png',
          mimeType: item.mimeType,
        ),
      );
      await emojiVault?.vault.markRecent(item.id);
      if (mounted) setState(() => composerPanel = ComposerPanel.none);
    } catch (_) {
      if (mounted) setState(() => mediaMessage = '表情发送失败，请重试');
    }
  }

  Future<void> _sendNudge(
    RoomMessageViewModel message,
    String targetDisplayName,
  ) async {
    final sender = ownProfile;
    final senderId = widget.room.client.userID;
    if (sender == null || senderId == null) return;
    try {
      // The profile service is authoritative for a sender's nudge suffix.
      // Refresh it at send time so a just-saved profile setting is used by
      // already-open conversations as well.
      final latestProfile = await widget.api.loadProfile();
      if (mounted) {
        setState(() {
          ownProfile = latestProfile;
          nudgeSuffix = latestProfile.nudgeSuffix ?? '';
        });
      }
      await NudgeService(
        backend: MatrixNudgeBackend(widget.room.client),
        roomId: widget.room.id,
        senderId: senderId,
        senderDisplayName: sender.nickname,
      ).send(
        targetUserId: message.senderId,
        targetDisplayName: targetDisplayName,
        suffix: message.senderId == senderId
            ? (latestProfile.nudgeSuffix ?? '')
            : (contactsByMatrixId[message.senderId]?.nudgeSuffix ?? ''),
      );
    } catch (_) {
      if (mounted) setState(() => mediaMessage = '拍一拍发送失败，请重试');
    }
  }

  Future<void> _showReminderPicker(RoomMessageViewModel message) async {
    final service = reminderService;
    if (service == null) {
      setState(() => mediaMessage = '提醒同步尚未就绪，请稍后重试');
      return;
    }
    var selected = DateTime.now().add(const Duration(hours: 1));
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => Container(
        height: 360,
        color: CupertinoTheme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              SizedBox(
                height: 52,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CupertinoButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Text('取消'),
                    ),
                    const Text(
                      '选择提醒时间',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    CupertinoButton(
                      key: const Key('reminder-confirm'),
                      onPressed: () async {
                        try {
                          await service.create(
                            roomId: widget.room.id,
                            eventId: message.id,
                            dueAt: selected,
                          );
                          if (!sheetContext.mounted) return;
                          Navigator.pop(sheetContext);
                          if (mounted) setState(() => mediaMessage = '提醒已设置');
                        } catch (_) {
                          if (mounted) {
                            setState(() => mediaMessage = '提醒设置失败，请重试');
                          }
                        }
                      },
                      child: const Text('完成'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.dateAndTime,
                  initialDateTime: selected,
                  minimumDate: DateTime.now(),
                  use24hFormat: true,
                  onDateTimeChanged: (value) => selected = value,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _send() async {
    final text = input.text.trim();
    if (text.isEmpty || controller == null) return;
    input.clear();
    final interaction = _interaction;
    final reply = replyingTo;
    final mentions = mentionDraft.activeUserIds(text);
    if (interaction != null && reply != null) {
      await interaction.reply(
        reply.id,
        text,
        mentionedUserIds: mentions,
      );
      setState(() => replyingTo = null);
    } else if (interaction != null && mentions.isNotEmpty) {
      await interaction.sendMention(text, mentions);
    } else {
      await controller!.sendText(text);
    }
    mentionDraft.clear();
  }

  MessageInteractionService? get _interaction {
    final timeline = roomTimeline;
    final userId = widget.room.client.userID;
    if (timeline == null || userId == null) return null;
    return MessageInteractionService(
      backend: MatrixMessageInteractionBackend(
        client: widget.room.client,
        timeline: timeline,
      ),
      roomId: widget.room.id,
      currentUserId: userId,
    );
  }

  Future<DateTime?> _serverNow() async {
    final homeserver = widget.room.client.homeserver;
    if (homeserver == null) return null;
    try {
      return await MatrixServerClock(
        homeserver: homeserver,
        httpClient: widget.room.client.httpClient,
      ).now();
    } catch (_) {
      return null;
    }
  }

  Future<void> _sendMedia({required bool image}) async {
    if (mediaBusy) return;
    final service = MediaMessageService(
      MatrixSdkE2eeClient(
        widget.room.client,
        homeserver: widget.room.client.homeserver!,
      ),
    );
    setState(() {
      mediaBusy = true;
      mediaMessage = image ? '正在加密发送图片…' : '正在加密发送文件…';
    });
    try {
      if (image) {
        await service.sendImage(widget.room.id);
      } else {
        await service.sendFile(widget.room.id);
      }
      if (mounted) _showMediaMessage(image ? '图片已发送' : '文件已发送');
    } catch (_) {
      if (mounted) {
        setState(() => mediaMessage = image ? '图片发送失败，请重试' : '文件发送失败，请重试');
      }
    } finally {
      await service.dispose();
      if (mounted) setState(() => mediaBusy = false);
    }
  }

  void _showMediaMessage(String message) {
    mediaMessageTimer?.cancel();
    setState(() {
      mediaMessage = message;
      mediaMessageVisible = true;
    });
    mediaMessageTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => mediaMessageVisible = false);
      mediaMessageTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => mediaMessage = null);
      });
    });
  }

  void _dismissComposerExtensions() {
    FocusManager.instance.primaryFocus?.unfocus();
    if (composerPanel != ComposerPanel.none) {
      setState(() => composerPanel = ComposerPanel.none);
    }
  }

  void _togglePanel(ComposerPanel panel) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      composerPanel = composerPanel == panel ? ComposerPanel.none : panel;
    });
  }

  Future<void> _handleMoreAction(ChatMoreAction action) async {
    setState(() => composerPanel = ComposerPanel.none);
    switch (action) {
      case ChatMoreAction.image:
      case ChatMoreAction.camera:
        await _sendMedia(image: true);
      case ChatMoreAction.file:
        await _sendMedia(image: false);
      case ChatMoreAction.redPacket:
        await _showRedPacket();
      case ChatMoreAction.voiceCall:
        if (peer != null) await widget.onVoice?.call(peer!);
      case ChatMoreAction.videoCall:
        if (peer != null) await widget.onVideo?.call(peer!);
    }
  }

  Future<void> _showRedPacket() async {
    final timeline = controller;
    if (timeline == null) return;
    if (!isGroup && peer == null) {
      await _showError('好友资料尚未加载，暂时无法发送定向红包');
      return;
    }
    final redPacketController = ChatRedPacketController(
      business: BusinessChatRedPacketGateway(widget.api),
      references: TimelineRedPacketReferenceGateway(timeline),
      roomId: isGroup ? widget.room.id : null,
      recipientId: isGroup ? null : peer!.userId,
    );
    await Navigator.push<void>(
      context,
      CupertinoPageRoute(
        builder: (pageContext) => ChatRedPacketSheet(
          controller: redPacketController,
          isGroup: isGroup,
          onSent: () => Navigator.pop(pageContext),
        ),
      ),
    );
    redPacketController.dispose();
  }

  Future<void> _showVoice() async {
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (_) => CupertinoPopupSurface(
        child: SafeArea(
          child: VoiceComposer(
            service: MediaMessageService(
              MatrixSdkE2eeClient(
                widget.room.client,
                homeserver: widget.room.client.homeserver!,
              ),
            ),
            roomId: widget.room.id,
          ),
        ),
      ),
    );
  }

  void _insertEmoji(String selected) {
    final selection = input.selection;
    final start = selection.isValid ? selection.start : input.text.length;
    final end = selection.isValid ? selection.end : input.text.length;
    input.value = TextEditingValue(
      text: input.text.replaceRange(start, end, selected),
      selection: TextSelection.collapsed(offset: start + selected.length),
    );
  }

  Future<void> _showError(String message) => showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('操作失败'),
          content: Text(message),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      );

  Future<void> _openContact(ContactDetails contact) => Navigator.push(
        context,
        CupertinoPageRoute(
          builder: (_) => ContactProfilePage(
            api: widget.api,
            initialContact: contact,
            onVoice: widget.onVoice,
            onVideo: widget.onVideo,
            onContactUpdated: (updated) =>
                _identityCache.applyUpdatedContact(updated.toSummary()),
          ),
        ),
      );

  Future<void> _openConversationDetails() async {
    if (isGroup) {
      final infoController = GroupChatInfoController(
        MatrixGroupChatInfoGateway(widget.room),
      )..bindMembershipChanges(
          widget.room.client.onSync.stream,
          roomId: widget.room.id,
        );
      final contacts = await widget.api.listContacts();
      if (!mounted) return;
      final contactsById = {
        for (final contact in contacts)
          contact.matrixUserId: contact.toDetails(),
      };
      await Navigator.push<void>(
        context,
        CupertinoPageRoute(
          builder: (_) => GroupChatInfoPage(
            controller: infoController,
            onAddMember: () => _openGroupMemberPicker(infoController),
            onSearchHistory: _openHistorySearch,
            onClearLocalHistory: _clearLocalHistory,
            onMemberTap: (member) async {
              final contact = contactsById[member.matrixUserId];
              if (contact != null) await _openContact(contact);
            },
            onLeft: () {
              Navigator.pop(context);
              Navigator.pop(context);
            },
          ),
        ),
      );
      infoController.dispose();
      return;
    }
    User? member;
    for (final participant in widget.room.getParticipants()) {
      if (participant.id != widget.room.client.userID) {
        member = participant;
        break;
      }
    }
    final contact = peer;
    final peerId = contact?.matrixUserId ?? member?.id;
    if (peerId == null) return;
    final peerName =
        contact?.displayName ?? member?.calcDisplayname() ?? peerId;
    final avatarUrl = contact?.avatarUrl ?? member?.avatarUrl?.toString();
    await Navigator.push<void>(
      context,
      CupertinoPageRoute(
        builder: (_) => DirectChatInfoPage(
          peerName: peerName,
          peerId: peerId,
          matrixClient: widget.room.client,
          peerAvatarUrl: avatarUrl,
          preference: preferenceForRoom(widget.room),
          onAddMember: widget.onCreateGroup,
          onSearchHistory: _openHistorySearch,
          onClearLocalHistory: _clearLocalHistory,
          onPreferenceChanged: (preference) =>
              writeConversationPreference(widget.room, preference),
        ),
      ),
    );
  }

  Future<void> _openGroupMemberPicker(
    GroupChatInfoController infoController,
  ) async {
    try {
      final contacts = await widget.api.listContacts();
      if (!mounted) return;
      final existing = infoController.state.snapshot?.members
              .map((member) => member.matrixUserId)
              .toSet() ??
          <String>{};
      await Navigator.push<void>(
        context,
        CupertinoPageRoute(
          builder: (_) => GroupMemberPickerPage(
            contacts: contacts,
            existingMemberIds: existing,
            onInvite: infoController.invite,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('无法添加群成员'),
          content: const Text('通讯录加载失败，请检查网络后重试。'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    }
  }

  void _openHistorySearch() {
    final messages = controller?.messages ?? const <RoomMessageViewModel>[];
    Navigator.push<void>(
      context,
      CupertinoPageRoute(
        builder: (_) => GroupChatHistorySearchPage(
          isGroup: isGroup,
          onEntryTap: (entry) async {
            Navigator.pop(context);
            if (entry.eventId.isNotEmpty) {
              await _scrollToMessage(entry.eventId);
            }
          },
          entries: [
            for (final message in messages)
              GroupChatHistoryEntry(
                sender: _displayName(message.senderId, message.isOwn),
                text: message.text,
                senderId: message.senderId,
                eventId: message.id,
                timestamp: message.timestamp,
                kind: switch (message.kind) {
                  RoomMessageKind.image
                      when message.mimeType?.startsWith('video/') == true =>
                    LocalChatSearchKind.video,
                  RoomMessageKind.image => LocalChatSearchKind.image,
                  RoomMessageKind.file => LocalChatSearchKind.file,
                  _ => LocalChatSearchKind.text,
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _clearLocalHistory() async {
    final store = hiddenEvents;
    if (store == null) return;
    for (final message
        in controller?.messages ?? const <RoomMessageViewModel>[]) {
      await store.hide(widget.room.id, message.id);
    }
    if (mounted) setState(() {});
  }

  Future<void> _scrollToMessage(String eventId) async {
    var target = messageKeys[eventId]?.currentContext;
    // A reply may point beyond the currently loaded timeline window. Fetch
    // older batches until the event becomes available, with a strict bound to
    // avoid an endless request loop when the event has expired or was purged.
    for (var attempts = 0;
        target == null && attempts < 20 && mounted;
        attempts++) {
      final before = controller?.messages.length ?? 0;
      await controller?.loadHistory();
      if (!mounted || (controller?.messages.length ?? 0) <= before) break;
      await WidgetsBinding.instance.endOfFrame;
      target = messageKeys[eventId]?.currentContext;
    }
    if (target == null || !mounted || !target.mounted) return;
    final scrollTarget = target;
    await Scrollable.ensureVisible(
      scrollTarget,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: .5,
    );
    if (!mounted) return;
    setState(() => highlightedMessageId = eventId);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted && highlightedMessageId == eventId) {
      setState(() => highlightedMessageId = null);
    }
  }

  String _displayName(String matrixUserId, bool own) {
    if (own) return ownProfile?.nickname ?? '我';
    return contactsByMatrixId[matrixUserId]?.displayName ??
        matrixUserId.split(':').first.replaceFirst('@', '');
  }

  Widget _avatar(RoomMessageViewModel message) {
    final contact = contactsByMatrixId[message.senderId];
    final member =
        widget.room.unsafeGetUserFromMemoryOrFallback(message.senderId);
    return MatrixUserAvatar(
      client: widget.room.client,
      diagnosticSource: 'room-message',
      nickname: _displayName(message.senderId, message.isOwn),
      fallbackSeed: message.senderId.isEmpty ? 'me' : message.senderId,
      matrixAvatarUri: message.isOwn ? null : member.avatarUrl,
      fallbackAvatarUrl:
          message.isOwn ? ownProfile?.avatarUrl : contact?.avatarUrl,
      size: WeChatDimensions.messageAvatar,
    );
  }

  Widget _messageContent(RoomMessageViewModel message) =>
      switch (message.kind) {
        RoomMessageKind.image => EncryptedImageMessage(
            load: () => controller!.loadAttachment(message.id),
          ),
        RoomMessageKind.file => WeChatAttachmentTile(
            name: message.text,
            progress: switch (message.deliveryState) {
              RoomDeliveryState.sending => .5,
              RoomDeliveryState.sent => 1,
              RoomDeliveryState.failed => 0,
            },
          ),
        RoomMessageKind.voice => WeChatVoiceBubble(
            duration: message.voiceDuration,
          ),
        RoomMessageKind.redPacket => WeChatRedPacketCard(
            greeting: message.greeting ?? '恭喜发财',
            state: RedPacketVisualState.available,
            onTap: message.packetId == null
                ? null
                : () => showCupertinoModalPopup<void>(
                      context: context,
                      builder: (_) => RedPacketDetailSheet(
                        api: widget.api,
                        packetId: message.packetId!,
                      ),
                    ),
          ),
        RoomMessageKind.system => Text(
            message.text,
            style: const TextStyle(
              color: WeChatColors.textSecondary,
              fontSize: 13,
            ),
          ),
        RoomMessageKind.text => Text(message.text),
      };

  String _formatTime(DateTime timestamp) {
    final local = timestamp.toLocal();
    final now = DateTime.now();
    final time = '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return time;
    }
    if (local.year == now.year) return '${local.month}月${local.day}日 $time';
    return '${local.year}年${local.month}月${local.day}日 $time';
  }

  Widget _messageRow(RoomMessageViewModel message, DateTime? previousTime) {
    final contact = contactsByMatrixId[message.senderId];
    User? member;
    for (final participant in widget.room.getParticipants()) {
      if (participant.id == message.senderId) {
        member = participant;
        break;
      }
    }
    final displayName = resolveMessageSenderDisplayName(
      senderId: message.senderId,
      contactDisplayName: contact?.displayName,
      matrixDisplayName: member?.calcDisplayname(),
    );
    if (message.isRecalled) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: message.isOwn
              ? Wrap(children: [
                  const Text('你撤回了一条消息 ',
                      style: TextStyle(
                          color: WeChatColors.textSecondary, fontSize: 13)),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    onPressed: () => setState(() {
                      input.text = recalledDrafts[message.id] ?? '';
                      input.selection =
                          TextSelection.collapsed(offset: input.text.length);
                    }),
                    child: const Text('重新编辑',
                        style: TextStyle(
                            color: WeChatColors.socialLink, fontSize: 13)),
                  ),
                ])
              : Text('$displayName 撤回了一条消息',
                  style: const TextStyle(
                      color: WeChatColors.textSecondary, fontSize: 13)),
        ),
      );
    }
    final candidates = (controller?.messages ?? const <RoomMessageViewModel>[])
        .where((item) => item.id == message.replyToEventId);
    final replied = candidates.isEmpty ? null : candidates.first;
    final body = Column(
      children: [
        if (shouldShowMessageTimeSeparator(previousTime, message.timestamp))
          Padding(
            key: ValueKey('message-time-${message.id}'),
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              _formatTime(message.timestamp),
              style: const TextStyle(
                color: WeChatColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        if (message.kind == RoomMessageKind.system)
          WeChatNudgeNotice(text: message.text)
        else
          WeChatMessageBubble(
            content: _messageContent(message),
            avatar: _avatar(message),
            onAvatarTap: contact == null ? null : () => _openContact(contact),
            onAvatarDoubleTap: () => _sendNudge(message, displayName),
            onAvatarLongPress: () {
              final value = mentionDraft.append(
                input.text,
                displayName: displayName,
                userId: message.senderId,
              );
              input
                ..text = value
                ..selection = TextSelection.collapsed(offset: value.length);
            },
            onLongPress: () => _showMessageActions(message),
            direction: message.isOwn
                ? MessageDirection.outgoing
                : MessageDirection.incoming,
            state: switch (message.deliveryState) {
              RoomDeliveryState.sending => MessageDeliveryState.sending,
              RoomDeliveryState.failed => MessageDeliveryState.failed,
              RoomDeliveryState.sent => MessageDeliveryState.sent,
            },
          ),
        if (message.replyToEventId != null)
          Align(
            alignment:
                message.isOwn ? Alignment.centerRight : Alignment.centerLeft,
            child: _QuotePreview(
              message: replied,
              targetEventId: message.replyToEventId!,
              displayName: replied == null
                  ? '引用消息'
                  : _displayName(replied.senderId, replied.isOwn),
              onTap: () => _scrollToMessage(message.replyToEventId!),
            ),
          ),
      ],
    );
    if (!selection.active) return body;
    final selected = selection.selectedIds.contains(message.id);
    return Row(
      children: [
        CupertinoButton(
          key: ValueKey('message-select-${message.id}'),
          minimumSize: const Size.square(44),
          padding: EdgeInsets.zero,
          onPressed: () => setState(() => selection.toggle(message.id)),
          child: Icon(
            selected
                ? CupertinoIcons.checkmark_circle_fill
                : CupertinoIcons.circle,
            color: selected
                ? WeChatColors.brandPrimary
                : WeChatColors.textSecondary,
          ),
        ),
        Expanded(child: body),
      ],
    );
  }

  MessageContentKind _contentKind(RoomMessageViewModel message) =>
      switch (message.kind) {
        RoomMessageKind.image => message.mimeType == 'image/gif'
            ? MessageContentKind.gif
            : MessageContentKind.image,
        RoomMessageKind.file => MessageContentKind.file,
        RoomMessageKind.voice => MessageContentKind.voice,
        RoomMessageKind.redPacket => MessageContentKind.redPacket,
        RoomMessageKind.system => MessageContentKind.system,
        RoomMessageKind.text => MessageContentKind.text,
      };

  Future<void> _showMessageActions(RoomMessageViewModel message) async {
    final serverNow = await _serverNow();
    if (!mounted) return;
    final actions = MessageActionPolicy.actionsFor(
      MessageCapabilities(
        kind: _contentKind(message),
        isOwn: message.isOwn,
        sentAt: message.timestamp,
        serverNow: serverNow ?? message.timestamp.add(const Duration(days: 1)),
      ),
    );
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => MessageActionSheet(
        actions: actions,
        onSelected: (action) {
          Navigator.pop(sheetContext);
          _handleMessageAction(message, action);
        },
      ),
    );
  }

  Future<void> _handleMessageAction(
    RoomMessageViewModel message,
    MessageAction action,
  ) async {
    switch (action) {
      case MessageAction.deleteLocal:
        if (hiddenEvents == null) return;
        await hiddenEvents!.hide(widget.room.id, message.id);
        if (mounted) setState(() {});
      case MessageAction.multiSelect:
        setState(() => selection.startWith(message.id));
      case MessageAction.forward:
        await _forwardMessages([message]);
      case MessageAction.reply:
        setState(() => replyingTo = message);
      case MessageAction.recall:
        final interaction = _interaction;
        final serverNow = await _serverNow();
        if (interaction == null || serverNow == null) return;
        recalledDrafts[message.id] = message.text;
        await interaction.recall(
          MessageInteractionEvent(
            id: message.id,
            senderId: message.senderId,
            originServerTs: message.timestamp,
          ),
          serverNow: serverNow,
        );
        await controller?.refresh();
      case MessageAction.addToEmoji:
        await _addMessageToEmoji(message);
      case MessageAction.reminder:
        await _showReminderPicker(message);
    }
  }

  bool _isForwardable(String eventId, List<RoomMessageViewModel> messages) {
    final message = messages.firstWhere((item) => item.id == eventId);
    return MessageActionPolicy.isForwardable(_contentKind(message));
  }

  Future<void> _deleteSelection() async {
    final store = hiddenEvents;
    if (store == null) return;
    for (final eventId in selection.selectedIds) {
      await store.hide(widget.room.id, eventId);
    }
    if (!mounted) return;
    setState(selection.exit);
  }

  Future<void> _forwardMessages(List<RoomMessageViewModel> messages) async {
    final interaction = _interaction;
    if (interaction == null) return;
    final vaultRoomId = widget
        .room.client.accountData[emojiVaultAccountDataType]?.content['room_id']
        ?.toString();
    final reminderRoomId = widget.room.client
        .accountData[messageReminderAccountDataType]?.content['room_id']
        ?.toString();
    final targets = widget.room.client.rooms
        .where(
          (room) =>
              room.id != widget.room.id &&
              room.encrypted &&
              !isMatrixControlRoom(
                roomId: room.id,
                displayName: room.getLocalizedDisplayname(),
                vaultRoomId: vaultRoomId,
                reminderRoomId: reminderRoomId,
              ),
        )
        .toList(growable: false);
    if (targets.isEmpty) {
      setState(() => mediaMessage = '没有可用的端到端加密会话');
      return;
    }
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: const Text('选择转发到的会话'),
        actions: [
          for (final target in targets)
            CupertinoActionSheetAction(
              onPressed: () async {
                Navigator.pop(sheetContext);
                try {
                  for (final message in messages) {
                    await interaction.forward(message.id, target.id);
                  }
                  if (!mounted) return;
                  setState(() {
                    mediaMessage = '已转发 ${messages.length} 条消息';
                    selection.exit();
                  });
                } catch (_) {
                  if (mounted) setState(() => mediaMessage = '转发失败，请重试');
                }
              },
              child: Text(target.getLocalizedDisplayname()),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheetContext),
          child: const Text('取消'),
        ),
      ),
    );
  }

  @override
  void dispose() {
    controller?.removeListener(_changed);
    controller?.dispose();
    mediaMessageTimer?.cancel();
    input.dispose();
    messageScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allMessages = controller?.messages ?? const <RoomMessageViewModel>[];
    final messages = hiddenEvents?.visibleItems(
          widget.room.id,
          allMessages,
          eventId: (message) => message.id,
        ) ??
        allMessages;
    final showAnnouncement =
        readAnnouncementVersion != null && _showAnnouncement;
    return WeChatPageScaffold.navigation(
      backgroundColor: WeChatColors.chatPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.chatNavigationBackground,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: peer == null ? null : () => _openContact(peer!),
          child: Text(_navigationTitle),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoButton(
              key: const Key('chat-details'),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              onPressed: _openConversationDetails,
              child: const Icon(ChangliaoIcons.more, size: 22),
            ),
          ],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            if (showAnnouncement)
              CupertinoButton(
                key: const Key('group-announcement-bar'),
                padding: EdgeInsets.zero,
                onPressed: _openAnnouncement,
                child: Container(
                  height: 40,
                  color: WeChatColors.chatNavigationBackground,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(children: [
                    const Icon(CupertinoIcons.volume_up, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _announcement,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(color: WeChatColors.textSecondary),
                      ),
                    ),
                    const CupertinoListTileChevron(),
                  ]),
                ),
              ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _dismissComposerExtensions,
                child: loading
                    ? const Center(child: CupertinoActivityIndicator())
                    : errorMessage != null
                        ? Center(child: Text(errorMessage!))
                        : messages.isEmpty
                            ? const SizedBox.expand()
                            : ListView.builder(
                                controller: messageScrollController,
                                reverse: true,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: WeChatSpacing.md,
                                  vertical: WeChatSpacing.sm,
                                ),
                                itemCount: messages.length,
                                itemBuilder: (_, reverseIndex) {
                                  final index =
                                      messages.length - reverseIndex - 1;
                                  final message = messages[index];
                                  final previous = index == 0
                                      ? null
                                      : messages[index - 1].timestamp;
                                  return Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: WeChatSpacing.sm,
                                    ),
                                    child: KeyedSubtree(
                                      key: messageKeys.putIfAbsent(
                                        message.id,
                                        GlobalKey.new,
                                      ),
                                      child: AnimatedContainer(
                                        duration:
                                            const Duration(milliseconds: 180),
                                        color:
                                            highlightedMessageId == message.id
                                                ? WeChatColors.divider
                                                : const Color(0x00000000),
                                        child: _messageRow(message, previous),
                                      ),
                                    ),
                                  );
                                },
                              ),
              ),
            ),
            if (mediaMessage != null)
              AnimatedOpacity(
                opacity: mediaMessageVisible ? 1 : 0,
                duration: const Duration(milliseconds: 500),
                child: Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  color: WeChatColors.chatNavigationBackground,
                  child: Text(mediaMessage!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12)),
                ),
              ),
            if (replyingTo != null && !selection.active)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                color: CupertinoTheme.of(context).barBackgroundColor,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '引用：${replyingTo!.text}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: WeChatColors.textSecondary,
                        ),
                      ),
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size.square(36),
                      onPressed: () => setState(() => replyingTo = null),
                      child: const Icon(CupertinoIcons.xmark, size: 18),
                    ),
                  ],
                ),
              ),
            if (selection.active)
              MessageSelectionBar(
                count: selection.selectedIds.length,
                canForward: selection.canForward(
                  (eventId) => _isForwardable(eventId, messages),
                ),
                onForward: () => _forwardMessages([
                  for (final message in messages)
                    if (selection.selectedIds.contains(message.id)) message,
                ]),
                onDelete: _deleteSelection,
                onCancel: () => setState(selection.exit),
              )
            else ...[
              ChatComposerBar(
                controller: input,
                panel: composerPanel,
                onMore: () => _togglePanel(ComposerPanel.more),
                onVoice: _showVoice,
                onEmoji: () => _togglePanel(ComposerPanel.emoji),
                onSend: _send,
                onSubmitted: (_) => _send(),
              ),
              if (composerPanel == ComposerPanel.more)
                ChatMorePanel(onSelected: _handleMoreAction),
              if (composerPanel == ComposerPanel.emoji)
                SizedBox(
                  height: 280,
                  child: ChatEmojiPanel(
                    onEmojiSelected: _insertEmoji,
                    customItems: customEmojiItems,
                    onCustomSelected: _sendCustomEmoji,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

final class GroupAnnouncementPage extends StatelessWidget {
  const GroupAnnouncementPage({
    super.key,
    required this.title,
    required this.announcement,
  });
  final String title;
  final String announcement;
  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: const Text('群公告'),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              Text(announcement),
            ]),
          ),
        ),
      );
}

final class EncryptedImageMessage extends StatefulWidget {
  const EncryptedImageMessage({super.key, required this.load});

  final Future<Uint8List> Function() load;

  @override
  State<EncryptedImageMessage> createState() => _EncryptedImageMessageState();
}

final class _EncryptedImageMessageState extends State<EncryptedImageMessage> {
  late Future<Uint8List> bytes;

  @override
  void initState() {
    super.initState();
    bytes = widget.load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
        future: bytes,
        builder: (_, snapshot) {
          if (snapshot.hasError) {
            return CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () => setState(() => bytes = widget.load()),
              child: const Text('图片加载失败，点击重试'),
            );
          }
          if (!snapshot.hasData) {
            return const SizedBox(
              width: 160,
              height: 120,
              child: Center(child: CupertinoActivityIndicator()),
            );
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              snapshot.data!,
              width: 180,
              fit: BoxFit.cover,
            ),
          );
        },
      );
}

final class _QuotePreview extends StatelessWidget {
  const _QuotePreview({
    required this.message,
    required this.targetEventId,
    required this.displayName,
    required this.onTap,
  });

  final RoomMessageViewModel? message;
  final String targetEventId;
  final String displayName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final message = this.message;
    final summary = switch (message?.kind) {
      RoomMessageKind.image => '图片',
      RoomMessageKind.voice => '语音 ${message!.voiceDuration.inSeconds}″',
      RoomMessageKind.file => '文件：${message!.text}',
      _ => _truncateQuoteText(message?.text ?? '原消息加载中'),
    };
    return CupertinoButton(
      key: Key('reply-preview-$targetEventId'),
      padding: const EdgeInsets.only(top: 4),
      minimumSize: Size.zero,
      onPressed: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 236),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: WeChatColors.divider,
          borderRadius: BorderRadius.circular(WeChatRadius.control),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (message?.kind == RoomMessageKind.image)
            const Icon(CupertinoIcons.photo,
                size: 15, color: WeChatColors.textSecondary)
          else if (message?.kind == RoomMessageKind.voice)
            const Icon(CupertinoIcons.speaker_2,
                size: 15, color: WeChatColors.textSecondary),
          if (message?.kind == RoomMessageKind.image ||
              message?.kind == RoomMessageKind.voice)
            const SizedBox(width: 4),
          Flexible(
            child: Text(
              '$displayName：$summary',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: WeChatColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

String _truncateQuoteText(String value) {
  final characters = value.characters;
  return characters.length > 10
      ? '${characters.take(10).toString()}...'
      : value;
}
