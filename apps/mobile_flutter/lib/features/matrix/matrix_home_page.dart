import 'package:flutter/cupertino.dart';
import 'package:matrix/matrix.dart';

import '../../ui/chat/wechat_message_bubble.dart';
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
  @override State<MatrixHomePage> createState() => _MatrixHomePageState();
}

class _MatrixHomePageState extends State<MatrixHomePage> {
  bool syncing = false;
  Future<void> sync() async {
    if (syncing) return;
    setState(() => syncing = true);
    try { await widget.matrix.sync(); } finally { if (mounted) setState(() => syncing = false); }
  }
  @override void initState() { super.initState(); sync(); }
  @override Widget build(BuildContext context) {
    final rooms = widget.matrix.sdkClient.rooms;
    final items = rooms.map((room) => CupertinoListTile(
      title: Text(room.getLocalizedDisplayname()),
      subtitle: Text(room.lastEvent?.text ?? '端到端加密消息'),
      onTap: () => Navigator.push(context, CupertinoPageRoute(builder: (_) => RoomPage(room: room, roomName: room.getLocalizedDisplayname()))),
    )).toList();
    if (items.isEmpty) items.add(const CupertinoListTile(title: Text('暂无房间')));
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('消息')),
      child: SafeArea(child: ListView(padding: const EdgeInsets.all(WeChatSpacing.md), children: [CupertinoListSection.insetGrouped(children: items)])),
    );
  }
}

class RoomPage extends StatefulWidget {
  const RoomPage({super.key, required this.roomName, required this.room});
  final String roomName;
  final Room room;
  @override State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  final input = TextEditingController();
  RoomTimelineController? controller;
  bool loading = true;

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    late final Timeline timeline;
    timeline = await widget.room.getTimeline(onUpdate: () => controller?.refresh());
    if (!mounted) { timeline.cancelSubscriptions(); return; }
    controller = RoomTimelineController(MatrixRoomTimelineAdapter(widget.room, timeline))..addListener(_changed);
    setState(() => loading = false);
    await controller!.markRead();
  }
  void _changed() { if (mounted) setState(() {}); }
  Future<void> _send() async {
    final text = input.text.trim();
    if (text.isEmpty || controller == null) return;
    input.clear();
    await controller!.sendText(text);
  }
  void _showMedia() {
    showCupertinoModalPopup<void>(context: context, builder: (_) => CupertinoPopupSurface(
      child: SafeArea(child: SizedBox(height: 320, child: MediaComposer(
        service: MediaMessageService(MatrixSdkE2eeClient(widget.room.client, homeserver: widget.room.client.homeserver!)),
        roomId: widget.room.id,
      ))),
    ));
  }
  void _showVoice() {
    showCupertinoModalPopup<void>(context: context, builder: (_) => CupertinoPopupSurface(
      child: SafeArea(child: VoiceComposer(service: MediaMessageService(MatrixSdkE2eeClient(widget.room.client, homeserver: widget.room.client.homeserver!)), roomId: widget.room.id)),
    ));
  }
  @override void dispose() { controller?.removeListener(_changed); controller?.dispose(); input.dispose(); super.dispose(); }

  @override Widget build(BuildContext context) {
    final messages = controller?.messages ?? const <RoomMessageViewModel>[];
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(widget.roomName)),
      child: SafeArea(child: Column(children: [
        Expanded(child: loading
            ? const Center(child: CupertinoActivityIndicator())
            : messages.isEmpty
                ? const Center(child: Text('暂无消息'))
                : ListView.builder(
                    padding: const EdgeInsets.all(WeChatSpacing.md),
                    itemCount: messages.length,
                    itemBuilder: (_, index) {
                      final message = messages[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: WeChatSpacing.sm),
                        child: WeChatMessageBubble(
                          content: Text(message.text),
                          direction: message.isOwn ? MessageDirection.outgoing : MessageDirection.incoming,
                          state: switch (message.deliveryState) {
                            RoomDeliveryState.sending => MessageDeliveryState.sending,
                            RoomDeliveryState.failed => MessageDeliveryState.failed,
                            RoomDeliveryState.sent => MessageDeliveryState.sent,
                          },
                        ),
                      );
                    },
                  )),
        Container(
          color: CupertinoTheme.of(context).barBackgroundColor,
          padding: const EdgeInsets.all(WeChatSpacing.sm),
          child: Row(children: [
            CupertinoButton(padding: const EdgeInsets.symmetric(horizontal: WeChatSpacing.sm), onPressed: _showMedia, child: const Icon(CupertinoIcons.add_circled)),
            CupertinoButton(padding: const EdgeInsets.symmetric(horizontal: WeChatSpacing.xs), onPressed: _showVoice, child: const Icon(CupertinoIcons.mic)),
            Expanded(child: CupertinoTextField(controller: input, placeholder: '输入加密消息', onSubmitted: (_) => _send(), padding: const EdgeInsets.all(WeChatSpacing.sm))),
            CupertinoButton(onPressed: _send, child: const Text('发送')),
          ]),
        ),
      ])),
    );
  }
}
