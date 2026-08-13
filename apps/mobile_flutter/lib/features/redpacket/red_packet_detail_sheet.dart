import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../ui/finance/wechat_red_packet_card.dart';
import 'red_packet_controller.dart';

final class RedPacketDetailSheet extends StatefulWidget {
  const RedPacketDetailSheet({super.key, required this.api, required this.packetId});
  final BusinessApiClient api;
  final String packetId;
  @override State<RedPacketDetailSheet> createState() => _RedPacketDetailSheetState();
}

final class _RedPacketDetailSheetState extends State<RedPacketDetailSheet> {
  late final RedPacketController controller = RedPacketController(widget.api)..addListener(_changed);
  void _changed() { if (mounted) setState(() {}); }
  @override void initState() { super.initState(); controller.load(widget.packetId); }
  @override void dispose() { controller.removeListener(_changed); controller.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) {
    final detail = controller.detail;
    final state = switch (detail?['status']) {
      'COMPLETED' => RedPacketVisualState.exhausted,
      'EXPIRED' => RedPacketVisualState.expired,
      'CANCELLED' => RedPacketVisualState.withdrawn,
      _ => RedPacketVisualState.available,
    };
    return CupertinoPopupSurface(child: SafeArea(child: SizedBox(height: 420, child: Padding(
      padding: const EdgeInsets.all(20),
      child: controller.loading && detail == null ? const Center(child: CupertinoActivityIndicator()) : Column(children: [
        WeChatRedPacketCard(greeting: '恭喜发财，大吉大利', state: state),
        const SizedBox(height: 16),
        if (detail != null) Text('已领取 ${detail['claimed_count']}/${detail['share_count']}，共 ${detail['total']} 彩币'),
        if (controller.error != null) Text(controller.error!),
        const Spacer(),
        CupertinoButton.filled(onPressed: state == RedPacketVisualState.available && !controller.loading ? () => controller.claim(widget.packetId) : null, child: const Text('拆红包')),
      ]),
    ))));
  }
}
