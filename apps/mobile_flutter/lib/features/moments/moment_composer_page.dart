import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'moment_visibility_page.dart';

final class MomentComposerPage extends StatefulWidget {
  const MomentComposerPage({
    super.key,
    required this.api,
    this.initialImages = const [],
  });

  final BusinessApiClient api;
  final List<XFile> initialImages;

  @override
  State<MomentComposerPage> createState() => _MomentComposerPageState();
}

final class _MomentComposerPageState extends State<MomentComposerPage> {
  final text = TextEditingController();
  final images = <XFile>[];
  final remoteImageUrls = <String>[];
  MomentVisibilitySelection visibility =
      const MomentVisibilitySelection.public();
  String? linkUrl;
  String? errorMessage;
  bool saving = false;
  bool _allowPop = false;
  bool _draftSaved = false;
  bool _published = false;

  bool get dirty =>
      text.text.trim().isNotEmpty ||
      images.isNotEmpty ||
      remoteImageUrls.isNotEmpty ||
      linkUrl != null ||
      visibility.visibility != 'PUBLIC' ||
      visibility.selectedCount > 0;

  @override
  void initState() {
    super.initState();
    images.addAll(widget.initialImages.take(9));
    _loadDraft();
  }

  Future<void> _loadDraft() async {
    try {
      final draft = await widget.api.momentDraft();
      if (!mounted) return;
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
      setState(() {
        text.text = draft['text']?.toString() ?? '';
        linkUrl = draft['link_url']?.toString();
        remoteImageUrls
          ..clear()
          ..addAll(
            (draft['image_urls'] as List? ?? const [])
                .map((value) => value.toString())
                .where((value) => value.trim().isNotEmpty)
                .take(9),
          );
        visibility = MomentVisibilitySelection(
          visibility: mode,
          userIds: users,
          tagIds: tags,
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        errorMessage =
            error is BusinessApiException ? error.message : '草稿加载失败，可继续编辑并稍后重试';
      });
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
    await widget.api.saveMomentDraft(_payload());
  }

  String _mimeType(XFile image) {
    final explicit = image.mimeType?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final extension = image.name.toLowerCase().split('.').last;
    return switch (extension) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'gif' => 'image/gif',
      _ => 'image/jpeg',
    };
  }

  Future<List<String>> _uploadPendingImages() async {
    while (images.isNotEmpty) {
      final image = images.first;
      final bytes = await image.readAsBytes();
      final mimeType = _mimeType(image);
      final begun = await widget.api.beginMomentUpload(
        fileName: image.name,
        mimeType: mimeType,
        byteSize: bytes.length,
      );
      final uploadId = begun['id']?.toString();
      if (uploadId == null || uploadId.isEmpty) {
        throw StateError('Moment upload session is missing an id');
      }
      await widget.api.putMomentUpload(uploadId, bytes, mimeType);
      final completed = await widget.api.completeMomentUpload(uploadId);
      final mediaUrl = completed['media_url']?.toString().trim();
      if (mediaUrl == null || mediaUrl.isEmpty) {
        throw StateError('Moment upload completion is missing a media URL');
      }
      if (!mounted) return remoteImageUrls.toList(growable: false);
      setState(() {
        images.removeAt(0);
        remoteImageUrls.add(mediaUrl);
      });
    }
    return remoteImageUrls.toList(growable: false);
  }

  Future<bool> _onBack() async {
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
          setState(() => errorMessage = error is BusinessApiException
              ? error.message
              : '草稿保存失败，请检查网络后重试');
        }
        return false;
      }
    }
    if (result == 'discard') {
      _allowPop = true;
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
    final selected = await ImagePicker().pickMultiImage(imageQuality: 82);
    if (!mounted) return;
    setState(() => images.addAll(
          selected.take(9 - images.length - remoteImageUrls.length),
        ));
  }

  Future<void> _openVisibility() async {
    final selected = await Navigator.push<MomentVisibilitySelection>(
      context,
      CupertinoPageRoute(
        builder: (_) => MomentVisibilityPage(
          api: widget.api,
          initialSelection: visibility,
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
    if (saving || !dirty) return;
    setState(() {
      saving = true;
      errorMessage = null;
    });
    try {
      final imageUrls = await _uploadPendingImages();
      await widget.api.publishMoment(
        text: text.text,
        visibility: visibility.visibility,
        imageUrls: imageUrls,
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
      _published = true;
      _allowPop = true;
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() => errorMessage = error is BusinessApiException
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
        onPopInvokedWithResult: (_, __) async {
          if (await _onBack() && context.mounted) Navigator.pop(context);
        },
        child: WeChatPageScaffold.navigation(
          backgroundColor: CupertinoColors.white,
          navigationBar: CupertinoNavigationBar(
            backgroundColor: CupertinoColors.white,
            border: const Border(
              bottom: BorderSide(color: WeChatColors.divider, width: .5),
            ),
            leading: CupertinoButton(
              key: const Key('moment-compose-cancel'),
              padding: EdgeInsets.zero,
              onPressed: () async {
                if (await _onBack() && context.mounted) Navigator.pop(context);
              },
              child: const Text(
                '取消',
                style: TextStyle(color: CupertinoColors.black),
              ),
            ),
            middle: const Text(
              '朋友圈',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            trailing: CupertinoButton(
              key: const Key('moment-compose-publish'),
              padding: EdgeInsets.zero,
              onPressed: saving || !dirty ? null : _publish,
              child: saving
                  ? const CupertinoActivityIndicator()
                  : const Text(
                      '发表',
                      style: TextStyle(
                        color: WeChatColors.socialLink,
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
                    decoration: const BoxDecoration(
                      color: CupertinoColors.white,
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
                                onPressed: () => setState(
                                  () => remoteImageUrls.remove(imageUrl),
                                ),
                                child: const Icon(
                                  CupertinoIcons.clear_circled_solid,
                                  color: CupertinoColors.systemGrey,
                                ),
                              ),
                            ),
                          ],
                        ),
                      for (final image in images)
                        Stack(
                          children: [
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
                                onPressed: () =>
                                    setState(() => images.remove(image)),
                                child: const Icon(
                                  CupertinoIcons.clear_circled_solid,
                                  color: CupertinoColors.systemGrey,
                                ),
                              ),
                            ),
                          ],
                        ),
                      if (images.length + remoteImageUrls.length < 9)
                        CupertinoButton(
                          key: const Key('moment-pick-images'),
                          color: WeChatColors.lightSurface,
                          minimumSize: const Size(84, 84),
                          padding: EdgeInsets.zero,
                          onPressed: _pickImages,
                          child: const Icon(
                            CupertinoIcons.add,
                            color: WeChatColors.textSecondary,
                            size: 30,
                          ),
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
