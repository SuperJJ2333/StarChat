import 'dart:async';
import 'dart:typed_data';

enum MediaLoadPriority { interactive, visible, prefetch, background }

final class MediaLoadCanceled extends StateError {
  MediaLoadCanceled() : super('Media load canceled');
}

final class MediaLoadLease {
  MediaLoadLease._(this._cancel, this.priority);
  final void Function(MediaLoadLease) _cancel;
  final MediaLoadPriority priority;
  final _completion = Completer<Uint8List>();
  Future<Uint8List> get value => _completion.future;
  void cancel() {
    if (!_completion.isCompleted) _cancel(this);
  }
}

final class _MediaTask {
  _MediaTask(this.key, this.load, this.isVideo, this.order);
  final String key;
  final Future<Uint8List> Function() load;
  final bool isVideo;
  final int order;
  final consumers = <MediaLoadLease>{};
  bool running = false;
  int boost = MediaLoadPriority.background.index;
  int get priority => consumers.fold(
      boost,
      (best, lease) =>
          lease.priority.index < best ? lease.priority.index : best);
}

/// Bounds source work, independently of RAM/disk hits in the cache repository.
/// Active native requests retain their slot until completion even if every
/// consumer leaves; canceling a Future cannot safely abort that native work.
final class MediaLoadScheduler {
  MediaLoadScheduler({this.maxConcurrent = 3, this.maxVideos = 1}) {
    if (maxConcurrent < 1 || maxVideos < 1 || maxVideos > maxConcurrent) {
      throw ArgumentError('Invalid media concurrency limits');
    }
  }
  final int maxConcurrent, maxVideos;
  final _tasks = <String, _MediaTask>{};
  int _active = 0, _videos = 0, _sequence = 0;
  bool _scheduled = false;

  MediaLoadLease request(String key, Future<Uint8List> Function() load,
      {MediaLoadPriority priority = MediaLoadPriority.visible,
      bool isVideo = false}) {
    final task = _tasks.putIfAbsent(
        key, () => _MediaTask(key, load, isVideo, _sequence++));
    final lease = MediaLoadLease._((lease) {
      task.consumers.remove(lease);
      lease._completion.completeError(MediaLoadCanceled());
      if (task.consumers.isEmpty && !task.running) _tasks.remove(key);
      _schedule();
    }, priority);
    task.consumers.add(lease);
    _schedule();
    return lease;
  }

  void cancelAll() {
    for (final task in _tasks.values.toList()) {
      for (final lease in task.consumers.toList()) {
        lease.cancel();
      }
    }
  }

  void promote(String key, MediaLoadPriority priority) {
    final task = _tasks[key];
    if (task != null && priority.index < task.boost) {
      task.boost = priority.index;
      _schedule();
    }
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      _pump();
    });
  }

  void _pump() {
    final pending = _tasks.values.where((task) => !task.running).toList()
      ..sort((a, b) {
        final order = a.priority.compareTo(b.priority);
        return order == 0 ? a.order.compareTo(b.order) : order;
      });
    for (final task in pending) {
      if (_active >= maxConcurrent) break;
      if (!identical(_tasks[task.key], task) || task.consumers.isEmpty) {
        continue;
      }
      if (task.isVideo && _videos >= maxVideos) continue;
      task.running = true;
      _active++;
      if (task.isVideo) _videos++;
      unawaited(_run(task));
    }
  }

  Future<void> _run(_MediaTask task) async {
    try {
      final bytes = await task.load();
      for (final lease in task.consumers) {
        lease._completion.complete(bytes);
      }
    } catch (error, stack) {
      for (final lease in task.consumers) {
        lease._completion.completeError(error, stack);
      }
    } finally {
      task.consumers.clear();
      _tasks.remove(task.key);
      _active--;
      if (task.isVideo) _videos--;
      _schedule();
    }
  }
}

final mediaLoadScheduler = MediaLoadScheduler();

const _priorityZoneKey = #chatflowMediaPriority;
const _videoZoneKey = #chatflowMediaVideo;
bool get currentMediaLoadIsVideo => Zone.current[_videoZoneKey] == true;
MediaLoadPriority get currentMediaLoadPriority =>
    Zone.current[_priorityZoneKey] as MediaLoadPriority? ??
    MediaLoadPriority.visible;

Future<T> withMediaLoadPriority<T>(
        MediaLoadPriority priority, Future<T> Function() action,
        {bool? isVideo}) =>
    runZoned(action, zoneValues: {
      _priorityZoneKey: priority,
      if (isVideo != null) _videoZoneKey: isVideo,
    });
