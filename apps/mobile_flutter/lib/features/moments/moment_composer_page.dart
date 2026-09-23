import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../matrix/profile_repository.dart';
import '../matrix/image_picker_page.dart';
import 'moment_comment_composer.dart'
    show MomentGallerySelection, MomentGalleryPicker;
import 'moment_visibility_page.dart';
import 'moment_draft_store.dart';
import 'moment_image_preprocessor.dart';
import '../../ui/motion/motion_page_route.dart';

final class MomentComposerPage extends StatefulWidget {
  const MomentComposerPage({
    super.key,
    required this.api,
    this.initialImages = const [],
    this.imagePreprocessor,
    this.identityCache,
    this.galleryPicker,
  });

  final BusinessApiClient api;
  final MomentGalleryPicker? galleryPicker;
  final List<XFile> initialImages;

  /// 可注入的图片压缩管线（缺省为原生 JPEG 压缩实现）。
  final MomentImagePreprocessor? imagePreprocessor;

  /// 本地联系人投影：透传给可见范围名单页做首帧渲染。
  final ProfileRepository? identityCache;

  @override
  State<MomentComposerPage> createState() => _MomentComposerPageState();
}

final class _MomentComposerPageState extends State<MomentComposerPage> {
  final text = TextEditingController();
  final images = <XFile>[];
  final remoteImageUrls = <String>[];
  final remoteVideoUrls = <String>[];
  final _previews = <XFile, Uint8List>{};
  int get _mediaCount =>
      images.length + remoteImageUrls.length + remoteVideoUrls.length;
  MomentVisibilitySelection visibility =
      const MomentVisibilitySelection.public();
  String? linkUrl;
  String? errorMessage;
  bool saving = false;
  bool _selecting = false;
  bool get busy => saving || _selecting;
  bool _allowPop = false;
  bool _draftSaved = false;
  bool _published = false;
  String? _publishKey, _publishPayload;

  bool get dirty =>
      text.text.trim().isNotEmpty ||
      images.isNotEmpty ||
      remoteImageUrls.isNotEmpty ||
      remoteVideoUrls.isNotEmpty ||
      linkUrl != null ||
      visibility.visibility != 'PUBLIC' ||
      visibility.selectedCount > 0;

  @override
  void initState() {
    super.initState();
    images.addAll(widget.initialImages.take(9));
    // 本地优先：先用本地草稿渲染，再与服务端对齐。
    unawaited(_hydrateLocalDraft());
    _loadDraft();
  }

  /// 本地草稿（账号作用域）：断网也能接着上次写；跨账号一律丢弃。
  Future<void> _hydrateLocalDraft() async {
    final store = MomentDraftStores.shared;
    final snapshot = store?.read();
    if (snapshot == null || mounted == false) return;
    String? scope;
    try {
      final userId = await widget.api.currentMatrixUserId();
      scope = userId == null || userId.isEmpty ? null : 'matrix:$userId';
    } catch (_) {
      scope = null;
    }
    if (scope == null || scope != snapshot.scope) {
      unawaited(store?.clear());
      return;
    }
    if (!mounted) return;
    setState(() => _applyDraft(snapshot.payload));
  }

  void _applyDraft(Map<String, dynamic> draft) {
    final mode = draft['visibility']?.toString() ?? 'PUBLIC';
    final users = Set<String>.from(
      mode == 'EXCLUDE'
          ? draft['exclude_user_ids'] ?? const []
          : draft['include_user_ids'] ?? const [],
    );
    final tags = Set<String>.from(
      mode == 'EXCLUDE'
          ? draft['exclude_tag_ids'] ?? const []
          : draft['include_tag_ids'] ?? const [],
    );
    text.text = draft['text']?.toString() ?? '';
    linkUrl = draft['link_url']?.toString();
    remoteImageUrls
      ..clear()
      ..addAll(
        (draft['image_urls'] as List? ?? const [])
            .map((value) => value.toString())
            .where((value) => value.trim().isNotEmpty)
            .take(9 - images.length),
      );
    remoteVideoUrls
      ..clear()
      ..addAll((draft['video_urls'] as List? ?? const [])
          .map((v) => v.toString())
          .where((v) => v.isNotEmpty)
          .take(9 - images.length - remoteImageUrls.length));
    visibility = MomentVisibilitySelection(
      visibility: mode,
      userIds: users,
      tagIds: tags,
    );
  }

  Future<void> _loadDraft() async {
    try {
      final draft = await widget.api.momentDraft();
      if (!mounted) return;
      // 服务端草稿优先（本地草稿只是离线兜底）。
      setState(() => _applyDraft(draft));
      unawaited(_persistLocalDraft());
    } on BusinessApiException catch (error) {
      if (!mounted || error.code == 'MOMENT_DRAFT_NOT_FOUND') return;
      setState(() => errorMessage = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => errorMessage = '草稿加载失败，可继续编辑并稍后重试');
    }
  }

  Future<void> _persistLocalDraft() async {
    final store = MomentDraftStores.shared;
    if (store == null) return;
    try {
      final userId = await widget.api.currentMatrixUserId();
      if (userId == null || userId.isEmpty) return;
      await store.write(MomentDraftSnapshot(
        scope: 'matrix:$userId',
        payload: _payload(),
        savedAt: DateTime.now(),
      ));
    } catch (_) {
      // 本地草稿写失败不是保存失败。
    }
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Map<String, dynamic> _payload() => {
        'text': text.text,
        'visibility': visibility.visibility,
        'image_urls': remoteImageUrls.toList(growable: false),
        if (remoteVideoUrls.isNotEmpty)
          'video_urls': remoteVideoUrls.toList(growable: false),
        'link_url': linkUrl,
        'include_user_ids': visibility.visibility == 'INCLUDE'
            ? visibility.userIds.toList()
            : const [],
        'include_tag_ids': visibility.visibility == 'INCLUDE'
            ? visibility.tagIds.toList()
            : const [],
        'exclude_user_ids': visibility.visibility == 'EXCLUDE'
            ? visibility.userIds.toList()
            : const [],
        'exclude_tag_ids': visibility.visibility == 'EXCLUDE'
            ? visibility.tagIds.toList()
            : const [],
      };

  Future<void> _saveDraft() async {
    await _uploadPendingImages();
    // 先落本地：断网/服务端拒绝时草稿也不丢（微信级加载模型 L1）。
    await _persistLocalDraft();
    await widget.api.saveMomentDraft(_payload());
  }

  String _jpegFileName(String original) {
    final base = original.replaceAll(RegExp(r'\.[^.]+$'), '');
    final safe = base.isEmpty ? 'moment' : base;
    return '$safe.jpg';
  }

  Future<List<String>> _uploadPendingImages() async {
    final preprocessor = widget.imagePreprocessor ?? MomentImagePreprocessor();
    while (images.isNotEmpty) {
      final image = images.first;
      final videoMime = momentVideoMime(image);
      final Uint8List bytes;
      try {
        if (videoMime != null && await image.length() > 20 * 1024 * 1024) {
          throw const MomentImageException('视频大小不能超过20MB');
        }
        bytes = await image.readAsBytes();
      } on MomentImageException {
        rethrow;
      } catch (_) {
        throw const MomentImageException('读取媒体失败，请重新选择');
      }
      if (videoMime != null &&
          (bytes.isEmpty || bytes.length > 20 * 1024 * 1024)) {
        throw const MomentImageException('视频大小不能超过20MB');
      }
      final processed =
          videoMime == null ? await preprocessor.process(bytes) : bytes;
      final mimeType = videoMime ?? 'image/jpeg';
      final begun = await widget.api.beginMomentUpload(
        fileName: videoMime == null ? _jpegFileName(image.name) : image.name,
        mimeType: mimeType,
        byteSize: processed.lengthInBytes,
      );
      final uploadId = begun['id']?.toString();
      if (uploadId == null || uploadId.isEmpty) {
        throw StateError('Moment upload session is missing an id');
      }
      await widget.api.putMomentUpload(uploadId, processed, mimeType);
      final completed = await widget.api.completeMomentUpload(uploadId);
      final mediaUrl = completed['media_url']?.toString().trim();
      if (mediaUrl == null || mediaUrl.isEmpty) {
        throw StateError('Moment upload completion is missing a media URL');
      }
      if (!mounted) return remoteImageUrls.toList(growable: false);
      setState(() {
        images.removeAt(0);
        _previews.remove(image);
        (videoMime == null ? remoteImageUrls : remoteVideoUrls).add(mediaUrl);
      });
    }
    return remoteImageUrls.toList(growable: false);
  }

  Future<bool> _onBack() async {
    if (busy) return false;
    if (_allowPop || _published || _draftSaved || !dirty) return true;
    final result = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('保存草稿？'),
        content: const Text('下次进入朋友圈发表页可继续编辑。'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('继续编辑'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('不保存'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, 'save'),
            child: const Text('保存草稿'),
          ),
        ],
      ),
    );
    if (result == 'save') {
      try {
        await _saveDraft();
        _draftSaved = true;
        _allowPop = true;
        return true;
      } catch (error) {
        if (mounted) {
          setState(() => errorMessage = error is MomentImageException
              ? error.message
              : error is BusinessApiException
                  ? error.message
                  : '草稿保存失败，请检查网络后重试');
        }
        return false;
      }
    }
    if (result == 'discard') {
      _allowPop = true;
      unawaited(MomentDraftStores.shared?.clear());
      try {
        await widget.api.deleteMomentDraft();
      } catch (_) {
        // A local discard still closes the editor; the stale server draft is
        // harmless and can be overwritten by a later explicit save.
      }
      return true;
    }
    return false;
  }

  Future<void> _pickImages() async {
    if (busy) return;
    final remaining = 9 - _mediaCount;
    if (remaining <= 0) {
      setState(() => errorMessage = '最多只能发布9个图片或视频');
      return;
    }
    setState(() => _selecting = true);
    try {
      final selected = await (widget.galleryPicker?.call(context, remaining) ??
          Navigator.of(context, rootNavigator: true)
              .push<MomentGallerySelection>(MotionPageRoute(
                  builder: (_) => ImagePickerPage(
                      maxCount: remaining,
                      confirmLabel: '添加',
                      showOriginalToggle: false))));
      if (!mounted || selected == null) return;
      if (selected.flash) throw const MomentImageException('朋友圈不支持闪照');
      for (final photo in selected.photos.take(remaining)) {
        if (photo.isVideo &&
            !const ['video/mp4', 'video/quicktime'].contains(photo.mimeType)) {
          throw const MomentImageException('仅支持MP4/MOV视频');
        }
        if (photo.isVideo &&
            photo.originalSizeBytes != null &&
            await photo.originalSizeBytes!() > 20 * 1024 * 1024) {
          throw const MomentImageException('视频大小不能超过20MB');
        }
        final bytes = await photo.originalBytes();
        if (!mounted) return;
        if (photo.isVideo &&
            (bytes.isEmpty || bytes.length > 20 * 1024 * 1024)) {
          throw const MomentImageException('视频大小不能超过20MB');
        }
        final suffix = photo.isVideo
            ? (photo.mimeType == 'video/quicktime' ? 'mov' : 'mp4')
            : 'jpg';
        final file = XFile.fromData(bytes,
            name: 'moment-${photo.id}.$suffix', mimeType: photo.mimeType);
        if (photo.isVideo && momentVideoMime(file) == null) {
          throw const MomentImageException('仅支持MP4/MOV视频');
        }
        setState(() {
          images.add(file);
          _previews[file] =
              photo.thumbnail.isNotEmpty ? photo.thumbnail : bytes;
          errorMessage = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => errorMessage =
            error is MomentImageException ? error.message : '选择媒体失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }

  Future<void> _openVisibility() async {
    final selected = await Navigator.push<MomentVisibilitySelection>(
      context,
      MotionPageRoute(
        builder: (_) => MomentVisibilityPage(
          api: widget.api,
          initialSelection: visibility,
          identityCache: widget.identityCache,
        ),
      ),
    );
    if (selected != null && mounted) setState(() => visibility = selected);
  }

  Future<void> _editLink() async {
    final controller = TextEditingController(text: linkUrl);
    final value = await showCupertinoDialog<String?>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('添加链接'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            key: const Key('moment-link-input'),
            controller: controller,
            keyboardType: TextInputType.url,
            placeholder: 'https://',
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(
              dialogContext,
              controller.text.trim(),
            ),
            child: const Text('完成'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !mounted) return;
    setState(() => linkUrl = value.isEmpty ? null : value);
  }

  Future<void> _publish() async {
    if (busy || !dirty) return;
    setState(() {
      saving = true;
      errorMessage = null;
    });
    try {
      final imageUrls = await _uploadPendingImages();
      final payloadIdentity = jsonEncode(_payload());
      if (_publishPayload != payloadIdentity) {
        _publishPayload = payloadIdentity;
        _publishKey = widget.api.newIdempotencyKey();
      }
      await widget.api.publishMoment(
        idempotencyKey: _publishKey,
        text: text.text,
        visibility: visibility.visibility,
        imageUrls: imageUrls,
        videoUrls: remoteVideoUrls,
        includeUserIds: visibility.visibility == 'INCLUDE'
            ? visibility.userIds.toList()
            : const [],
        includeTagIds: visibility.visibility == 'INCLUDE'
            ? visibility.tagIds.toList()
            : const [],
        excludeUserIds: visibility.visibility == 'EXCLUDE'
            ? visibility.userIds.toList()
            : const [],
        excludeTagIds: visibility.visibility == 'EXCLUDE'
            ? visibility.tagIds.toList()
            : const [],
        linkUrl: linkUrl,
      );
      await widget.api.deleteMomentDraft();
      unawaited(MomentDraftStores.shared?.clear());
      _published = true;
      _allowPop = true;
      if (mounted && Navigator.canPop(context)) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() => errorMessage = error is MomentImageException
            ? error.message
            : error is BusinessApiException
                ? error.message
                : '发表失败，内容已保留，请检查网络后重试');
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          // didPop=true 说明本次 pop 已由代码触发（发布成功携带结果返回），
          // 若再弹一层会把用户带过朋友圈页、落回发现页。
          if (didPop) return;
          if (await _onBack() && context.mounted) Navigator.pop(context);
        },
        child: WeChatPageScaffold.navigation(
          backgroundColor: WeChatColors.elevatedSurface(context),
          navigationBar: CupertinoNavigationBar(
            backgroundColor: WeChatColors.navigationBackground(context),
            border: Border(
              bottom: BorderSide(
                  color: WeChatColors.resolve(context, WeChatColors.divider),
                  width: .5),
            ),
            leading: CupertinoButton(
              key: const Key('moment-compose-cancel'),
              padding: EdgeInsets.zero,
              onPressed: () async {
                if (await _onBack() && context.mounted) Navigator.pop(context);
              },
              child: Text(
                '取消',
                style:
                    TextStyle(color: WeChatColors.resolveTextPrimary(context)),
              ),
            ),
            middle: const Text(
              '朋友圈',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            trailing: CupertinoButton(
              key: const Key('moment-compose-publish'),
              padding: EdgeInsets.zero,
              onPressed: busy || !dirty ? null : _publish,
              child: busy
                  ? const CupertinoActivityIndicator()
                  : Text(
                      '发表',
                      style: TextStyle(
                        color: WeChatColors.resolve(
                            context, WeChatColors.socialLink),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
          child: SafeArea(
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                if (errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Text(
                      errorMessage!,
                      key: const Key('moment-compose-error'),
                      style: const TextStyle(color: WeChatColors.danger),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                  child: CupertinoTextField(
                    controller: text,
                    minLines: 6,
                    maxLines: 12,
                    padding: EdgeInsets.zero,
                    decoration: BoxDecoration(
                      color: WeChatColors.elevatedSurface(context),
                    ),
                    placeholder: '这一刻的想法…',
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final imageUrl in remoteImageUrls)
                        Stack(
                          children: [
                            Image.network(
                              imageUrl,
                              width: 84,
                              height: 84,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const SizedBox(
                                width: 84,
                                height: 84,
                                child: Icon(CupertinoIcons.photo),
                              ),
                            ),
                            Positioned(
                              right: 0,
                              child: CupertinoButton(
                                padding: EdgeInsets.zero,
                                onPressed: busy
                                    ? null
                                    : () => setState(
                                          () =>
                                              remoteImageUrls.remove(imageUrl),
                                        ),
                                child: const Icon(
                                  CupertinoIcons.clear_circled_solid,
                                  color: CupertinoColors.systemGrey,
                                ),
                              ),
                            ),
                          ],
                        ),
                      for (final videoUrl in remoteVideoUrls)
                        SizedBox(
                            width: 84,
                            height: 84,
                            child: Stack(children: [
                              const Center(
                                  child: Icon(CupertinoIcons.play_circle,
                                      size: 36)),
                              Positioned(
                                  right: 0,
                                  child: CupertinoButton(
                                      padding: EdgeInsets.zero,
                                      onPressed: busy
                                          ? null
                                          : () => setState(() =>
                                              remoteVideoUrls.remove(videoUrl)),
                                      child: const Icon(
                                          CupertinoIcons.clear_circled_solid))),
                            ])),
                      for (final image in images)
                        Stack(
                          children: [
                            if (momentVideoMime(image) != null)
                              const SizedBox(
                                  width: 84,
                                  height: 84,
                                  child: Icon(CupertinoIcons.play_circle,
                                      size: 36))
                            else if (_previews[image]?.isNotEmpty == true)
                              Image.memory(_previews[image]!,
                                  cacheWidth: 256,
                                  width: 84,
                                  height: 84,
                                  fit: BoxFit.cover)
                            else
                              Image.file(
                                File(image.path),
                                width: 84,
                                height: 84,
                                fit: BoxFit.cover,
                              ),
                            Positioned(
                              right: 0,
                              child: CupertinoButton(
                                padding: EdgeInsets.zero,
                                onPressed: busy
                                    ? null
                                    : () =>
                                        setState(() => images.remove(image)),
                                child: const Icon(
                                  CupertinoIcons.clear_circled_solid,
                                  color: CupertinoColors.systemGrey,
                                ),
                              ),
                            ),
                          ],
                        ),
                      if (_mediaCount < 9)
                        CupertinoButton(
                          key: const Key('moment-pick-images'),
                          color: WeChatColors.resolve(
                              context, WeChatColors.lightSurface),
                          minimumSize: const Size(84, 84),
                          padding: EdgeInsets.zero,
                          onPressed: busy ? null : _pickImages,
                          child: const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(CupertinoIcons.photo_on_rectangle,
                                    color: WeChatColors.textSecondary,
                                    size: 26),
                                SizedBox(height: 4),
                                Text('相册',
                                    style: TextStyle(
                                        color: WeChatColors.textSecondary,
                                        fontSize: 12))
                              ]),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                WeChatListTile(
                  key: const Key('moment-visibility-row'),
                  leading: const Icon(CupertinoIcons.person_2),
                  title: const Text('谁可以看'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        visibility.summary,
                        style: const TextStyle(
                          color: WeChatColors.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(
                        CupertinoIcons.chevron_right,
                        size: 16,
                        color: WeChatColors.textTertiary,
                      ),
                    ],
                  ),
                  onTap: _openVisibility,
                ),
                WeChatListTile(
                  key: const Key('moment-link-row'),
                  leading: const Icon(CupertinoIcons.link),
                  title: const Text('添加链接'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (linkUrl != null)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 180),
                          child: Text(
                            linkUrl!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: WeChatColors.textSecondary,
                            ),
                          ),
                        ),
                      const SizedBox(width: 8),
                      const Icon(
                        CupertinoIcons.chevron_right,
                        size: 16,
                        color: WeChatColors.textTertiary,
                      ),
                    ],
                  ),
                  onTap: _editLink,
                ),
              ],
            ),
          ),
        ),
      );
}

/// 朋友圈图片候选过滤（纯逻辑）：按 MIME，缺失时按扩展名兜底。
/// Photo Picker 允许选中视频/文件，朋友圈仅接受图片。
bool isSupportedMomentImage(XFile file) {
  final mime = (file.mimeType ?? '').toLowerCase();
  if (mime.isNotEmpty) return mime.startsWith('image/');
  const extensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};
  final name = file.name;
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return extensions.contains(name.substring(dot).toLowerCase());
}

/// Only allow native-player containers accepted by the Moments upload API.
String? momentVideoMime(XFile file) {
  final mime = file.mimeType?.toLowerCase();
  if (mime == 'video/mp4' || mime == 'video/quicktime') return mime;
  if (mime != null && mime.isNotEmpty) return null;
  final name = file.name.toLowerCase();
  if (name.endsWith('.mp4') || name.endsWith('.m4v')) return 'video/mp4';
  if (name.endsWith('.mov')) return 'video/quicktime';
  return null;
}
