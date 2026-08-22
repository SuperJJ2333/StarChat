import 'package:flutter/cupertino.dart';

import '../../ui/foundation/wechat_tokens.dart';
import '../../ui/components/modern_action_button.dart';
import 'matrix_e2ee_client.dart';
import 'matrix_verification_service.dart';

final class MatrixVerificationPage extends StatefulWidget {
  const MatrixVerificationPage({super.key, required this.matrix});
  final MatrixSdkE2eeClient matrix;
  @override
  State<MatrixVerificationPage> createState() => _MatrixVerificationPageState();
}

final class _MatrixVerificationPageState extends State<MatrixVerificationPage> {
  late final MatrixVerificationService service =
      MatrixVerificationService(widget.matrix.sdkClient);
  String status = '等待验证请求';
  Future<void> _action(Future<void> Function() f, String text) async {
    try {
      await f();
      if (mounted) setState(() => status = text);
    } catch (e) {
      if (mounted) setState(() => status = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: Text('SAS 设备验证')),
      child: SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
        const Icon(CupertinoIcons.lock_rotation,
            size: 64, color: CupertinoColors.systemIndigo),
        const SizedBox(height: 20),
        Text(status, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        ModernActionButton(
            icon: CupertinoIcons.check_mark_circled,
            label: '接受验证',
            onPressed: () =>
                _action(service.acceptIncoming, '已接受验证，请选择相同的 SAS 表情或数字')),
        const SizedBox(height: 10),
        ModernActionButton(
          icon: CupertinoIcons.number,
          label: '显示 SAS',
          onPressed: () => _action(service.chooseSas, 'SAS 已发送，请与对方比对'),
        ),
        const SizedBox(height: 10),
        ModernActionButton(
          icon: CupertinoIcons.shield_lefthalf_fill,
          label: '确认匹配',
          onPressed: () => _action(service.confirmSasMatch, '验证完成，设备已信任'),
        ),
        const SizedBox(height: 10),
        ModernActionButton(
          icon: CupertinoIcons.xmark_shield,
          label: '拒绝',
          kind: ModernActionKind.danger,
          onPressed: () => _action(service.reject, '已拒绝验证'),
        ),
      ])));
  @override
  void dispose() {
    service.dispose();
    super.dispose();
  }
}
