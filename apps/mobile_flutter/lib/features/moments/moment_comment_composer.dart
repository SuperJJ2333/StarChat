import 'dart:convert';
import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../../ui/chat/chat_emoji_panel.dart';
import '../../ui/chat/contain_image_bubble.dart' show boundedChatImageProvider;
import '../matrix/gallery_media_payload.dart';
import '../matrix/image_picker_page.dart';
import '../matrix/profile_repository.dart';
import 'moment_models.dart';

typedef MomentGalleryPicker
    = Future<({List<GalleryPhoto> photos, bool original})?> Function(
        BuildContext context, int maxCount);

Future<MomentCommentView?> showMomentCommentComposer(BuildContext context,
        {required BusinessApiClient api,
        required String momentId,
        MomentCommentView? parent,
        ProfileRepository? identityCache,
        MomentGalleryPicker? galleryPicker}) =>
    showCupertinoModalPopup<MomentCommentView>(
        context: context,
        builder: (_) => _CommentComposer(
            api: api,
            momentId: momentId,
            parent: parent,
            identityCache: identityCache,
            galleryPicker: galleryPicker));

class _CommentComposer extends StatefulWidget {
  const _CommentComposer(
      {required this.api,
      required this.momentId,
      this.parent,
      this.identityCache,
      this.galleryPicker});
  final BusinessApiClient api;
  final String momentId;
  final MomentCommentView? parent;
  final ProfileRepository? identityCache;
  final MomentGalleryPicker? galleryPicker;
  @override
  State<_CommentComposer> createState() => _CommentComposerState();
}

class _CommentComposerState extends State<_CommentComposer> {
  final text = TextEditingController();
  final focus = FocusNode();
  final images = <GalleryMediaPayload>[];
  final uploadedIds = <GalleryMediaPayload, String>{};
  final localEmoji = <String, GalleryMediaPayload>{};
  int nextEmojiId = 0;
  String? error;
  bool busy = false;
  bool picking = false;
  bool showEmoji = false;
  String? requestKey;
  bool get locked => busy || picking;
  late final Future<String?> initialAccount;

  @override
  void initState() {
    super.initState();
    initialAccount = accountScope();
  }

  Future<String?> accountScope() async {
    final session = await widget.api.sessionStore.session();
    if (session == null) return null;
    final parts = session.accessToken.split('.');
    if (parts.length == 3) {
      try {
        final claims = jsonDecode(
            utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
        if (claims is Map && claims['sub'] != null) {
          return 'business:${claims['sub']}';
        }
      } on FormatException {
        // Opaque development credentials still get a session-local boundary.
      }
    }
    return session.matrixUserId ?? session.accessToken;
  }

  Future<void> ensureAccount() async {
    final expected = await initialAccount;
    if (expected == null || expected != await accountScope()) {
      throw const FormatException('登录状态已变化，请重新打开评论');
    }
  }

  @override
  void dispose() {
    text.dispose();
    focus.dispose();
    super.dispose();
  }

  Future<void> pick() async {
    if (locked || images.length >= 9) return;
    focus.unfocus();
    setState(() {
      picking = true;
      error = null;
      showEmoji = false;
    });
    try {
      final maxCount = 9 - images.length;
      final selected = await (widget.galleryPicker?.call(context, maxCount) ??
          Navigator.of(context, rootNavigator: true)
              .push<({List<GalleryPhoto> photos, bool original})>(
                  CupertinoPageRoute(
                      builder: (_) => ImagePickerPage(
                          photosOnly: true, maxCount: maxCount))));
      if (!mounted || selected == null) return;
      await ensureAccount();
      if (!mounted) return;
      if (selected.photos.length > maxCount) {
        throw const FormatException('最多选择9张图片');
      }
      final prepared = <GalleryMediaPayload>[];
      for (final photo in selected.photos) {
        if (photo.isVideo) throw const FormatException('评论仅支持图片或 GIF');
        prepared
            .add(await prepareGalleryMedia(photo, original: selected.original));
        if (!mounted) return;
      }
      await ensureAccount();
      if (!mounted) return;
      setState(() {
        images.addAll(prepared);
        for (final image in prepared) {
          localEmoji['${nextEmojiId++}'] = image;
        }
        while (localEmoji.length > 9) {
          localEmoji.remove(localEmoji.keys.first);
        }
        requestKey = null;
      });
    } catch (failure) {
      if (mounted) {
        setState(() => error =
            failure is FormatException ? failure.message : '图片读取失败，请重试');
      }
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  void insertEmoji(String emoji) {
    if (locked) return;
    final selection = text.selection;
    final start = selection.isValid ? selection.start : text.text.length;
    final end = selection.isValid ? selection.end : start;
    final value = text.text.replaceRange(start, end, emoji);
    if (value.characters.length > 1000) return;
    text.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: start + emoji.length));
    setState(() => requestKey = null);
  }

  Future<void> send() async {
    if (locked || (text.text.trim().isEmpty && images.isEmpty)) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await ensureAccount();
      if (!mounted) return;
      for (final image in images) {
        if (uploadedIds.containsKey(image)) continue;
        final upload = await widget.api.beginMomentUpload(
            fileName: image.fileName,
            mimeType: image.mimeType,
            byteSize: image.bytes.length);
        if (!mounted) return;
        final id = upload['id'].toString();
        await ensureAccount();
        if (!mounted) return;
        await widget.api.putMomentUpload(id, image.bytes, image.mimeType);
        if (!mounted) return;
        await ensureAccount();
        if (!mounted) return;
        final complete = await widget.api.completeMomentUpload(id);
        if (!mounted) return;
        if (complete['media_url'] == null) {
          throw StateError('Missing media URL');
        }
        uploadedIds[image] = id;
      }
      await ensureAccount();
      if (!mounted) return;
      requestKey ??= widget.api.newIdempotencyKey();
      final response = await widget.api.commentMoment(
          widget.momentId, text.text.trim(),
          parentId: widget.parent?.id,
          imageUploadIds: [for (final image in images) uploadedIds[image]!],
          idempotencyKey: requestKey);
      if (!mounted) return;
      await ensureAccount();
      if (mounted) Navigator.pop(context, MomentCommentView.fromJson(response));
    } catch (failure) {
      if (mounted) {
        setState(() {
          busy = false;
          error = failure is BusinessApiException
              ? failure.message
              : failure is FormatException
                  ? failure.message
                  : '发送失败，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.identityCache == null
      ? buildContent(context)
      : ListenableBuilder(
          listenable: widget.identityCache!,
          builder: (context, _) => buildContent(context));

  String get replyName {
    final author = widget.parent!.author;
    return widget.identityCache
            ?.resolveIdentity(
                userId: author.userId,
                username: author.username,
                nickname: author.nickname,
                displayName: author.displayName,
                avatarUrl: author.avatarUrl)
            .displayName ??
        author.displayName;
  }

  Widget buildContent(BuildContext context) => PopScope(
      canPop: !busy,
      child: CupertinoPopupSurface(
          child: SafeArea(
              top: false,
              child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      12, 12, 12, MediaQuery.viewInsetsOf(context).bottom + 12),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(widget.parent == null ? '评论' : '回复 $replyName'),
                    const SizedBox(height: 10),
                    CupertinoTextField(
                        key: const Key('moment-comment-input'),
                        controller: text,
                        focusNode: focus,
                        autofocus: true,
                        enabled: !locked,
                        maxLength: 1000,
                        minLines: 1,
                        maxLines: 4,
                        placeholder: '说点什么…',
                        onTap: () => setState(() => showEmoji = false),
                        onChanged: (_) => setState(() => requestKey = null)),
                    if (images.isNotEmpty)
                      SizedBox(
                          height: 70,
                          child: ListView(
                              scrollDirection: Axis.horizontal,
                              children: [
                                for (final image in images)
                                  Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Image(
                                            image: boundedChatImageProvider(
                                                image.bytes,
                                                maxEdge: (48 *
                                                        MediaQuery
                                                            .devicePixelRatioOf(
                                                                context))
                                                    .ceil()
                                                    .clamp(48, 192)),
                                            width: 48,
                                            height: 48,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, __, ___) =>
                                                const Icon(
                                                    CupertinoIcons.photo)),
                                        CupertinoButton(
                                            onPressed: locked
                                                ? null
                                                : () => setState(() {
                                                      images.remove(image);
                                                      uploadedIds.remove(image);
                                                      requestKey = null;
                                                    }),
                                            child: const Text('移除')),
                                      ])
                              ])),
                    if (error != null)
                      Text(error!,
                          style: const TextStyle(
                              color: CupertinoColors.systemRed)),
                    Row(children: [
                      CupertinoButton(
                          onPressed: locked
                              ? null
                              : () {
                                  focus.unfocus();
                                  setState(() => showEmoji = !showEmoji);
                                },
                          child: const Icon(CupertinoIcons.smiley)),
                      CupertinoButton(
                          key: const Key('moment-comment-gallery'),
                          onPressed: locked || images.length >= 9 ? null : pick,
                          child: picking
                              ? const CupertinoActivityIndicator()
                              : const Icon(CupertinoIcons.photo)),
                      const Spacer(),
                      CupertinoButton(
                          key: const Key('moment-comment-submit'),
                          onPressed: locked ||
                                  (text.text.trim().isEmpty && images.isEmpty)
                              ? null
                              : send,
                          child: busy
                              ? const CupertinoActivityIndicator()
                              : const Text('发送')),
                    ]),
                    if (showEmoji)
                      SizedBox(
                          height: MediaQuery.sizeOf(context).height * .3,
                          child: ChatEmojiPanel(
                            onEmojiSelected: insertEmoji,
                            customItems: [
                              for (final entry in localEmoji.entries)
                                CustomEmojiItem(
                                    id: entry.key,
                                    bytes: entry.value.bytes,
                                    mimeType: entry.value.mimeType,
                                    isAnimated:
                                        entry.value.mimeType == 'image/gif')
                            ],
                            customEmptyState: Center(
                                child: CupertinoButton(
                                    onPressed: locked ? null : pick,
                                    child: const Text('从相册添加图片或 GIF'))),
                            onCustomSelected: (item) {
                              if (locked || images.length >= 9) return;
                              final image = localEmoji[item.id];
                              if (image == null) return;
                              setState(() {
                                if (!images.contains(image)) images.add(image);
                                requestKey = null;
                              });
                            },
                            onCustomRemoved: (item) async {
                              if (!locked) {
                                setState(() => localEmoji.remove(item.id));
                              }
                            },
                          )),
                  ])))));
}
