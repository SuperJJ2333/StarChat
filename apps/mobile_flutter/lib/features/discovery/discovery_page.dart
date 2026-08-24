import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../moments/moments_page.dart';
import '../matrix/chat_identity_cache.dart';
import '../search/global_search_page.dart';

final class DiscoveryPage extends StatelessWidget {
  const DiscoveryPage({super.key, required this.api, this.identityCache});

  final BusinessApiClient api;
  final ChatIdentityCache? identityCache;

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        backgroundColor: WeChatColors.tabRootPageBackground,
        navigationBar: CupertinoNavigationBar(
            backgroundColor: WeChatColors.chatNavigationBackground,
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: const Text('发现'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              CupertinoButton(
                key: const Key('discovery-search'),
                padding: EdgeInsets.zero,
                onPressed: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                      builder: (_) => GlobalSearchPage(api: api)),
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
                          Navigator.push(
                            context,
                            CupertinoPageRoute(
                                builder: (_) => MomentsPage(
                                      api: api,
                                      identityCache: identityCache,
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
                onTap: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                    builder: (_) => MomentsPage(
                      api: api,
                      identityCache: identityCache,
                    ),
                  ),
                ),
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
  Widget build(BuildContext context) => const WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            backgroundColor: WeChatColors.chatNavigationBackground,
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
