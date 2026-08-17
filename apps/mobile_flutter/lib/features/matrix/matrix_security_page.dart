import 'package:flutter/cupertino.dart';
import 'matrix_e2ee_client.dart';
import 'matrix_verification_page.dart';

final class MatrixSecurityPage extends StatefulWidget {
  const MatrixSecurityPage({super.key, required this.matrix});
  final MatrixSdkE2eeClient matrix;
  @override
  State<MatrixSecurityPage> createState() => _MatrixSecurityPageState();
}

final class _MatrixSecurityPageState extends State<MatrixSecurityPage> {
  final recovery = TextEditingController();
  bool busy = false;
  String? message;
  @override
  void dispose() {
    recovery.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() fn, String ok) async {
    setState(() => busy = true);
    try {
      await fn();
      if (mounted) setState(() => message = ok);
    } catch (e) {
      if (mounted) setState(() => message = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('设备安全')),
      child: SafeArea(
          child: ListView(padding: const EdgeInsets.all(16), children: [
        CupertinoListSection.insetGrouped(
            header: const Text('设备验证'),
            children: [
              CupertinoListTile(
                  leading: const Icon(CupertinoIcons.checkmark_seal),
                  title: const Text('SAS 交互式验证'),
                  onTap: () => Navigator.of(context).push(CupertinoPageRoute(
                      builder: (_) =>
                          MatrixVerificationPage(matrix: widget.matrix))))
            ]),
        CupertinoListSection.insetGrouped(
            header: const Text('加密备份'),
            children: [
              CupertinoTextField(
                  controller: recovery,
                  placeholder: '粘贴恢复密钥',
                  obscureText: true,
                  padding: const EdgeInsets.all(14)),
              CupertinoListTile(
                  title: const Text('创建并缓存加密备份'),
                  trailing: CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: busy
                          ? null
                          : () => run(() async {
                                await widget.matrix
                                    .backupKeysToEncryptedStore();
                              }, '备份已加密并保存在设备'),
                      child: const Text('创建'))),
              CupertinoListTile(
                  title: const Text('恢复加密备份'),
                  trailing: CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: busy
                          ? null
                          : () => run(
                              () => widget.matrix.restoreEncryptedBackup(
                                  recoveryKey: recovery.text.trim()),
                              '备份恢复完成'),
                      child: const Text('恢复')))
            ]),
        if (message != null)
          Padding(padding: const EdgeInsets.all(16), child: Text(message!))
      ])),
    );
  }
}
