import 'package:flutter/cupertino.dart';

import '../../ui/components/modern_action_button.dart';
import '../../ui/foundation/changliao_icons.dart';
import 'chat_red_packet_controller.dart';

final class ChatRedPacketSheet extends StatefulWidget {
  const ChatRedPacketSheet({
    super.key,
    required this.controller,
    required this.isGroup,
    required this.onSent,
  });

  final ChatRedPacketController controller;
  final bool isGroup;
  final VoidCallback onSent;

  @override
  State<ChatRedPacketSheet> createState() => _ChatRedPacketSheetState();
}

final class _ChatRedPacketSheetState extends State<ChatRedPacketSheet> {
  final total = TextEditingController();
  final greeting = TextEditingController(text: '恭喜发财，大吉大利');
  final shares = TextEditingController(text: '2');
  String mode = 'RANDOM';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    total.dispose();
    greeting.dispose();
    shares.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _send() async {
    await widget.controller.submit(
      total: total.text.trim(),
      greeting: greeting.text.trim().isEmpty ? '恭喜发财' : greeting.text.trim(),
      mode: widget.isGroup ? mode : 'EQUAL',
      shareCount: widget.isGroup ? int.tryParse(shares.text) ?? 1 : 1,
    );
    if (mounted && widget.controller.state.status == ChatRedPacketStatus.sent) {
      widget.onSent();
    }
  }

  Future<void> _retryShare() async {
    await widget.controller.retryShare();
    if (mounted && widget.controller.state.status == ChatRedPacketStatus.sent) {
      widget.onSent();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final busy = state.status == ChatRedPacketStatus.creating ||
        state.status == ChatRedPacketStatus.sharing;
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('发红包')),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (widget.isGroup)
              CupertinoSlidingSegmentedControl<String>(
                groupValue: mode,
                children: const {
                  'RANDOM': Text('拼手气'),
                  'EQUAL': Text('普通红包'),
                },
                onValueChanged: (value) {
                  if (!busy) setState(() => mode = value ?? mode);
                },
              ),
            const SizedBox(height: 16),
            CupertinoTextField(
              key: const Key('chat-red-packet-total'),
              controller: total,
              enabled: !busy,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              placeholder: '总金额（彩币）',
              padding: const EdgeInsets.all(16),
            ),
            if (widget.isGroup) ...[
              const SizedBox(height: 12),
              CupertinoTextField(
                key: const Key('chat-red-packet-shares'),
                controller: shares,
                enabled: !busy,
                keyboardType: TextInputType.number,
                placeholder: '红包个数',
                padding: const EdgeInsets.all(16),
              ),
            ],
            const SizedBox(height: 12),
            CupertinoTextField(
              key: const Key('chat-red-packet-greeting'),
              controller: greeting,
              enabled: !busy,
              maxLength: 32,
              placeholder: '祝福语',
              padding: const EdgeInsets.all(16),
            ),
            const SizedBox(height: 16),
            ModernActionButton(
              key: const Key('chat-red-packet-send'),
              icon: ChangliaoIcons.gift,
              label: '塞钱进红包',
              loading: busy,
              onPressed: busy ? null : _send,
            ),
            if (state.status == ChatRedPacketStatus.shareFailed) ...[
              const SizedBox(height: 12),
              ModernActionButton(
                icon: ChangliaoIcons.retry,
                label: '重新发送到会话',
                onPressed: _retryShare,
              ),
            ],
            if (state.status == ChatRedPacketStatus.sent) ...[
              const SizedBox(height: 16),
              const Center(child: Text('红包已发送')),
            ] else if (state.message != null) ...[
              const SizedBox(height: 12),
              Text(
                state.message!,
                style: const TextStyle(color: CupertinoColors.systemRed),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
