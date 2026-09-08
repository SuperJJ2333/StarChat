import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../ui/components/wechat_scaffold.dart';

import '../../ui/foundation/wechat_tokens.dart';
import '../../ui/components/modern_action_button.dart';
import 'matrix_e2ee_client.dart';
import 'matrix_verification_service.dart';

final class MatrixVerificationPage extends StatefulWidget {
  const MatrixVerificationPage({
    super.key,
    required this.matrix,
    this.serviceFactory,
  });
  final MatrixSdkE2eeClient matrix;
  final MatrixVerificationService Function(MatrixSdkE2eeClient matrix)?
      serviceFactory;
  @override
  State<MatrixVerificationPage> createState() => _MatrixVerificationPageState();
}

final class _MatrixVerificationPageState extends State<MatrixVerificationPage> {
  late final MatrixVerificationService service =
      widget.serviceFactory?.call(widget.matrix) ??
          MatrixVerificationService(widget.matrix);
  String status = '等待验证请求';
  String? requestId;

  @override
  void initState() {
    super.initState();
    unawaited(service.listenForIncoming((state) {
      if (!mounted) return;
      setState(() {
        if (state.phase == MatrixVerificationRequestPhase.incoming) {
          requestId = state.requestId;
          status = '收到验证请求';
        } else if (requestId == state.requestId) {
          requestId = null;
          status = '验证请求已失效，请等待新请求';
        }
      });
    }).catchError((_) {
      debugPrint('E2EE_VERIFICATION_SETUP_FAILED');
    }));
  }

  Future<void> _requestAction(
    Future<void> Function(String requestId) action,
    String text,
  ) async {
    final activeId = requestId;
    if (activeId == null) {
      if (mounted) setState(() => status = '请先等待验证请求');
      return;
    }
    await _action(() => action(activeId), text);
  }

  Future<void> _action(Future<void> Function() f, String text) async {
    try {
      await f();
      if (mounted) setState(() => status = text);
    } catch (_) {
      debugPrint('E2EE_VERIFICATION_ACTION_FAILED');
      if (mounted) setState(() => status = '验证操作失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.navigationBackground(context),
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
                _requestAction(service.accept, '已接受验证，请选择相同的 SAS 表情或数字')),
        const SizedBox(height: 10),
        ModernActionButton(
          icon: CupertinoIcons.number,
          label: '显示 SAS',
          onPressed: () => _requestAction(service.chooseSas, 'SAS 已发送，请与对方比对'),
        ),
        const SizedBox(height: 10),
        ModernActionButton(
          icon: CupertinoIcons.shield_lefthalf_fill,
          label: '确认匹配',
          onPressed: () => _requestAction(service.confirmSas, '验证完成，设备已信任'),
        ),
        const SizedBox(height: 10),
        ModernActionButton(
          icon: CupertinoIcons.xmark_shield,
          label: '拒绝',
          kind: ModernActionKind.danger,
          onPressed: () => _requestAction(service.reject, '已拒绝验证'),
        ),
      ])));
  @override
  void dispose() {
    unawaited(service.dispose().catchError((_) {
      debugPrint('E2EE_VERIFICATION_DISPOSE_FAILED');
    }));
    super.dispose();
  }
}
