import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';

import '../../ui/components/wechat_scaffold.dart';

import '../../ui/foundation/wechat_tokens.dart';
import '../../core/business_api_client.dart';
import '../../ui/moments/wechat_moment_tile.dart';
import '../../ui/moments/wechat_moment_viewer.dart';
import 'moment_models.dart';
import 'moment_audience_picker_page.dart';

final class MomentsPage extends StatefulWidget {
  const MomentsPage({super.key, required this.api});
  final BusinessApiClient api;
  @override
  State<MomentsPage> createState() => _MomentsPageState();
}

final class _MomentsPageState extends State<MomentsPage> {
  final _itemOverrides = <String, MomentItem>{};
  final _pendingLikeIds = <String>{};
  late Future<Map<String, dynamic>> _feed;
  String? _coverUrl;
  String? _interactionError;

  @override
  void initState() {
    super.initState();
    _feed = widget.api.momentsFeed(mode: 'latest');
    widget.api.momentsPreferences().then((value) {
      if (mounted) setState(() => _coverUrl = value['cover_url']?.toString());
    });
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
                  onPressed: () => Navigator.push(
                      context,
                      CupertinoPageRoute(
                          builder: (_) => MomentComposerPage(api: widget.api))),
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
                            child: const Text('畅聊朋友圈',
                                style: TextStyle(
                                    color: CupertinoColors.white,
                                    fontSize: 22)))),
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

final class MomentComposerPage extends StatefulWidget {
  const MomentComposerPage({super.key, required this.api});
  final BusinessApiClient api;
  @override
  State<MomentComposerPage> createState() => _ComposerState();
}

final class _ComposerState extends State<MomentComposerPage> {
  final text = TextEditingController();
  final users = TextEditingController();
  final images = <XFile>[];
  final directUserIds = <String>{};
  final tagIds = <String>{};
  String visibility = 'PUBLIC';
  String? location;
  String? linkUrl;
  bool saving = false;
  bool _allowPop = false;
  bool _draftSaved = false;
  bool _published = false;

  bool get dirty =>
      text.text.trim().isNotEmpty ||
      images.isNotEmpty ||
      location != null ||
      linkUrl != null ||
      visibility != 'PUBLIC' ||
      directUserIds.isNotEmpty ||
      tagIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.api.momentDraft().then((draft) {
      if (!mounted) return;
      setState(() {
        text.text = draft['text']?.toString() ?? '';
        visibility = draft['visibility']?.toString() ?? 'PUBLIC';
        location = draft['location']?.toString();
        linkUrl = draft['link_url']?.toString();
        directUserIds.addAll(List<String>.from(draft['include_user_ids'] ??
            draft['exclude_user_ids'] ??
            const []));
        tagIds.addAll(List<String>.from(
            draft['include_tag_ids'] ?? draft['exclude_tag_ids'] ?? const []));
      });
    }).catchError((_) {});
  }

  @override
  void dispose() {
    text.dispose();
    users.dispose();
    super.dispose();
  }

  Future<bool> _onBack() async {
    if (_allowPop || _published || _draftSaved) return true;
    if (!dirty) return true;
    final result = await showCupertinoDialog<String>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
              title: const Text('保存草稿？'),
              content: const Text('下次进入朋友圈发表页可继续编辑。'),
              actions: [
                CupertinoDialogAction(
                    onPressed: () => Navigator.pop(context, 'cancel'),
                    child: const Text('继续编辑')),
                CupertinoDialogAction(
                    isDestructiveAction: true,
                    onPressed: () => Navigator.pop(context, 'discard'),
                    child: const Text('不保存')),
                CupertinoDialogAction(
                    onPressed: () => Navigator.pop(context, 'save'),
                    child: const Text('保存草稿')),
              ],
            ));
    if (result == 'save') {
      await _saveDraft();
      _draftSaved = true;
      _allowPop = true;
      return true;
    }
    if (result == 'discard') {
      _allowPop = true;
      try {
        await widget.api.deleteMomentDraft();
      } catch (_) {}
      return true;
    }
    return false;
  }

  Map<String, dynamic> _payload() => {
        'text': text.text,
        'visibility': visibility,
        'image_urls': images.map((item) => item.path).toList(),
        'location': location,
        'link_url': linkUrl,
        'include_user_ids':
            visibility == 'INCLUDE' ? directUserIds.toList() : const [],
        'include_tag_ids': visibility == 'INCLUDE' ? tagIds.toList() : const [],
        'exclude_user_ids':
            visibility == 'EXCLUDE' ? directUserIds.toList() : const [],
        'exclude_tag_ids': visibility == 'EXCLUDE' ? tagIds.toList() : const [],
      };

  Future<void> _saveDraft() async {
    await widget.api.saveMomentDraft(_payload());
  }

  Future<void> _pickImages() async {
    final selected = await ImagePicker().pickMultiImage(imageQuality: 82);
    if (!mounted) return;
    setState(() {
      images.addAll(selected.take(9 - images.length));
    });
  }

  Future<void> _selectAudience() async {
    final selected = await Navigator.push<Map<String, dynamic>>(
        context,
        CupertinoPageRoute(
            builder: (_) => MomentAudiencePickerPage(
                api: widget.api,
                initialUsers: directUserIds,
                initialTags: tagIds)));
    if (selected != null && mounted) {
      setState(() {
        directUserIds
          ..clear()
          ..addAll(List<String>.from(selected['users'] ?? const []));
        tagIds
          ..clear()
          ..addAll(List<String>.from(selected['tags'] ?? const []));
      });
    }
  }

  Future<void> _publish() async {
    if (saving || (!dirty && text.text.trim().isEmpty)) return;
    setState(() => saving = true);
    try {
      await widget.api.publishMoment(
          text: text.text,
          visibility: visibility,
          imageUrls: const [],
          includeUserIds:
              visibility == 'INCLUDE' ? directUserIds.toList() : const [],
          excludeUserIds:
              visibility == 'EXCLUDE' ? directUserIds.toList() : const []);
      await widget.api.deleteMomentDraft();
      _published = true;
      _allowPop = true;
      if (mounted) Navigator.pop(context);
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
        navigationBar: CupertinoNavigationBar(
            backgroundColor: CupertinoColors.white,
            border: const Border(bottom: BorderSide(color: Color(0xFFE5E5E5))),
            leading: CupertinoButton(
                key: const Key('moment-compose-cancel'),
                padding: EdgeInsets.zero,
                onPressed: () async {
                  if (await _onBack() && context.mounted) {
                    Navigator.pop(context);
                  }
                },
                child: const Text('取消',
                    style: TextStyle(color: CupertinoColors.black))),
            middle: const Text('朋友圈',
                style: TextStyle(fontWeight: FontWeight.w600)),
            trailing: CupertinoButton(
                key: const Key('moment-compose-publish'),
                padding: EdgeInsets.zero,
                onPressed: saving || !dirty ? null : _publish,
                child: saving
                    ? const CupertinoActivityIndicator()
                    : const Text('发表',
                        style: TextStyle(
                            color: Color(0xFF576B95),
                            fontWeight: FontWeight.w600)))),
        child: SafeArea(
            child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
              CupertinoTextField(
                  controller: text,
                  minLines: 5,
                  maxLines: 10,
                  decoration: const BoxDecoration(color: CupertinoColors.white),
                  placeholder: '这一刻的想法…',
                  onChanged: (_) => setState(() {})),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final image in images)
                  Stack(children: [
                    Image.file(File(image.path),
                        width: 76, height: 76, fit: BoxFit.cover),
                    Positioned(
                        right: 0,
                        child: CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed: () =>
                                setState(() => images.remove(image)),
                            child: const Icon(CupertinoIcons.clear_circled)))
                  ]),
                if (images.length < 9)
                  CupertinoButton(
                      key: const Key('moment-pick-images'),
                      onPressed: _pickImages,
                      child: const Icon(CupertinoIcons.photo_on_rectangle))
              ]),
              const SizedBox(height: 16),
              CupertinoSlidingSegmentedControl<String>(
                  groupValue: visibility,
                  children: const {
                    'PUBLIC': Text('公开（好友）'),
                    'SELF': Text('私密'),
                    'INCLUDE': Text('只给谁看'),
                    'EXCLUDE': Text('不给谁看')
                  },
                  onValueChanged: (v) => setState(() => visibility = v!)),
              if (visibility == 'INCLUDE' || visibility == 'EXCLUDE')
                CupertinoListTile(
                    title: const Text('选择标签或者朋友'),
                    additionalInfo: Text(
                        '${directUserIds.length} 位朋友、${tagIds.length} 个标签'),
                    onTap: _selectAudience),
              CupertinoListTile(
                  title: const Text('所在位置'),
                  additionalInfo: Text(location ?? '不显示位置'),
                  onTap: () => setState(
                      () => location = location == null ? '当前位置' : null)),
              CupertinoTextField(
                  placeholder: '添加链接',
                  onChanged: (value) =>
                      linkUrl = value.trim().isEmpty ? null : value.trim()),
            ])),
      ));
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
