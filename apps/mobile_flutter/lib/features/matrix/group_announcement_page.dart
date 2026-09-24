import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Tooltip;
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' show MatrixException;
import 'package:shared_preferences/shared_preferences.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/chat/contain_image_bubble.dart' show boundedChatImageProvider;
import '../../ui/foundation/wechat_tokens.dart';
import 'gif_image_policy.dart';
import 'group_announcement_service.dart';
import 'image_picker_page.dart';
import '../../ui/motion/motion_page_route.dart';

final class GroupAnnouncementPage extends StatefulWidget {
  const GroupAnnouncementPage(
      {super.key, required this.service, this.pickImage});
  final Future<XFile?> Function()? pickImage;
  final GroupAnnouncementService service;
  @override
  State<GroupAnnouncementPage> createState() => _GroupAnnouncementPageState();
}

final class _GroupAnnouncementPageState extends State<GroupAnnouncementPage> {
  List<AnnouncementBlock>? blocks;
  GroupAnnouncement? _document;
  final input = TextEditingController();
  bool editing = false;
  bool busy = false;
  String? error;
  bool _loadRetryable = false;
  bool _canReplaceUnreadable = false;
  int _loadEpoch = 0;
  int _editorEpoch = 0;
  StreamSubscription<void>? _subscription;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _listen();
  }

  void _listen() {
    _subscription = widget.service.changes.listen((_) {
      if (editing && widget.service.canEdit) return;
      if (editing) {
        setState(() {
          _editorEpoch++;
          editing = false;
          busy = false;
          blocks = null;
          _clearInputs();
        });
      }
      unawaited(_load());
    });
  }

  void _clearInputs() {
    input.clear();
  }

  @override
  void didUpdateWidget(covariant GroupAnnouncementPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.service, widget.service)) return;
    _editorEpoch++;
    _subscription?.cancel();
    _clearInputs();
    blocks = null;
    _document = null;
    editing = false;
    busy = false;
    error = null;
    _loadRetryable = false;
    _canReplaceUnreadable = false;
    _listen();
    unawaited(_load());
  }

  @override
  void dispose() {
    _subscription?.cancel();
    input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final epoch = ++_loadEpoch;
    try {
      final value = await widget.service.load();
      if (mounted && epoch == _loadEpoch) {
        setState(() {
          blocks = value.blocks.toList();
          _document = value;
          error = null;
          _canReplaceUnreadable = false;
        });
      }
    } catch (failure) {
      if (mounted && epoch == _loadEpoch) {
        setState(() {
          _canReplaceUnreadable = failure is AnnouncementPendingDecryption ||
              failure is AnnouncementDecryptionUnavailable ||
              failure is FormatException;
          final status =
              failure is MatrixException ? failure.response?.statusCode : null;
          _loadRetryable = failure is SocketException ||
              failure is TimeoutException ||
              failure is http.ClientException ||
              status == 408 ||
              status == 429 ||
              (status != null && status >= 500 && status < 600);
          error = failure is AnnouncementPendingDecryption
              ? '公告无法解密，请联系群管理员重新发布'
              : failure is AnnouncementDecryptionUnavailable
                  ? '公告无法解密，请联系群管理员重新发布'
                  : _loadRetryable
                      ? '公告加载失败，请重试'
                      : failure is FormatException
                          ? '公告格式异常，暂无法显示'
                          : failure is StateError &&
                                  failure.message == '仅群成员可查看公告'
                              ? '仅群成员可查看公告'
                              : failure is MatrixException &&
                                      (failure.errcode == 'M_FORBIDDEN' ||
                                          failure.errcode == 'M_UNKNOWN_TOKEN')
                                  ? '无权查看群公告'
                                  : '公告暂不可用，请稍后查看';
        });
      }
    }
  }

  Future<void> _replaceUnreadable() async {
    final epoch = _loadEpoch;
    final service = widget.service;
    final confirmed = await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
              title: const Text('重新编写公告'),
              content: const Text(
                  '当前公告无法读取。发布新内容后将替换当前公告；发布空内容可清空公告。历史消息会保留，取消或返回不会修改公告。'),
              actions: [
                CupertinoDialogAction(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消')),
                CupertinoDialogAction(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('继续编写')),
              ],
            ));
    if (confirmed != true ||
        !mounted ||
        epoch != _loadEpoch ||
        !identical(service, widget.service) ||
        !service.canEdit ||
        !_canReplaceUnreadable) {
      return;
    }
    setState(() {
      blocks = [];
      _document = null;
      error = null;
      _canReplaceUnreadable = false;
    });
    _edit();
  }

  void _edit() {
    input.text = blocks!
        .where((block) => !block.isImage)
        .map((block) => block.value)
        .where((text) => text.isNotEmpty)
        .join('\n\n');
    setState(() {
      blocks = blocks!.where((block) => block.isImage).toList();
      editing = true;
    });
  }

  Future<void> _save() async {
    final epoch = _editorEpoch;
    final service = widget.service;
    bool current() =>
        mounted && epoch == _editorEpoch && identical(service, widget.service);
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final document = GroupAnnouncement([
        if (input.text.trim().isNotEmpty) AnnouncementBlock.text(input.text),
        ...blocks!,
      ]);
      await service.save(document);
      if (mounted && current()) Navigator.pop(context, true);
    } on FormatException catch (failure) {
      if (current()) setState(() => error = failure.message);
    } catch (_) {
      if (current()) setState(() => error = '发布失败，请检查权限、加密状态和网络后重试');
    } finally {
      if (current()) setState(() => busy = false);
    }
  }

  Future<void> _image() async {
    final epoch = _editorEpoch;
    final service = widget.service;
    bool current() =>
        mounted && epoch == _editorEpoch && identical(service, widget.service);
    if (blocks!.length >=
        maxAnnouncementBlocks - (input.text.trim().isNotEmpty ? 1 : 0)) {
      setState(() => error = '群公告内容已达上限，请删除部分图片后重试');
      return;
    }
    setState(() => busy = true);
    try {
      late final Uint8List bytes;
      late final String name;
      if (widget.pickImage != null) {
        final file = await widget.pickImage!();
        if (file == null || !current()) return;
        if (await file.length() > maxAnnouncementImageBytes) {
          throw const FormatException('公告图片不能超过20MB');
        }
        if (!current()) return;
        bytes = await file.readAsBytes();
        name = file.name;
      } else {
        final selection = await Navigator.of(context, rootNavigator: true)
            .push<({List<GalleryPhoto> photos, bool original, bool flash})>(
                MotionPageRoute(
                    builder: (_) => const ImagePickerPage(
                          photosOnly: true,
                          maxCount: 1,
                          showOriginalToggle: false,
                          confirmLabel: '添加',
                        )));
        if (selection == null || selection.photos.isEmpty || !current()) {
          return;
        }
        final photo = selection.photos.single;
        if (photo.isVideo) throw const FormatException('群公告仅支持图片');
        bytes = await photo.compressedBytes();
        name = isGifBytes(bytes)
            ? '公告图片.gif'
            : '公告图片.${switch (photo.mimeType.toLowerCase()) {
                'image/png' => 'png',
                'image/webp' => 'webp',
                _ => 'jpg',
              }}';
      }
      if (!current()) return;
      if (bytes.length > maxAnnouncementImageBytes) {
        throw const FormatException('公告图片不能超过20MB');
      }
      final total = blocks!
          .fold<int>(0, (sum, block) => sum + (block.localBytes?.length ?? 0));
      if (total + bytes.length > maxAnnouncementDraftImageBytes) {
        throw const FormatException('公告草稿图片合计不能超过40MB');
      }
      validateAnnouncementImage(bytes);
      final block = AnnouncementBlock.localImage(bytes, name);
      if (current()) {
        setState(() {
          blocks!.add(block);
        });
      }
    } on FormatException catch (failure) {
      if (current()) setState(() => error = failure.message);
    } catch (_) {
      if (current()) setState(() => error = '图片读取失败，请重试');
    } finally {
      if (current()) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            middle: const Text('群公告'),
            trailing: blocks == null || !widget.service.canEdit
                ? null
                : CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: busy
                        ? null
                        : editing
                            ? _save
                            : _edit,
                    child: Text(editing ? '发布' : '编辑'))),
        child: SafeArea(
            child: ListView(padding: const EdgeInsets.all(16), children: [
          if (error != null)
            if (!editing && !_loadRetryable)
              Text(error!, style: const TextStyle(color: WeChatColors.danger))
            else
              CupertinoButton(
                  onPressed: busy
                      ? null
                      : editing
                          ? _save
                          : _load,
                  child: Text(error!,
                      style: const TextStyle(color: WeChatColors.danger))),
          if (blocks == null && error == null)
            const CupertinoActivityIndicator(),
          if (!editing && _canReplaceUnreadable && widget.service.canEdit)
            CupertinoButton(
                onPressed: busy ? null : _replaceUnreadable,
                child: const Text('重新编写')),
          if (!editing && blocks?.isEmpty == true) const Text('暂无群公告'),
          if (!editing && _document?.publisherName != null)
            Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                    '${_document!.publisherName} · ${_publicationTime(_document!.publishedAt!)}',
                    style: const TextStyle(
                        fontSize: 13, color: WeChatColors.textSecondary))),
          if (editing)
            Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: CupertinoTextField(
                    key: const Key('group-announcement-text'),
                    controller: input,
                    minLines: 10,
                    maxLines: null,
                    maxLength: 5000,
                    padding: const EdgeInsets.all(14),
                    placeholder: '输入公告内容')),
          if (blocks != null)
            for (var i = 0; i < blocks!.length; i++)
              Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (blocks![i].localBytes != null)
                          Image(
                              image: boundedChatImageProvider(
                                  blocks![i].localBytes!),
                              fit: BoxFit.contain)
                        else if (blocks![i].isImage)
                          _AnnouncementImage(
                              service: widget.service,
                              eventId: blocks![i].value)
                        else if (!editing)
                          Text(blocks![i].value,
                              style:
                                  const TextStyle(fontSize: 16, height: 1.6)),
                        if (editing && blocks![i].isImage)
                          CupertinoButton(
                              onPressed: busy
                                  ? null
                                  : () {
                                      setState(() {
                                        blocks!.removeAt(i);
                                      });
                                    },
                              child: const Text('删除图片',
                                  style:
                                      TextStyle(color: WeChatColors.danger))),
                      ])),
          if (editing)
            Align(
              alignment: Alignment.centerLeft,
              child: CupertinoButton(
                  key: const Key('group-announcement-add-image'),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  onPressed: busy ? null : _image,
                  child: const Icon(CupertinoIcons.photo_on_rectangle,
                      semanticLabel: '添加图片')),
            ),
          if (busy) const CupertinoActivityIndicator(),
        ])),
      );

  String _publicationTime(DateTime timestamp) {
    final local = timestamp.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

final class _AnnouncementImage extends StatefulWidget {
  const _AnnouncementImage({required this.service, required this.eventId});
  final GroupAnnouncementService service;
  final String eventId;
  @override
  State<_AnnouncementImage> createState() => _AnnouncementImageState();
}

final class _AnnouncementImageState extends State<_AnnouncementImage> {
  late Future<Uint8List> bytes = widget.service.loadImage(widget.eventId);
  StreamSubscription<void>? _subscription;
  bool _failed = false;
  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _subscription = widget.service.changes.listen((_) {
      if (!mounted || !_failed) return;
      setState(() {
        _failed = false;
        bytes = widget.service.loadImage(widget.eventId);
      });
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _AnnouncementImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) {
      _subscription?.cancel();
      _listen();
    }
    if (oldWidget.eventId != widget.eventId ||
        !identical(oldWidget.service, widget.service)) {
      _failed = false;
      bytes = widget.service.loadImage(widget.eventId);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
      future: bytes,
      builder: (context, snapshot) {
        _failed = snapshot.hasError;
        return snapshot.hasData
            ? Image(
                image: boundedChatImageProvider(snapshot.data!),
                fit: BoxFit.contain)
            : SizedBox(
                height: 160,
                child: Center(
                    child: snapshot.hasError
                        ? CupertinoButton(
                            onPressed: () => setState(() => bytes =
                                widget.service.loadImage(widget.eventId)),
                            child: const Text('图片加载失败，点击重试'))
                        : const CupertinoActivityIndicator()));
      });
}

final class GroupAnnouncementBanner extends StatefulWidget {
  const GroupAnnouncementBanner(
      {super.key, required this.service, this.dismissalScope});
  final GroupAnnouncementService service;

  /// Stable account/room scope. Matrix-backed banners derive this themselves.
  final String? dismissalScope;
  @override
  State<GroupAnnouncementBanner> createState() =>
      _GroupAnnouncementBannerState();
}

final class _GroupAnnouncementBannerState
    extends State<GroupAnnouncementBanner> {
  GroupAnnouncement value = const GroupAnnouncement([]);
  String? _dismissedPublication;
  int _loadEpoch = 0;
  StreamSubscription<dynamic>? subscription;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
    subscription = widget.service.changes.listen((_) {
      unawaited(_load());
    });
  }

  @override
  void didUpdateWidget(covariant GroupAnnouncementBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.service, widget.service) &&
        oldWidget.dismissalScope == widget.dismissalScope) {
      return;
    }
    subscription?.cancel();
    value = const GroupAnnouncement([]);
    _dismissedPublication = null;
    subscription = widget.service.changes.listen((_) => unawaited(_load()));
    unawaited(_load());
  }

  Future<void> _load() async {
    final epoch = ++_loadEpoch;
    try {
      final next = await widget.service.load();
      String? dismissed;
      try {
        final key = _dismissalKey;
        if (key != null) {
          final preferences = await SharedPreferences.getInstance();
          dismissed = preferences.getString(key);
        }
      } catch (_) {
        // A local preference failure must not suppress a readable notice.
      }
      if (mounted && epoch == _loadEpoch) {
        setState(() {
          value = next;
          _dismissedPublication ??= dismissed;
        });
      }
    } catch (_) {/* Preserve the last successfully decrypted announcement. */}
  }

  String? get _dismissalKey {
    final service = widget.service;
    final scope = widget.dismissalScope ??
        (service is MatrixGroupAnnouncementService
            ? jsonEncode([service.room.client.userID, service.room.id])
            : null);
    if (scope == null) return null;
    return 'group_announcement_dismissed_v1:$scope';
  }

  String get _publicationIdentity {
    final id = value.publicationId;
    if (id != null) return id;
    // Legacy room topics have no document event ID. Persist only a digest,
    // never the announcement text, in local preferences.
    final body = value.blocks
        .map((block) => '${block.isImage ? 'i' : 't'}:${block.value}')
        .join('\u0000');
    return sha256
        .convert(utf8.encode(
            '${value.publishedAt?.toUtc().microsecondsSinceEpoch ?? 0}:$body'))
        .toString();
  }

  Future<void> _dismiss() async {
    final identity = _publicationIdentity;
    setState(() => _dismissedPublication = identity);
    try {
      final key = _dismissalKey;
      if (key == null) return;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(key, identity);
    } catch (_) {
      // Keep the notice hidden for this room session if storage is unavailable.
    }
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      !value.isEffective || _dismissedPublication == _publicationIdentity
          ? const SizedBox.shrink()
          : Container(
              key: const Key('group-announcement-banner'),
              decoration: BoxDecoration(
                  color: WeChatColors.resolve(
                      context, WeChatColors.announcementSurface)),
              child: Row(children: [
                Expanded(
                    child: CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        onPressed: () async {
                          await Navigator.push(
                              context,
                              MotionPageRoute<void>(
                                  builder: (_) => GroupAnnouncementPage(
                                      service: widget.service)));
                          await _load();
                        },
                        child: Row(children: [
                          const Icon(CupertinoIcons.speaker_2,
                              size: 18, color: WeChatColors.warning),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(value.preview,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: WeChatColors.resolveTextPrimary(
                                          context)))),
                          const Icon(CupertinoIcons.chevron_forward, size: 14),
                        ]))),
                Tooltip(
                    message: '不再提醒',
                    child: CupertinoButton(
                        key: const Key('group-announcement-dismiss'),
                        padding: const EdgeInsets.fromLTRB(8, 10, 16, 10),
                        onPressed: _dismiss,
                        child: Icon(CupertinoIcons.clear,
                            size: 17,
                            color: WeChatColors.resolveTextPrimary(context)))),
              ]));
}
