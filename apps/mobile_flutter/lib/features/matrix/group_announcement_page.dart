import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/chat/contain_image_bubble.dart' show boundedChatImageProvider;
import '../../ui/foundation/wechat_tokens.dart';
import 'group_announcement_service.dart';

final class GroupAnnouncementPage extends StatefulWidget {
  const GroupAnnouncementPage(
      {super.key, required this.service, this.pickImage});
  final Future<XFile?> Function()? pickImage;
  final MatrixGroupAnnouncementService service;
  @override
  State<GroupAnnouncementPage> createState() => _GroupAnnouncementPageState();
}

final class _GroupAnnouncementPageState extends State<GroupAnnouncementPage> {
  List<AnnouncementBlock>? blocks;
  final inputs = <int, TextEditingController>{};
  bool editing = false;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final input in inputs.values) {
      input.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final value = await widget.service.load();
      if (mounted) {
        setState(() {
          blocks = value.blocks.toList();
          error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '公告加载失败，请重试');
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
      await widget.service.save(document);
      if (mounted) Navigator.pop(context, true);
    } on FormatException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } catch (_) {
      if (mounted) setState(() => error = '发布失败，请检查权限、加密状态和网络后重试');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _image() async {
    if (blocks!.length >= maxAnnouncementBlocks) {
      setState(() => error = '群公告最多100段，请删除部分内容后重试');
      return;
    }
    setState(() => busy = true);
    try {
      final file = await (widget.pickImage?.call() ??
          ImagePicker().pickImage(
              source: ImageSource.gallery, maxWidth: 1600, maxHeight: 1600));
      if (file == null || !mounted) return;
      final length = await file.length();
      if (length > maxAnnouncementImageBytes) {
        throw const FormatException('公告图片不能超过20MB');
      }
      final total = blocks!
          .fold<int>(0, (sum, block) => sum + (block.localBytes?.length ?? 0));
      if (total + length > maxAnnouncementDraftImageBytes) {
        throw const FormatException('公告草稿图片合计不能超过40MB');
      }
      final bytes = await file.readAsBytes();
      validateAnnouncementImage(bytes);
      final block = AnnouncementBlock.localImage(bytes, file.name);
      if (mounted) {
        setState(() {
          blocks!.add(block);
        });
      }
    } on FormatException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } catch (_) {
      if (mounted) setState(() => error = '图片读取失败，请重试');
    } finally {
      if (mounted) setState(() => busy = false);
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
}

final class _AnnouncementImage extends StatefulWidget {
  const _AnnouncementImage({required this.service, required this.eventId});
  final MatrixGroupAnnouncementService service;
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
  final MatrixGroupAnnouncementService service;
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
    subscription = widget.service.room.client.onSync.stream.listen((update) {
      if (update.rooms?.join?.containsKey(widget.service.room.id) == true) {
        unawaited(_load());
      }
    });
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
