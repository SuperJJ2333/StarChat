import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:matrix/matrix.dart';

import '../../core/business_api_client.dart';
import '../contacts/contact_models.dart';
import '../contacts/contacts_page.dart';
import '../profile/profile_controller.dart';
import '../redpacket/red_packet_detail_sheet.dart';
import '../../ui/chat/chat_composer_bar.dart';
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
import 'media_message_service.dart';
import 'room_timeline_controller.dart';
import 'voice_composer.dart';

class MatrixHomePage extends StatefulWidget {
  const MatrixHomePage({
    super.key,
    required this.api,
    required this.matrix,
    required this.themeController,
    required this.onCreateGroup,
    this.onVoice,
    this.onVideo,
  });
  final BusinessApiClient api;
  final MatrixSdkE2eeClient matrix;
  final ThemeController themeController;
  final VoidCallback onCreateGroup;
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
    final rooms = widget.matrix.sdkClient.rooms;
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
                    onTap: () => Navigator.push(
                      context,
                      CupertinoPageRoute(
                        builder: (_) => RoomPage(
                          api: widget.api,
                          room: room,
                          roomName: roomName,
                          onVoice: widget.onVoice,
                          onVideo: widget.onVideo,
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
    this.onVoice,
    this.onVideo,
  });

  final BusinessApiClient api;
  final String roomName;
  final Room room;
  final ContactDetails? initialContact;
  final ContactAction? onVoice;
  final ContactAction? onVideo;

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  final input = TextEditingController();
  RoomTimelineController? controller;
  Map<String, ContactDetails> contactsByMatrixId = const {};
  ProfileData? ownProfile;
  ContactDetails? peer;
  bool loading = true;
  bool mediaBusy = false;
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
      final timeline =
          await widget.room.getTimeline(onUpdate: () => controller?.refresh());
      if (!mounted) {
        timeline.cancelSubscriptions();
        return;
      }
      controller = RoomTimelineController(
        MatrixRoomTimelineAdapter(widget.room, timeline),
      )..addListener(_changed);
      setState(() => loading = false);
      await controller!.markRead();
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

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _send() async {
    final text = input.text.trim();
    if (text.isEmpty || controller == null) return;
    input.clear();
    await controller!.sendText(text);
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

  Future<void> _showMedia() async {
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: const Text('发送到当前加密会话'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheetContext);
              _sendMedia(image: true);
            },
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.photo),
                SizedBox(width: 8),
                Text('照片'),
              ],
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheetContext);
              _sendMedia(image: false);
            },
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.doc),
                SizedBox(width: 8),
                Text('文件'),
              ],
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheetContext);
              _showRedPacket();
            },
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(CupertinoIcons.gift),
                SizedBox(width: 8),
                Text('红包'),
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

  Future<void> _showEmoji() async {
    const emojis = [
      '😀',
      '😃',
      '😄',
      '😁',
      '😂',
      '😊',
      '😍',
      '😘',
      '🤔',
      '😎',
      '😭',
      '😡',
      '👍',
      '👏',
      '🙏',
      '🎉',
      '❤️',
      '💪',
      '🌹',
      '🔥',
      '✅',
      '🎁',
      '🍻',
      '✨',
    ];
    final selected = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheetContext) => CupertinoPopupSurface(
        child: SafeArea(
          child: SizedBox(
            height: 260,
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 8,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: emojis.length,
              itemBuilder: (_, index) => CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () => Navigator.pop(sheetContext, emojis[index]),
                child:
                    Text(emojis[index], style: const TextStyle(fontSize: 28)),
              ),
            ),
          ),
        ),
      ),
    );
    if (selected == null) return;
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
    final contact = peer;
    if (contact != null) {
      await _openContact(contact);
      return;
    }
    await Navigator.push<void>(
      context,
      CupertinoPageRoute(
        builder: (_) => CupertinoPageScaffold(
          navigationBar: const CupertinoNavigationBar(middle: Text('群聊信息')),
          child: SafeArea(
            child: ListView(
              children: [
                for (final contact in contactsByMatrixId.values)
                  CupertinoListTile(
                    leading: UserAvatar(
                      nickname: contact.displayName,
                      fallbackSeed: contact.username,
                      avatarUrl: contact.avatarUrl,
                      size: 40,
                    ),
                    title: Text(contact.displayName),
                    onTap: () => _openContact(contact),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
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
    return Column(
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
    final messages = controller?.messages ?? const <RoomMessageViewModel>[];
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
            ChatComposerBar(
              controller: input,
              onMore: _showMedia,
              onVoice: _showVoice,
              onEmoji: _showEmoji,
              onSend: _send,
              onSubmitted: (_) => _send(),
            ),
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
