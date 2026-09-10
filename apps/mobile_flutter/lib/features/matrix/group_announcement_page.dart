import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' show MatrixException;
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/chat/contain_image_bubble.dart' show boundedChatImageProvider;
import '../../ui/foundation/wechat_tokens.dart';
import 'group_announcement_service.dart';

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
  final inputs = <int, TextEditingController>{};
  bool editing = false;
  bool busy = false;
  String? error;
  bool _loadRetryable = false;
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
    for (final input in inputs.values) {
      input.dispose();
    }
    inputs.clear();
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
    _listen();
    unawaited(_load());
  }

  @override
  void dispose() {
    _subscription?.cancel();
    for (final input in inputs.values) {
      input.dispose();
    }
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
        });
      }
    } catch (failure) {
      if (mounted && epoch == _loadEpoch) {
        setState(() {
          final status =
              failure is MatrixException ? failure.response?.statusCode : null;
          _loadRetryable = failure is SocketException ||
              failure is TimeoutException ||
              failure is http.ClientException ||
              status == 408 ||
              status == 429 ||
              (status != null && status >= 500 && status < 600);
          error = _loadRetryable
              ? '公告加载失败，请重试'
              : failure is FormatException
                  ? '公告格式异常，暂无法显示'
                  : failure is StateError && failure.message == '仅群成员可查看公告'
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

  void _edit() {
    for (final input in inputs.values) {
      input.dispose();
    }
    inputs.clear();
    if (blocks!.isEmpty) blocks!.add(const AnnouncementBlock.text(''));
    for (var i = 0; i < blocks!.length; i++) {
      if (!blocks![i].isImage) {
        inputs[i] = TextEditingController(text: blocks![i].value);
      }
    }
    setState(() => editing = true);
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
        for (var i = 0; i < blocks!.length; i++)
          blocks![i].isImage
              ? blocks![i]
              : AnnouncementBlock.text(inputs[i]!.text)
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
    if (blocks!.length >= maxAnnouncementBlocks) {
      setState(() => error = '群公告最多100段，请删除部分内容后重试');
      return;
    }
    setState(() => busy = true);
    try {
      final file = await (widget.pickImage?.call() ??
          ImagePicker().pickImage(
              source: ImageSource.gallery, maxWidth: 1600, maxHeight: 1600));
      if (file == null || !current()) return;
      final length = await file.length();
      if (!current()) return;
      if (length > maxAnnouncementImageBytes) {
        throw const FormatException('公告图片不能超过20MB');
      }
      final total = blocks!
          .fold<int>(0, (sum, block) => sum + (block.localBytes?.length ?? 0));
      if (total + length > maxAnnouncementDraftImageBytes) {
        throw const FormatException('公告草稿图片合计不能超过40MB');
      }
      final bytes = await file.readAsBytes();
      if (!current()) return;
      validateAnnouncementImage(bytes);
      final block = AnnouncementBlock.localImage(bytes, file.name);
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
          if (blocks?.isEmpty == true) const Text('暂无群公告'),
          if (!editing && _document?.publisherName != null)
            Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                    '${_document!.publisherName} · ${_publicationTime(_document!.publishedAt!)}',
                    style: const TextStyle(
                        fontSize: 13, color: WeChatColors.textSecondary))),
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
                        else if (editing)
                          CupertinoTextField(
                              controller: inputs[i],
                              minLines: 3,
                              maxLines: null,
                              maxLength: 5000,
                              placeholder: '输入公告内容')
                        else
                          Text(blocks![i].value,
                              style:
                                  const TextStyle(fontSize: 16, height: 1.6)),
                        if (editing)
                          CupertinoButton(
                              onPressed: busy
                                  ? null
                                  : () {
                                      setState(() {
                                        blocks!.removeAt(i);
                                        inputs.remove(i)?.dispose();
                                        final shifted = {
                                          for (final entry in inputs.entries)
                                            (entry.key > i
                                                ? entry.key - 1
                                                : entry.key): entry.value
                                        };
                                        inputs
                                          ..clear()
                                          ..addAll(shifted);
                                      });
                                    },
                              child: const Text('删除此段',
                                  style:
                                      TextStyle(color: WeChatColors.danger))),
                      ])),
          if (editing)
            Row(children: [
              CupertinoButton(
                  onPressed: busy
                      ? null
                      : () => setState(() {
                            if (blocks!.length >= maxAnnouncementBlocks) {
                              error = '群公告最多100段，请删除部分内容后重试';
                              return;
                            }
                            inputs[blocks!.length] = TextEditingController();
                            blocks!.add(const AnnouncementBlock.text(''));
                          }),
                  child: const Text('添加文字')),
              CupertinoButton(
                  onPressed: busy ? null : _image, child: const Text('添加图片')),
            ]),
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
  @override
  void didUpdateWidget(covariant _AnnouncementImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.eventId != widget.eventId) {
      bytes = widget.service.loadImage(widget.eventId);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
      future: bytes,
      builder: (context, snapshot) => snapshot.hasData
          ? Image(
              image: boundedChatImageProvider(snapshot.data!),
              fit: BoxFit.contain)
          : SizedBox(
              height: 160,
              child: Center(
                  child: snapshot.hasError
                      ? CupertinoButton(
                          onPressed: () => setState(() =>
                              bytes = widget.service.loadImage(widget.eventId)),
                          child: const Text('图片加载失败，点击重试'))
                      : const CupertinoActivityIndicator())));
}

final class GroupAnnouncementBanner extends StatefulWidget {
  const GroupAnnouncementBanner({super.key, required this.service});
  final GroupAnnouncementService service;
  @override
  State<GroupAnnouncementBanner> createState() =>
      _GroupAnnouncementBannerState();
}

final class _GroupAnnouncementBannerState
    extends State<GroupAnnouncementBanner> {
  GroupAnnouncement value = const GroupAnnouncement([]);
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
    if (identical(oldWidget.service, widget.service)) return;
    subscription?.cancel();
    value = const GroupAnnouncement([]);
    subscription = widget.service.changes.listen((_) => unawaited(_load()));
    unawaited(_load());
  }

  Future<void> _load() async {
    final epoch = ++_loadEpoch;
    try {
      final next = await widget.service.load();
      if (mounted && epoch == _loadEpoch) setState(() => value = next);
    } catch (_) {/* Preserve the last successfully decrypted announcement. */}
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !value.isEffective
      ? const SizedBox.shrink()
      : CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          onPressed: () async {
            await Navigator.push(
                context,
                CupertinoPageRoute<void>(
                    builder: (_) =>
                        GroupAnnouncementPage(service: widget.service)));
            await _load();
          },
          child: Row(children: [
            const Icon(CupertinoIcons.speaker_2, size: 18),
            const SizedBox(width: 8),
            Expanded(
                child: Text(value.preview,
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
            const Icon(CupertinoIcons.chevron_forward, size: 14)
          ]));
}
