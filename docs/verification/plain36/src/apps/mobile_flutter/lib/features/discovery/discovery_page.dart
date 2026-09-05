import 'package:flutter/cupertino.dart';
import '../contacts/scan_qr_page.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/components/wechat_nav_title.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../moments/moments_page.dart';
import '../matrix/profile_repository.dart';
import '../matrix/matrix_e2ee_client.dart';
import '../search/global_search_page.dart';

final class DiscoveryPage extends StatelessWidget {
  const DiscoveryPage(
      {super.key, required this.api, this.matrix, this.identityCache});

  final BusinessApiClient api;
  final MatrixSdkE2eeClient? matrix;
  final ProfileRepository? identityCache;

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        backgroundColor: WeChatColors.tabRootPageBackground,
        navigationBar: CupertinoNavigationBar(
            backgroundColor: WeChatColors.chatNavigationBackground,
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            transitionBetweenRoutes: false,
            middle: const WeChatNavTitle('发现'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              CupertinoButton(
                key: const Key('discovery-search'),
                padding: EdgeInsets.zero,
                onPressed: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                      builder: (_) =>
                          GlobalSearchPage(api: api, matrix: matrix)),
                ),
                child: const Icon(CupertinoIcons.search, size: 22),
              ),
              CupertinoButton(
                key: const Key('discovery-more'),
                padding: EdgeInsets.zero,
                onPressed: () => showCupertinoModalPopup<void>(
                  context: context,
                  builder: (sheetContext) => CupertinoActionSheet(
                    actions: [
                      CupertinoActionSheetAction(
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          final cache = identityCache;
                          if (cache == null) return;
                          Navigator.of(context, rootNavigator: true).push(
                            CupertinoPageRoute(
                                fullscreenDialog: true,
                                builder: (_) => MomentsPage(
                                      api: api,
                                      identityCache: cache,
                                    )),
                          );
                        },
                        child: const Text('朋友圈'),
                      ),
                    ],
                    cancelButton: CupertinoActionSheetAction(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Text('取消'),
                    ),
                  ),
                ),
                child: const Icon(CupertinoIcons.ellipsis_circle, size: 22),
              ),
            ])),
        child: SafeArea(
          child: ListView(
            key: const Key('discovery-home-list'),
            padding: EdgeInsets.zero,
            children: [
              WeChatListTile(
                key: const Key('discovery-scan-entry'),
                leading: const SizedBox(
                  width: 40,
                  child: Icon(CupertinoIcons.qrcode_viewfinder, size: 21),
                ),
                title: const Text('扫一扫'),
                subtitle: const Text(
                  '扫描好友二维码，添加朋友',
                  style: TextStyle(
                      fontSize: 12, color: WeChatColors.textSecondary),
                ),
                trailing: const Icon(CupertinoIcons.chevron_right, size: 12),
                onTap: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                    fullscreenDialog: true,
                    builder: (_) => ScanQrPage(
                      api: api,
                      groupJoinApi: api,
                      // 发现页扫码入群：加入后返回消息列表可见新会话，
                      // 不做自动跳转（保持发现页轻量）。
                    ),
                  ),
                ),
              ),
              WeChatListTile(
                leading: const SizedBox(
                  width: 40,
                  child: Icon(CupertinoIcons.photo_on_rectangle, size: 21),
                ),
                title: const Text('朋友圈'),
                subtitle: const Text(
                  '查看好友动态',
                  style: TextStyle(
                    fontSize: 12,
                    color: WeChatColors.textSecondary,
                  ),
                ),
                trailing: const Icon(CupertinoIcons.chevron_right, size: 12),
                onTap: () {
                  final cache = identityCache;
                  if (cache == null) return;
                  Navigator.of(context, rootNavigator: true).push(
                    CupertinoPageRoute(
                      fullscreenDialog: true,
                      builder: (_) => MomentsPage(
                        api: api,
                        identityCache: cache,
                      ),
                    ),
                  );
                },
              ),
              WeChatListTile(
                leading: const SizedBox(
                  width: 40,
                  child: Icon(ChangliaoIcons.discover, size: 21),
                ),
                title: const Text('推荐内容'),
                subtitle: const Text(
                  '公开内容会明确标记推荐来源',
                  style: TextStyle(
                    fontSize: 12,
                    color: WeChatColors.textSecondary,
                  ),
                ),
                trailing: const Icon(CupertinoIcons.chevron_right, size: 12),
                onTap: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                    builder: (_) => const _RecommendedContentPage(),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

final class _RecommendedContentPage extends StatelessWidget {
  const _RecommendedContentPage();

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: const CupertinoNavigationBar(
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text('推荐内容')),
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(ChangliaoIcons.discover, size: 48),
                SizedBox(height: 12),
                Text('暂无推荐内容'),
                SizedBox(height: 8),
                Text(
                  '公开内容会明确标记推荐来源',
                  style: TextStyle(color: WeChatColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      );
}
