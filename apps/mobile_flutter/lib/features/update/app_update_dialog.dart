import 'package:flutter/cupertino.dart';

import 'app_update.dart';
import 'android_delta_update.dart';

/// 版本更新弹窗。
///
/// - 可忽略更新：更新说明 + 「更新」 + 「稍后再说」，用户可自由关闭。
/// - 强制更新：只有「立即更新」，屏障不可点击、路由不可返回；尝试退出时
///   弹窗持续存在，直到更新完成。
Future<void> showAppUpdateDialog(
  BuildContext context, {
  required AppUpdateInfo info,
  required int currentBuild,
  Future<void> Function(String url) launchExternal = launchAppDownload,
  VoidCallback? onDeferred,
}) {
  final forced = requiresForcedUpdate(info, currentBuild);
  var working = false;
  var permissionRequired = false;
  var statusText = '';
  final dialog = showCupertinoDialog<void>(
    context: context,
    barrierDismissible: !forced,
    routeSettings:
        RouteSettings(name: forced ? 'app-update/forced' : 'app-update'),
    builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => PopScope(
              canPop: !forced,
              child: CupertinoAlertDialog(
                key: Key(
                    forced ? 'app-update-forced-dialog' : 'app-update-dialog'),
                title: Text('发现新版本 ${info.latestVersion}'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  const SizedBox(height: 6),
                  Text(info.notes),
                  if (statusText.isNotEmpty) Text(statusText),
                  const SizedBox(height: 6),
                  if (forced)
                    const Text(
                      '当前版本过旧，必须更新后才能继续使用',
                      style: TextStyle(
                          fontSize: 12, color: CupertinoColors.systemRed),
                    ),
                ]),
                actions: [
                  if (!forced)
                    CupertinoDialogAction(
                      key: const Key('app-update-defer'),
                      onPressed: () {
                        if (working) AndroidDeltaUpdater.cancel();
                        Navigator.of(dialogContext).pop();
                        onDeferred?.call();
                      },
                      child: const Text('稍后再说'),
                    ),
                  CupertinoDialogAction(
                    key: const Key('app-update-now'),
                    isDefaultAction: true,
                    onPressed: working
                        ? null
                        : () async {
                            if (permissionRequired) {
                              await AndroidDeltaUpdater.requestPermission();
                              if (dialogContext.mounted) {
                                setState(() {
                                  permissionRequired = false;
                                  statusText = '授权后点击更新继续安装';
                                });
                              }
                              return;
                            }
                            setState(() {
                              working = true;
                              statusText = info.androidDelta == null
                                  ? ''
                                  : '正在准备更新…';
                            });
                            try {
                              final outcome = await launchAppUpdate(info,
                                  launchExternal: launchExternal);
                              if (!dialogContext.mounted) return;
                              setState(() {
                                permissionRequired = outcome ==
                                    DeltaUpdateOutcome.permissionRequired;
                                statusText =
                                    permissionRequired ? '需要允许本应用安装更新' : '';
                              });
                            } finally {
                              if (dialogContext.mounted) {
                                setState(() => working = false);
                              }
                            }
                          },
                    child: Text(permissionRequired
                        ? '允许安装更新'
                        : working
                            ? '准备更新中…'
                            : forced
                                ? '立即更新'
                                : '更新'),
                  ),
                  if (info.androidDelta != null)
                    CupertinoDialogAction(
                      onPressed: () async {
                        await AndroidDeltaUpdater.cancel();
                        await launchExternal(info.downloadUrl);
                      },
                      child: const Text('下载完整安装包'),
                    ),
                ],
              ),
            )),
  );
  return info.androidDelta == null
      ? dialog
      : dialog.whenComplete(AndroidDeltaUpdater.cancel);
}
