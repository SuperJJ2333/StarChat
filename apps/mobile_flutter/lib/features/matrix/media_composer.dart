import 'package:flutter/cupertino.dart';
import 'media_message_service.dart';

final class MediaComposer extends StatefulWidget {
  const MediaComposer({super.key, required this.service, required this.roomId});
  final MediaMessageService service;
  final String roomId;
  @override
  State<MediaComposer> createState() => _MediaComposerState();
}

final class _MediaComposerState extends State<MediaComposer> {
  String? status;
  Future<void> _run(Future<String> Function() action) async {
    try {
      final id = await action();
      setState(() =>
          status = '已加密发送：${id.substring(0, id.length > 12 ? 12 : id.length)}');
    } catch (e) {
      setState(() => status = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) =>
      CupertinoListSection.insetGrouped(header: const Text('加密媒体'), children: [
        CupertinoListTile(
            leading: const Icon(CupertinoIcons.photo),
            title: const Text('图片'),
            onTap: () => _run(() => widget.service.sendImage(widget.roomId))),
        CupertinoListTile(
            leading: const Icon(CupertinoIcons.doc),
            title: const Text('文件'),
            onTap: () => _run(() => widget.service.sendFile(widget.roomId))),
        CupertinoListTile(
            leading: const Icon(CupertinoIcons.mic),
            title: const Text('语音消息'),
            subtitle: const Text('录音后加密上传'),
            onTap: () => setState(() => status = '请在录音控制页开始/结束录音')),
        if (status != null) CupertinoListTile(title: Text(status!))
      ]);
}
