import 'dart:typed_data';

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';

import '../../ui/components/wechat_scaffold.dart';
import '../../ui/components/user_avatar.dart';

import '../../ui/foundation/wechat_tokens.dart';
import '../../core/business_api_client.dart';
import '../../core/cache/cache_repository.dart';
import '../../ui/moments/wechat_moment_tile.dart';
import '../../ui/moments/wechat_moment_viewer.dart';
import 'moment_models.dart';
import 'moment_composer_page.dart';
import '../matrix/profile_repository.dart';

final class MomentsPage extends StatefulWidget {
  /// BUG 1：朋友圈不再自建资料缓存——必须注入全局唯一 ProfileRepository。
  const MomentsPage(
      {super.key, required this.api, required this.identityCache});
  final BusinessApiClient api;
  final ProfileRepository identityCache;
  @override
  State<MomentsPage> createState() => _MomentsPageState();
}

final class _MomentsPageState extends State<MomentsPage> {
  final _itemOverrides = <String, MomentItem>{};
  final _pendingLikeIds = <String>{};
  late Future<Map<String, dynamic>> _feed;
  String? _coverUrl;
  String? _interactionError;
  String? _identityError;
  late final ProfileRepository _identityCache = widget.identityCache;

  @override
  void initState() {
    super.initState();
    _identityCache.addListener(_identityChanged);
    _loadIdentity();
    _feed = _loadFeedWithCache();
    _loadPreferences();
  }

  Future<void> _loadIdentity() async {
    if (mounted) setState(() => _identityError = null);
    try {
      await _identityCache.preload();
    } catch (_) {
      if (mounted && _identityCache.profile == null) {
        setState(() => _identityError = '资料加载失败');
      }
    }
  }

  Future<void> _loadPreferences() async {
    try {
      final value = await widget.api.momentsPreferences();
      if (mounted) setState(() => _coverUrl = value['cover_url']?.toString());
    } catch (_) {
      if (mounted) setState(() => _interactionError = '封面加载失败，请重试');
    }
  }

  void _identityChanged() {
    if (mounted) setState(() {});
  }

  void _reloadFeed() {
    if (!mounted) return;
    setState(() {
      _itemOverrides.clear();
      _interactionError = null;
      _feed = _loadFeedWithCache();
    });
  }

  /// 朋友圈 Feed 加载（优化 3）：存在缓存时**立即用缓存首绘**，
  /// 同时后台刷新最新数据并落盘覆盖；无缓存时等待网络。
  Future<Map<String, dynamic>> _loadFeedWithCache() async {
    Map<String, dynamic>? cached;
    try {
      cached = await (await CacheRepository.instance()).moments.load();
    } catch (_) {
      cached = null; // 缓存不可用（如测试环境无插件通道）绝不阻塞加载
    }
    if (cached != null) {
      unawaited(_refreshFeedInBackground());
      return cached;
    }
    final fresh = await widget.api.momentsFeed(mode: 'latest');
    unawaited(_saveFeedCache(fresh));
    return fresh;
  }

  Future<void> _saveFeedCache(Map<String, dynamic> feed) async {
    try {
      await (await CacheRepository.instance()).moments.save(feed);
    } catch (_) {
      // 落盘失败不影响本次展示。
    }
  }

  Future<void> _refreshFeedInBackground() async {
    try {
      final fresh = await widget.api.momentsFeed(mode: 'latest');
      await _saveFeedCache(fresh);
      if (mounted) setState(() => _feed = Future.value(fresh));
    } catch (_) {
      // 后台刷新失败保持缓存首绘内容，不打断浏览。
    }
  }

  @override
  void dispose() {
    _identityCache.removeListener(_identityChanged);
    super.dispose();
  }

  Future<void> _toggleLike(MomentItem item) async {
    if (_pendingLikeIds.contains(item.id)) return;
    final optimistic = item.copyWith(
      liked: !item.liked,
      likeCount: item.liked
          ? (item.likeCount > 0 ? item.likeCount - 1 : 0)
          : item.likeCount + 1,
    );
    setState(() {
      _pendingLikeIds.add(item.id);
      _itemOverrides[item.id] = optimistic;
      _interactionError = null;
    });
    try {
      if (item.liked) {
        await widget.api.unlikeMoment(item.id);
      } else {
        await widget.api.likeMoment(item.id);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _itemOverrides[item.id] = item;
        _interactionError =
            error is BusinessApiException ? error.message : '点赞同步失败，请重试';
      });
    } finally {
      if (mounted) setState(() => _pendingLikeIds.remove(item.id));
    }
  }

  Future<void> _showComment(BuildContext context, MomentItem item) async {
    final controller = TextEditingController();
    await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
              builder: (dialogContext, setDialogState) {
                var submitting = false;
                String? errorMessage;
                return StatefulBuilder(
                  builder: (dialogContext, updateDialog) =>
                      CupertinoAlertDialog(
                    title: const Text('评论'),
                    content: Column(children: [
                      Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: CupertinoTextField(
                            key: const Key('moment-comment-input'),
                            controller: controller,
                            placeholder: '说点什么…',
                            onChanged: (_) => updateDialog(() {}),
                          )),
                      if (errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(errorMessage!,
                              style: const TextStyle(
                                  color: CupertinoColors.systemRed)),
                        ),
                    ]),
                    actions: [
                      CupertinoDialogAction(
                          onPressed: submitting
                              ? null
                              : () => Navigator.pop(dialogContext),
                          child: const Text('取消')),
                      CupertinoDialogAction(
                          key: const Key('moment-comment-submit'),
                          onPressed: submitting ||
                                  controller.text.trim().isEmpty
                              ? null
                              : () async {
                                  updateDialog(() {
                                    submitting = true;
                                    errorMessage = null;
                                  });
                                  try {
                                    final response = await widget.api
                                        .commentMoment(
                                            item.id, controller.text.trim());
                                    final comment =
                                        MomentCommentView.fromJson(response);
                                    if (mounted) {
                                      setState(() {
                                        final current =
                                            _itemOverrides[item.id] ?? item;
                                        _itemOverrides[item.id] =
                                            current.copyWith(comments: [
                                          ...current.comments,
                                          comment,
                                        ]);
                                      });
                                    }
                                    if (dialogContext.mounted) {
                                      Navigator.pop(dialogContext);
                                    }
                                  } catch (error) {
                                    if (!dialogContext.mounted) return;
                                    updateDialog(() {
                                      submitting = false;
                                      errorMessage =
                                          error is BusinessApiException
                                              ? error.message
                                              : '评论提交失败，请重试';
                                    });
                                  }
                                },
                          child: submitting
                              ? const CupertinoActivityIndicator()
                              : const Text('发送'))
                    ],
                  ),
                );
              },
            ));
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            backgroundColor: WeChatColors.chatNavigationBackground,
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: const Text('朋友圈'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => Navigator.push(
                      context,
                      CupertinoPageRoute(
                          builder: (_) =>
                              MomentsSettingsPage(api: widget.api))),
                  child: const Icon(CupertinoIcons.settings)),
              CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () async {
                    final didPublish = await Navigator.push<bool>(
                      context,
                      CupertinoPageRoute(
                        builder: (_) => MomentComposerPage(api: widget.api),
                      ),
                    );
                    if (didPublish == true) _reloadFeed();
                  },
                  child: const Icon(CupertinoIcons.camera))
            ])),
        child: SafeArea(
            child: FutureBuilder<Map<String, dynamic>>(
                future: _feed,
                builder: (_, snapshot) {
                  final items = (snapshot.data?['items'] as List?) ?? const [];
                  return ListView(children: [
                    if (_interactionError != null)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _interactionError!,
                          key: const Key('moment-interaction-error'),
                          style:
                              const TextStyle(color: CupertinoColors.systemRed),
                        ),
                      ),
                    GestureDetector(
                        key: const Key('moment-cover-header'),
                        onTap: _openCover,
                        child: Container(
                            height: 200,
                            decoration: BoxDecoration(
                                color: const Color(0xff4c4c4c),
                                image: _coverUrl == null
                                    ? null
                                    : DecorationImage(
                                        image: NetworkImage(_coverUrl!),
                                        fit: BoxFit.cover,
                                        onError: (_, __) {})),
                            alignment: Alignment.bottomRight,
                            padding: const EdgeInsets.all(16),
                            child: _ownerIdentity())),
                    for (final m in items)
                      Builder(builder: (_) {
                        final parsed = MomentItem.fromJson(
                            Map<String, dynamic>.from(m as Map));
                        final item = _itemOverrides[parsed.id] ?? parsed;
                        return WeChatMomentTile(
                          item: item,
                          onLike: _pendingLikeIds.contains(item.id)
                              ? null
                              : () => _toggleLike(item),
                          onComment: () => _showComment(context, item),
                        );
                      }),
                  ]);
                })),
      );

  Widget _ownerIdentity() {
    final profile = _identityCache.profile;
    if (profile == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Icon(
            CupertinoIcons.person_crop_circle,
            key: Key('moment-owner-loading-fallback'),
            color: CupertinoColors.white,
            size: 64,
          ),
          if (_identityError != null)
            CupertinoButton(
              key: const Key('moment-owner-retry'),
              padding: const EdgeInsets.only(top: 4),
              onPressed: _loadIdentity,
              child: Text(
                _identityError!,
                style: const TextStyle(color: CupertinoColors.white),
              ),
            ),
        ],
      );
    }
    final nickname = profile.nickname.trim().isEmpty
        ? profile.username.trim()
        : profile.nickname.trim();
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            nickname,
            key: const Key('moment-owner-nickname'),
            style: const TextStyle(
              color: CupertinoColors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: CupertinoColors.white, width: 2),
            borderRadius: BorderRadius.circular(6),
          ),
          child: UserAvatar(
            key: const Key('moment-owner-avatar'),
            nickname: nickname,
            fallbackSeed: profile.fallbackSeed,
            avatarUrl: profile.avatarUrl,
            diagnosticSource: 'moments-owner',
            size: 64,
          ),
        ),
      ],
    );
  }

  void _openCover() {
    Navigator.push(
      context,
      CupertinoPageRoute(
        builder: (_) => WeChatMomentCoverViewer(
          url: _coverUrl,
          onChangeCover: _changeCover,
        ),
      ),
    );
  }

  Future<String?> _changeCover(ValueChanged<Uint8List> onPreview) async {
    final image = await ImagePicker()
        .pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (image == null) return null;
    final bytes = await image.readAsBytes();
    onPreview(bytes);
    final extension = image.name.toLowerCase().split('.').last;
    final mimeType = extension == 'png'
        ? 'image/png'
        : extension == 'webp'
            ? 'image/webp'
            : 'image/jpeg';
    final begun = await widget.api.beginMomentCoverUpload(
        fileName: image.name, mimeType: mimeType, byteSize: bytes.length);
    final uploadId = begun['id'].toString();
    await widget.api.putMomentCoverUpload(uploadId, bytes, mimeType);
    await widget.api.completeMomentCoverUpload(uploadId);
    final saved = await widget.api.setMomentCover(uploadId);
    final coverUrl = saved['cover_url']?.toString();
    if (mounted) {
      setState(() => _coverUrl = coverUrl);
    }
    return coverUrl;
  }
}

final class MomentsSettingsPage extends StatefulWidget {
  const MomentsSettingsPage({super.key, required this.api});
  final BusinessApiClient api;
  @override
  State<MomentsSettingsPage> createState() => _MomentsSettingsState();
}

final class _MomentsSettingsState extends State<MomentsSettingsPage> {
  String range = 'ALL';
  bool personalized = true;
  @override
  void initState() {
    super.initState();
    widget.api.momentsPreferences().then((r) {
      if (mounted) {
        setState(() {
          range = r['history_range'];
          personalized = r['personalized_recommendations'];
        });
      }
    });
  }

  Future<void> save() async {
    await widget.api.updateMomentsPreferences(
        historyRange: range, personalized: personalized);
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: Text('朋友圈权限')),
      child: SafeArea(
          child: ListView(children: [
        CupertinoListSection.insetGrouped(
            header: const Text('允许朋友查看朋友圈的范围'),
            children: [
              for (final item in const {
                'ALL': '全部',
                'SIX_MONTHS': '最近半年',
                'ONE_MONTH': '最近一个月',
                'THREE_DAYS': '最近三天'
              }.entries)
                CupertinoListTile(
                    title: Text(item.value),
                    trailing: range == item.key
                        ? const Icon(CupertinoIcons.check_mark,
                            color: Color(0xff07c160))
                        : null,
                    onTap: () {
                      setState(() => range = item.key);
                      save();
                    })
            ]),
        CupertinoListSection.insetGrouped(children: [
          CupertinoListTile(
              title: const Text('个性化推荐'),
              trailing: CupertinoSwitch(
                  value: personalized,
                  onChanged: (v) {
                    setState(() => personalized = v);
                    save();
                  }))
        ])
      ])));
}
