import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/business_api_client.dart';
import 'moment_models.dart';
import 'moment_image_preprocessor.dart';

Future<MomentCommentView?> showMomentCommentComposer(BuildContext context,
        {required BusinessApiClient api,
        required String momentId,
        MomentCommentView? parent}) =>
    showCupertinoModalPopup<MomentCommentView>(
        context: context,
        builder: (_) =>
            _CommentComposer(api: api, momentId: momentId, parent: parent));

class _CommentComposer extends StatefulWidget {
  const _CommentComposer(
      {required this.api, required this.momentId, this.parent});
  final BusinessApiClient api;
  final String momentId;
  final MomentCommentView? parent;
  @override
  State<_CommentComposer> createState() => _CommentComposerState();
}

class _CommentComposerState extends State<_CommentComposer> {
  final text = TextEditingController();
  Uint8List? image;
  String? uploadedUrl;
  String? error;
  bool busy = false;
  bool showEmoji = false;
  String? requestKey;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> pick() async {
    try {
      final selected =
          await ImagePicker().pickImage(source: ImageSource.gallery);
      if (selected == null) return;
      final processed =
          await MomentImagePreprocessor().process(await selected.readAsBytes());
      if (mounted) {
        setState(() {
          image = processed;
          uploadedUrl = null;
          requestKey = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '图片读取失败，请重试');
    }
  }

  Future<void> send() async {
    if (busy || (text.text.trim().isEmpty && image == null)) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (image != null && uploadedUrl == null) {
        final upload = await widget.api.beginMomentUpload(
            fileName: 'comment.jpg',
            mimeType: 'image/jpeg',
            byteSize: image!.length);
        final id = upload['id'].toString();
        await widget.api.putMomentUpload(id, image!, 'image/jpeg');
        final complete = await widget.api.completeMomentUpload(id);
        if (complete['media_url'] == null) {
          throw StateError('Missing media URL');
        }
        uploadedUrl = id;
      }
      requestKey ??= widget.api.newIdempotencyKey();
      final response = await widget.api.commentMoment(
          widget.momentId, text.text.trim(),
          parentId: widget.parent?.id,
          imageUploadIds: uploadedUrl == null ? const [] : [uploadedUrl!],
          idempotencyKey: requestKey);
      if (mounted) Navigator.pop(context, MomentCommentView.fromJson(response));
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e is BusinessApiException ? e.message : '发送失败，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !busy,
        child: CupertinoPopupSurface(
            child: Padding(
          padding: EdgeInsets.fromLTRB(
              12, 12, 12, MediaQuery.viewInsetsOf(context).bottom + 12),
          child: SafeArea(
              top: false,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(widget.parent == null
                    ? '评论'
                    : '回复 ${widget.parent!.author.displayName}'),
                const SizedBox(height: 10),
                CupertinoTextField(
                    key: const Key('moment-comment-input'),
                    controller: text,
                    autofocus: true,
                    enabled: !busy,
                    maxLength: 1000,
                    minLines: 1,
                    maxLines: 4,
                    placeholder: '说点什么…',
                    onChanged: (_) => setState(() => requestKey = null)),
                if (image != null)
                  Row(children: [
                    Image.memory(image!,
                        width: 48, height: 48, fit: BoxFit.cover),
                    CupertinoButton(
                        onPressed: busy
                            ? null
                            : () => setState(() {
                                  image = null;
                                  uploadedUrl = null;
                                  requestKey = null;
                                }),
                        child: const Text('移除')),
                  ]),
                if (error != null)
                  Text(error!,
                      style: const TextStyle(color: CupertinoColors.systemRed)),
                Row(children: [
                  CupertinoButton(
                      onPressed: busy
                          ? null
                          : () => setState(() => showEmoji = !showEmoji),
                      child: const Icon(CupertinoIcons.smiley)),
                  CupertinoButton(
                      onPressed: busy ? null : pick,
                      child: const Icon(CupertinoIcons.photo)),
                  const Spacer(),
                  CupertinoButton(
                      key: const Key('moment-comment-submit'),
                      onPressed:
                          busy || (text.text.trim().isEmpty && image == null)
                              ? null
                              : send,
                      child: busy
                          ? const CupertinoActivityIndicator()
                          : const Text('发送')),
                ]),
                if (showEmoji)
                  Wrap(children: [
                    for (final emoji in [
                      '😀',
                      '😂',
                      '🥰',
                      '👍',
                      '❤️',
                      '🎉',
                      '🙏',
                      '🌹'
                    ])
                      CupertinoButton(
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                    final selection = text.selection;
                                    final start = selection.isValid
                                        ? selection.start
                                        : text.text.length;
                                    final end = selection.isValid
                                        ? selection.end
                                        : start;
                                    text.value = TextEditingValue(
                                        text: text.text
                                            .replaceRange(start, end, emoji),
                                        selection: TextSelection.collapsed(
                                            offset: start + emoji.length));
                                    requestKey = null;
                                  }),
                          child: Text(emoji))
                  ]),
              ])),
        )),
      );
}
