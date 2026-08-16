import 'package:flutter/cupertino.dart';
import 'package:matrix/matrix.dart';

import '../../ui/chat/chat_composer_bar.dart';
import '../../ui/chat/wechat_message_bubble.dart';
import '../../ui/components/conversation_list_tile.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'matrix_e2ee_client.dart';
import 'matrix_room_timeline_adapter.dart';
import 'media_composer.dart';
import 'media_message_service.dart';
import 'room_timeline_controller.dart';
import 'voice_composer.dart';

class MatrixHomePage extends StatefulWidget {
  const MatrixHomePage({super.key, required this.matrix});
  final MatrixSdkE2eeClient matrix;
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

  @override
  Widget build(BuildContext context) {
    final rooms = widget.matrix.sdkClient.rooms;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('消息'),
        trailing: CupertinoButton(
          key: const Key('messages-more'),
          padding: EdgeInsets.zero,
          onPressed: sync,
          child: syncing
              ? const CupertinoActivityIndicator(radius: 8)
              : const Icon(ChangliaoIcons.more, size: 22),
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
                          room: room,
                          roomName: roomName,
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
    required this.roomName,
    required this.room,
    this.onVoiceCall,
    this.onVideoCall,
  });

  final String roomName;
  final Room room;
  final VoidCallback? onVoiceCall;
  final VoidCallback? onVideoCall;

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  final input = TextEditingController();
  RoomTimelineController? controller;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    late final Timeline timeline;
    timeline =
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

  void _showMedia() {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (_) => CupertinoPopupSurface(
        child: SafeArea(
          child: SizedBox(
            height: 320,
            child: MediaComposer(
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
      ),
    );
  }

  void _showVoice() {
    showCupertinoModalPopup<void>(
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
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    return CupertinoPageScaffold(
      backgroundColor: dark
          ? WeChatColors.darkPageBackground
          : WeChatColors.lightPageBackground,
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.roomName),
        trailing: widget.onVoiceCall == null && widget.onVideoCall == null
            ? const Icon(ChangliaoIcons.more, size: 22)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.onVoiceCall != null)
                    CupertinoButton(
                      key: const Key('chat-voice-call'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: WeChatSpacing.sm,
                      ),
                      onPressed: widget.onVoiceCall,
                      child: const Icon(ChangliaoIcons.voiceCall, size: 22),
                    ),
                  if (widget.onVideoCall != null)
                    CupertinoButton(
                      key: const Key('chat-video-call'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: WeChatSpacing.sm,
                      ),
                      onPressed: widget.onVideoCall,
                      child: const Icon(ChangliaoIcons.videoCall, size: 24),
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
                          itemBuilder: (_, index) {
                            final message =
                                messages[messages.length - index - 1];
                            return Padding(
                              padding: const EdgeInsets.only(
                                bottom: WeChatSpacing.sm,
                              ),
                              child: WeChatMessageBubble(
                                content: Text(message.text),
                                direction: message.isOwn
                                    ? MessageDirection.outgoing
                                    : MessageDirection.incoming,
                                state: switch (message.deliveryState) {
                                  RoomDeliveryState.sending =>
                                    MessageDeliveryState.sending,
                                  RoomDeliveryState.failed =>
                                    MessageDeliveryState.failed,
                                  RoomDeliveryState.sent =>
                                    MessageDeliveryState.sent,
                                },
                              ),
                            );
                          },
                        ),
            ),
            ChatComposerBar(
              controller: input,
              onAttachment: _showMedia,
              onVoice: _showVoice,
              onSend: _send,
              onSubmitted: (_) => _send(),
            ),
          ],
        ),
      ),
    );
  }
}
