import 'package:flutter/cupertino.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'matrix_e2ee_client.dart';
import 'matrix_recovery_vault.dart';

final class MatrixSecurityPage extends StatelessWidget {
  const MatrixSecurityPage({super.key, required this.matrix});
  final MatrixSdkE2eeClient matrix;

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            backgroundColor: WeChatColors.navigationBackground(context),
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: const Text('聊天记录同步')),
        child: SafeArea(
            child: ListenableBuilder(
                listenable: matrix.historySyncStatus,
                builder: (context, _) {
                  final status = matrix.historySyncStatus;
                  final message = switch (status.phase) {
                    VaultSyncPhase.downloading => '正在恢复聊天记录',
                    VaultSyncPhase.ready => '已恢复可用记录',
                    VaultSyncPhase.partial => '部分旧记录缺少历史密钥',
                    VaultSyncPhase.retrying => '网络暂不可用，稍后自动重试',
                    VaultSyncPhase.unavailable => '恢复服务暂不可用，稍后自动重试',
                    VaultSyncPhase.revoked => '已退出当前账号，同步已停止',
                  };
                  return ListView(
                      padding: const EdgeInsets.all(WeChatSpacing.md),
                      children: [
                        Text(message),
                        const SizedBox(height: WeChatSpacing.md),
                        const Text('登录后自动同步最近 72 小时可访问的聊天记录。没有备份的旧密钥无法重建。',
                            style: TextStyle(
                                color: WeChatColors.textSecondary,
                                fontSize: WeChatTypography.subhead)),
                        CupertinoListSection.insetGrouped(children: [
                          for (final row in [
                            ('已下载密文', status.downloaded),
                            ('已托管密钥', status.protected),
                            ('已解密记录', status.decrypted),
                            ('缺少密钥', status.missing)
                          ])
                            CupertinoListTile(
                                title: Text(row.$1),
                                additionalInfo: Text(
                                    status.phase == VaultSyncPhase.revoked
                                        ? '—'
                                        : '${row.$2}')),
                        ]),
                        const Text('恢复材料由服务器加密托管，消息在设备上解密。',
                            style: TextStyle(
                                color: WeChatColors.textSecondary,
                                fontSize: WeChatTypography.subhead)),
                        if ({
                          VaultSyncPhase.partial,
                          VaultSyncPhase.retrying,
                          VaultSyncPhase.unavailable
                        }.contains(status.phase))
                          CupertinoButton(
                              onPressed: matrix.retryHistorySync,
                              child: const Text('重试同步')),
                      ]);
                })),
      );
}
