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
import '../../ui/chat/message_action.dart';
import '../../ui/chat/message_action_sheet.dart';
import '../../ui/chat/wechat_attachment_tile.dart';
import '../../ui/chat/wechat_message_bubble.dart';
import '../../ui/chat/wechat_voice_bubble.dart';
import '../../ui/components/conversation_list_tile.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/finance/wechat_red_packet_card.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../../ui/theme/theme_controller.dart';
import '../../ui/theme/theme_picker_sheet.dart';
import 'matrix_e2ee_client.dart';
import 'matrix_room_timeline_adapter.dart';
import 'chat_red_packet_adapters.dart';
import 'chat_red_packet_controller.dart';
import 'chat_red_packet_sheet.dart';
import 'group_chat_info_controller.dart';
import 'group_chat_info_page.dart';
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
  });
  final BusinessApiClient api;
  final MatrixSdkE2eeClient matrix;
  final ThemeController themeController;
  final VoidCallback onCreateGroup;
  final MessageReminderService? reminderService;
  final ContactAction? onVoice;
  final ContactAction? onVideo;
  @override
  State<MatrixHomePage> createState() => _MatrixHomePageState();
}

class _MatrixHomePageState extends State<MatrixHomePage> {
  bool syncing = false;

  Future<void> sync() async {
    if (syncing) return;
    setState(() => syncing = true);
    try {
      await widget.matrix.sync();
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  @override
  void initState() {
    super.initState();
    sync();
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

  @override
  Widget build(BuildContext context) {
    final vaultRoomId = widget.matrix.sdkClient
        .accountData[emojiVaultAccountDataType]?.content['room_id']
        ?.toString();
    final reminderRoomId = widget.matrix.sdkClient
        .accountData[messageReminderAccountDataType]?.content['room_id']
        ?.toString();
    final rooms = widget.matrix.sdkClient.rooms
        .where(
          (room) => !isMatrixControlRoom(
            roomId: room.id,
            displayName: room.getLocalizedDisplayname(),
            vaultRoomId: vaultRoomId,
            reminderRoomId: reminderRoomId,
          ),
        )
        .toList(growable: false);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('消息'),
        trailing: CupertinoButton(
          key: const Key('messages-more'),
          padding: EdgeInsets.zero,
          onPressed: _showMore,
          child: const Icon(ChangliaoIcons.more, size: 22),
        ),
      ),
      child: SafeArea(
        child: rooms.isEmpty
            ? const _MessagesEmptyState()
            : ListView.separated(
                padding: EdgeInsets.zero,
                itemCount: rooms.length,
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
                  final room = rooms[index];
                  final roomName = room.getLocalizedDisplayname();
                  return ConversationListTile(
                    key: ValueKey<String>('conversation-${room.id}'),
                    title: roomName,
                    subtitle: room.lastEvent?.text ?? '端到端加密消息',
                    timeLabel: _roomTime(room),
                    avatar: UserAvatar(
                      nickname: roomName,
                      fallbackSeed: room.id,
                      size: WeChatDimensions.conversationAvatar,
                    ),
                    unreadCount: room.notificationCount,
                    muted: room.pushRuleState != PushRuleState.notify,
                    onTap: () =>
                        Navigator.of(context, rootNavigator: true).push(
                      CupertinoPageRoute(
                        builder: (_) => RoomPage(
                          api: widget.api,
                          room: room,
                          roomName: roomName,
                          onVoice: widget.onVoice,
                          onVideo: widget.onVideo,
                          reminderService: widget.reminderService,
                        ),
                      ),
                    ),
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

class RoomPage extends StatefulWidget {
  const RoomPage({
    super.key,
    required this.api,
    required this.roomName,
    required this.room,
    this.initialContact,
    this.reminderService,
    this.onVoice,
    this.onVideo,
  });

  final BusinessApiClient api;
  final String roomName;
  final Room room;
  final ContactDetails? initialContact;
  final MessageReminderService? reminderService;
  final ContactAction? onVoice;
  final ContactAction? onVideo;

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  final input = TextEditingController();
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
  ContactDetails? peer;
  bool loading = true;
  bool mediaBusy = false;
  ComposerPanel composerPanel = ComposerPanel.none;
  String? errorMessage;
  String? mediaMessage;

  bool get isGroup => !widget.room.isDirectChat;

  @override
  void initState() {
    super.initState();
    peer = widget.initialContact;
    _load();
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
      final contacts = await widget.api.listContacts();
      final profile = await widget.api.loadProfile();
      final mapped = {
        for (final contact in contacts)
          contact.matrixUserId: contact.toDetails(),
      };
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
        ownProfile = profile;
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
      nudgeSuffix = await NudgePreferenceService(
        MatrixNudgePreferenceBackend(widget.room.client),
      ).loadSuffix();
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
      await NudgeService(
        backend: MatrixNudgeBackend(widget.room.client),
        roomId: widget.room.id,
        senderId: senderId,
        senderDisplayName: sender.nickname,
      ).send(
        targetUserId: message.senderId,
        targetDisplayName: targetDisplayName,
        suffix: nudgeSuffix,
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

  Future<void> _editNudgeSuffix() async {
    final field = TextEditingController(text: nudgeSuffix);
    await showCupertinoDialog<void>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('设置拍一拍'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            key: const Key('nudge-suffix-input'),
            controller: field,
            maxLength: 30,
            placeholder: '例如：的肩膀',
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () async {
              try {
                final suffix = field.text.trim();
                await NudgePreferenceService(
                  MatrixNudgePreferenceBackend(widget.room.client),
                ).saveSuffix(suffix);
                if (!dialogContext.mounted) return;
                Navigator.pop(dialogContext);
                if (mounted) setState(() => nudgeSuffix = suffix);
              } catch (_) {
                if (mounted) setState(() => mediaMessage = '拍一拍设置保存失败');
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    field.dispose();
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
      if (mounted) setState(() => mediaMessage = image ? '图片已发送' : '文件已发送');
    } catch (_) {
      if (mounted) {
        setState(() => mediaMessage = image ? '图片发送失败，请重试' : '文件发送失败，请重试');
      }
    } finally {
      await service.dispose();
      if (mounted) setState(() => mediaBusy = false);
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
          ),
        ),
      );

  Future<void> _openConversationDetails() async {
    if (isGroup) {
      final infoController = GroupChatInfoController(
        MatrixGroupChatInfoGateway(widget.room),
      );
      await Navigator.push<void>(
        context,
        CupertinoPageRoute(
          builder: (_) => GroupChatInfoPage(
            controller: infoController,
            onAddMember: () => _openGroupMemberPicker(infoController),
            onSearchHistory: _openGroupHistorySearch,
            onClearLocalHistory: _clearLocalHistory,
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
    final contact = peer;
    if (contact != null) {
      await showCupertinoModalPopup<void>(
        context: context,
        builder: (sheetContext) => CupertinoActionSheet(
          actions: [
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(sheetContext);
                _openContact(contact);
              },
              child: const Text('好友资料'),
            ),
            CupertinoActionSheetAction(
              key: const Key('chat-nudge-settings'),
              onPressed: () {
                Navigator.pop(sheetContext);
                _editNudgeSuffix();
              },
              child: const Text('设置拍一拍'),
            ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(sheetContext),
            child: const Text('取消'),
          ),
        ),
      );
      return;
    }
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

  void _openGroupHistorySearch() {
    final messages = controller?.messages ?? const <RoomMessageViewModel>[];
    Navigator.push<void>(
      context,
      CupertinoPageRoute(
        builder: (_) => GroupChatHistorySearchPage(
          entries: [
            for (final message in messages)
              GroupChatHistoryEntry(
                sender: _displayName(message.senderId, message.isOwn),
                text: message.text,
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

  String _displayName(String matrixUserId, bool own) {
    if (own) return ownProfile?.nickname ?? '我';
    return contactsByMatrixId[matrixUserId]?.displayName ??
        matrixUserId.split(':').first.replaceFirst('@', '');
  }

  Widget _avatar(RoomMessageViewModel message) {
    final contact = contactsByMatrixId[message.senderId];
    return UserAvatar(
      nickname: _displayName(message.senderId, message.isOwn),
      fallbackSeed: message.senderId.isEmpty ? 'me' : message.senderId,
      avatarUrl: message.isOwn ? ownProfile?.avatarUrl : contact?.avatarUrl,
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
    input.dispose();
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
    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    return CupertinoPageScaffold(
      backgroundColor: dark
          ? WeChatColors.darkPageBackground
          : WeChatColors.lightPageBackground,
      navigationBar: CupertinoNavigationBar(
        middle: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: peer == null ? null : () => _openContact(peer!),
          child: Text(widget.roomName),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (peer != null && widget.onVoice != null)
              CupertinoButton(
                key: const Key('chat-voice-call'),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                onPressed: () => widget.onVoice!(peer!),
                child: const Icon(ChangliaoIcons.voiceCall, size: 21),
              ),
            if (peer != null && widget.onVideo != null)
              CupertinoButton(
                key: const Key('chat-video-call'),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                onPressed: () => widget.onVideo!(peer!),
                child: const Icon(ChangliaoIcons.videoCall, size: 22),
              ),
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
            Expanded(
              child: loading
                  ? const Center(child: CupertinoActivityIndicator())
                  : errorMessage != null
                      ? Center(child: Text(errorMessage!))
                      : messages.isEmpty
                          ? const Center(
                              child: Text(
                                '暂无消息',
                                style: TextStyle(
                                  color: WeChatColors.textSecondary,
                                ),
                              ),
                            )
                          : ListView.builder(
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
                                  child: _messageRow(message, previous),
                                );
                              },
                            ),
            ),
            if (mediaMessage != null)
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                color: CupertinoTheme.of(context).barBackgroundColor,
                child: Text(
                  mediaMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12),
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
