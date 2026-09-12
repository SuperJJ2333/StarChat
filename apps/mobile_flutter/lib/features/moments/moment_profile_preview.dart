import '../contacts/contact_actions.dart';
import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../matrix/profile_repository.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../../ui/moments/moment_image_provider.dart';
import 'moment_models.dart';
import 'moment_preview_cache.dart';
import 'personal_moments_page.dart';
import 'moments_privacy_changes.dart';

/// Only server-authorized previews may render a profile entrance.
class MomentProfilePreview extends StatefulWidget {
  const MomentProfilePreview(
      {super.key,
      required this.api,
      this.identityCache,
    this.contactActions,
    required this.userId,
      required this.displayName,
      this.refreshRevision = 0});
  final BusinessApiClient api;
  final ContactActions? contactActions;
  final ProfileRepository? identityCache;
  final String userId, displayName;
  final int refreshRevision;
  @override
  State<MomentProfilePreview> createState() => _MomentProfilePreviewState();
}

class _MomentProfilePreviewState extends State<MomentProfilePreview> {
  Map<String, dynamic>? _cached;

  static MomentPreviewCache get _cache => MomentPreviewCache.instance;

  @override
  void initState() {
    super.initState();
    momentsPrivacyChanges.addListener(_refresh);
    _cache.addListener(widget.userId, _onCacheChanged);
    // 无感加载：先渲染缓存（若有）；TTL 过期才后台刷新，
    // 有更新才回调重建 —— 进页不再强制刷新。
    _cached = _cache.peek(widget.userId);
    _cache.ensureFresh(widget.userId);
  }

  @override
  void dispose() {
    momentsPrivacyChanges.removeListener(_refresh);
    _cache.removeListener(widget.userId, _onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (!mounted) return;
    final latest = _cache.peek(widget.userId);
    // 仅内容变化才 setState（时间戳续期不触发）。
    if (latest != null && latest != _cached) {
      setState(() => _cached = latest);
    }
  }

  void _refresh() {
    _cache.invalidate(widget.userId);
    _cached = null;
    _cache.ensureFresh(widget.userId);
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant MomentProfilePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId ||
        oldWidget.api != widget.api ||
        oldWidget.refreshRevision != widget.refreshRevision) {
      _cache.removeListener(oldWidget.userId, _onCacheChanged);
      _cached = _cache.peek(widget.userId);
      _cache.addListener(widget.userId, _onCacheChanged);
      _cache.ensureFresh(widget.userId);
    }
  }

  @override
  Widget build(BuildContext context) {
    // No persisted permission grants: errors, missing flags and denied users hide it.
    if (_cached == null || _cached!['entry_visible'] != true) {
      return const SizedBox.shrink();
    }
    final snapshotData = _cached!;
    {
      final items = (snapshotData['items'] as List? ?? [])
          .map((e) => MomentItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
          final pictures = <({String url, String? key})>[
            for (final item in items)
              for (var i = 0; i < item.images.length; i++)
                (
                  url: item.images[i],
                  key: momentImageKey(item.imageCacheKeys, i)
                ),
          ].take(3).toList();
          final summary = items
                  .where((e) => e.text.trim().isNotEmpty)
                  .map((e) => e.text)
                  .firstOrNull ??
              '暂无动态';
          return Padding(
              padding: const EdgeInsets.only(top: 12),
              child: CupertinoButton(
                key: const Key('friend-moments-section'),
                padding: EdgeInsets.zero,
                onPressed: () async {
                  await Navigator.push(
                      context,
                      CupertinoPageRoute(
                          builder: (_) => PersonalMomentsPage(
                      contactActions: widget.contactActions,
                      identityCache: widget.identityCache,
                              api: widget.api,
                              userId: widget.userId,
                              displayName: widget.displayName,
                              initialItems: items)));
                  if (mounted) {
                    // 返回后后台刷新一次（发布/删除会让缓存失效）。
                    _cached = _cache.peek(widget.userId);
                    _cache.ensureFresh(widget.userId);
                  }
                },
                child: Container(
                  color: WeChatColors.elevatedSurface(context),
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Text('朋友圈',
                        style: TextStyle(
                            fontSize: 16,
                            color: WeChatColors.resolveTextPrimary(context))),
                    const SizedBox(width: 20),
                    Expanded(
                        child: pictures.isEmpty
                            ? Text(summary,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 14,
                                    color: WeChatColors.textSecondary))
                            : Row(children: [
                                for (final picture in pictures)
                                  Padding(
                                      padding: const EdgeInsets.only(right: 4),
                                      child: Image(
                                        image: momentImageProvider(
                                            picture.url,
                                            picture.key,
                                            'profile:${widget.userId}'),
                                        width: 60,
                                        height: 60,
                                        fit: BoxFit.cover,
                                        gaplessPlayback: true,
                                        errorBuilder: (_, __, ___) =>
                                            const SizedBox(
                                                width: 60,
                                                height: 60,
                                                child:
                                                    Icon(CupertinoIcons.photo)),
                                      ))
                              ])),
                    const CupertinoListTileChevron(),
                  ]),
                ),
              ));
    }
  }
}
