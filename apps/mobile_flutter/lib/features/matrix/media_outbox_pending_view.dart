import 'package:flutter/cupertino.dart';
import '../../core/outbox/media_outbox_store.dart';
import '../../core/outbox/media_outbox_recovery_service.dart';

/// A failed durable intent remains discoverable after restart, even when no
/// in-process optimistic bubble exists. This view never reads attachment bytes.
final class MediaOutboxPendingView extends StatefulWidget {
  const MediaOutboxPendingView(
      {super.key, required this.service, required this.roomId});
  final MediaOutboxRecoveryService service;
  final String roomId;
  @override
  State<MediaOutboxPendingView> createState() => _MediaOutboxPendingViewState();
}

final class _MediaOutboxPendingViewState extends State<MediaOutboxPendingView> {
  List<MediaOutboxTask> _tasks = const [];
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    widget.service.addListener(_reload);
    _reload();
  }

  @override
  void didUpdateWidget(MediaOutboxPendingView old) {
    super.didUpdateWidget(old);
    if (old.service != widget.service) {
      old.service.removeListener(_reload);
      widget.service.addListener(_reload);
    }
    _reload();
  }

  Future<void> _reload() async {
    final generation = ++_generation;
    try {
      final tasks = await widget.service.store.pending();
      if (mounted && generation == _generation) {
        setState(() => _tasks =
            tasks.where((task) => task.roomId == widget.roomId).toList());
      }
    } catch (_) {/* Keep prior tasks visible while storage is unavailable. */}
  }

  @override
  void dispose() {
    _generation++;
    widget.service.removeListener(_reload);
    super.dispose();
  }

  Future<void> _show() => showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
            title: const Text('待发附件'),
            message: const Text('附件保留在此设备。取消会停止后续重试；已经提交的消息可能仍会送达。'),
            actions: [
              for (final task in _tasks) ...[
                CupertinoActionSheetAction(
                    onPressed: () async {
                      Navigator.pop(sheetContext);
                      try {
                        await widget.service.dispatch(task, userRetry: true);
                      } catch (_) {
                        await _reload();
                      }
                    },
                    child: Column(children: [
                      Text(task.filename),
                      if (task.failure != null)
                        Text(MediaOutboxException(task.failure!).userMessage,
                            style: const TextStyle(fontSize: 13)),
                      const Text('重试此附件')
                    ])),
                CupertinoActionSheetAction(
                    isDestructiveAction: true,
                    onPressed: () async {
                      Navigator.pop(sheetContext);
                      try {
                        await widget.service.cancel(task.txid);
                      } catch (_) {
                        await _reload();
                      }
                    },
                    child: const Text('取消此附件')),
              ]
            ],
            cancelButton: CupertinoActionSheetAction(
                onPressed: () => Navigator.pop(sheetContext),
                child: const Text('返回')),
          ));
  @override
  Widget build(BuildContext context) => _tasks.isEmpty
      ? const SizedBox.shrink()
      : CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          onPressed: _show,
          child: Text('待发附件 ${_tasks.length}',
              style: const TextStyle(fontSize: 13)));
}
