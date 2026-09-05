import 'package:flutter/cupertino.dart';

import '../../core/app_config.dart';
import '../../core/business_api_client.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../update/app_update.dart';
import '../update/app_update_dialog.dart';
import 'complaint_page.dart';

/// 「关于畅聊」入口页：品牌信息 + 当前版本行。
/// 点击当前版本号进入「关于」页，提供投诉与版本更新。
final class AboutChangliaoPage extends StatelessWidget {
  const AboutChangliaoPage({super.key, required this.api});

  final BusinessApiClient api;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: const Text('关于畅聊'),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            const SizedBox(height: 40),
            Center(
              child: Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: WeChatColors.brandPrimary,
                  borderRadius: BorderRadius.circular(22),
                ),
                alignment: Alignment.center,
                child: const Text(
                  '畅',
                  style: TextStyle(
                    color: CupertinoColors.white,
                    fontSize: 44,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Center(
              child: Text(
                '畅聊 ChatFlow',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 48),
            CupertinoListSection.insetGrouped(
              margin: EdgeInsets.zero,
              children: [
                CupertinoListTile(
                  key: const Key('about-version-row'),
                  title: const Text('当前版本'),
                  additionalInfo: Text('V${AppConfig.appVersionName}'),
                  trailing: const CupertinoListTileChevron(),
                  onTap: () => Navigator.push(
                    context,
                    CupertinoPageRoute(
                      builder: (_) => AboutDetailPage(api: api),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Center(
              child: Text(
                dark ? '' : '畅聊 ChatFlow · 端到端加密的可信沟通平台',
                style: const TextStyle(
                  fontSize: 12,
                  color: WeChatColors.textTertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「关于」详情页：投诉与版本更新（微信"关于微信"风格）。
final class AboutDetailPage extends StatefulWidget {
  const AboutDetailPage({super.key, required this.api});

  final BusinessApiClient api;

  @override
  State<AboutDetailPage> createState() => _AboutDetailPageState();
}

final class _AboutDetailPageState extends State<AboutDetailPage> {
  bool checking = false;

  Future<void> _checkUpdate() async {
    if (checking) return;
    setState(() => checking = true);
    AppUpdateInfo? info;
    try {
      info = parseAppUpdate(await widget.api.latestAppUpdate());
    } catch (_) {
      info = null;
    }
    if (!mounted) return;
    final pending = resolvePendingUpdate(
      info: info,
      currentBuild: AppConfig.appBuildNumber,
      currentVersion: AppConfig.appVersionName,
    );
    if (pending != null) {
      await showAppUpdateDialog(
        context,
        info: pending,
        currentBuild: AppConfig.appBuildNumber,
      );
      return;
    }
    await showCupertinoDialog<void>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        key: const Key('about-up-to-date-dialog'),
        title: const Text('当前已是最新版本'),
        content: Text('畅聊 V${AppConfig.appVersionName} 已是最新版本'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    if (mounted) setState(() => checking = false);
  }

  Future<void> _openComplaint() async {
    await Navigator.push(
      context,
      CupertinoPageRoute(builder: (_) => ComplaintPage(api: widget.api)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: const Text('关于'),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            const SizedBox(height: 32),
            Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: WeChatColors.brandPrimary,
                  borderRadius: BorderRadius.circular(18),
                ),
                alignment: Alignment.center,
                child: const Text(
                  '畅',
                  style: TextStyle(
                    color: CupertinoColors.white,
                    fontSize: 38,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            const Center(
              child: Text(
                '畅聊 ChatFlow',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                'V${AppConfig.appVersionName} (Build ${AppConfig.appBuildNumber})',
                style: const TextStyle(
                  fontSize: 12,
                  color: WeChatColors.textTertiary,
                ),
              ),
            ),
            const SizedBox(height: 28),
            CupertinoListSection.insetGrouped(
              margin: EdgeInsets.zero,
              children: [
                CupertinoListTile(
                  key: const Key('about-complaint-row'),
                  title: const Text('投诉'),
                  trailing: const CupertinoListTileChevron(),
                  onTap: _openComplaint,
                ),
                CupertinoListTile(
                  key: const Key('about-check-update-row'),
                  title: const Text('版本更新'),
                  trailing: checking
                      ? const CupertinoActivityIndicator()
                      : const CupertinoListTileChevron(),
                  onTap: checking ? null : _checkUpdate,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
