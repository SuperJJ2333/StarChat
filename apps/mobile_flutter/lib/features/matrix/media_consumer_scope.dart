import 'dart:async';

import 'media_load_scheduler.dart';

const _scopeZoneKey = #chatflowMediaConsumerScope;

final class MediaConsumerScope {
  MediaConsumerScope(
      {MediaLoadPriority priority = MediaLoadPriority.visible, this.onCancel})
      : _priority = priority;
  MediaLoadPriority _priority;
  MediaLoadPriority get priority => _priority;
  final void Function()? onCancel;
  final _priorityListeners = <void Function(MediaLoadPriority)>[];
  final _cancelListeners = <void Function()>[];
  bool _closed = false;
  bool get isActive => !_closed;
  int get debugPriorityListenerCount => _priorityListeners.length;
  int get debugCancelListenerCount => _cancelListeners.length;
  void promote(MediaLoadPriority next) {
    if (_closed || next.index >= priority.index) return;
    _priority = next;
    for (final listener in List.of(_priorityListeners)) {
      listener(next);
    }
  }

  void addPriorityListener(void Function(MediaLoadPriority) listener) =>
      _priorityListeners.add(listener);
  void removePriorityListener(void Function(MediaLoadPriority) listener) =>
      _priorityListeners.remove(listener);
  void addCancelListener(void Function() listener) =>
      _cancelListeners.add(listener);
  void removeCancelListener(void Function() listener) =>
      _cancelListeners.remove(listener);
  void cancel() => dispose();
  void dispose() {
    if (_closed) return;
    _closed = true;
    for (final listener in List.of(_cancelListeners)) {
      listener();
    }
    _cancelListeners.clear();
    _priorityListeners.clear();
    onCancel?.call();
  }

  Future<T> run<T>(Future<T> Function() action) {
    if (_closed) return Future.error(MediaLoadCanceled());
    return withMediaLoadPriority(
        _priority,
        () => runZoned(() => Future<T>.sync(action),
            zoneValues: {_scopeZoneKey: this}));
  }

  static MediaConsumerScope? get current =>
      Zone.current[_scopeZoneKey] as MediaConsumerScope?;
}

final class OwnedMediaFlight<T> {
  OwnedMediaFlight(this._source, {MediaConsumerScope? childScope})
      : childScope = childScope ??
            MediaConsumerScope(priority: MediaLoadPriority.background);
  final Future<T> Function() _source;
  final MediaConsumerScope childScope;
  final _owners = <MediaConsumerScope, Completer<T>>{};
  Future<T>? _unscoped;
  Future<T>? _running;
  bool _finished = false;
  bool _inactive = false;
  bool get isActive => !_inactive;
  bool get finished => _finished;
  void Function()? onInactive;
  Future<T> join([MediaConsumerScope? scope]) {
    if (_inactive) return Future.error(MediaLoadCanceled());
    if (scope == null) {
      childScope.promote(currentMediaLoadPriority);
      return _unscoped ??= _start();
    }
    if (!scope.isActive) return Future.error(MediaLoadCanceled());
    final existing = _owners[scope];
    if (existing != null) return existing.future;
    final owner = Completer<T>();
    _owners[scope] = owner;
    late final void Function(MediaLoadPriority) priorityListener;
    late final void Function() cancelListener;
    void remove() {
      scope.removePriorityListener(priorityListener);
      scope.removeCancelListener(cancelListener);
      if (_owners.remove(scope) != null && !owner.isCompleted) {
        owner.completeError(MediaLoadCanceled());
      }
      if (_owners.isEmpty && _unscoped == null && !_finished) {
        _inactive = true;
        childScope.cancel();
        onInactive?.call();
      }
    }

    priorityListener = (priority) => childScope.promote(priority);
    cancelListener = remove;
    childScope.promote(scope.priority);
    scope.addPriorityListener(priorityListener);
    scope.addCancelListener(cancelListener);
    _start().then((v) {
      if (!owner.isCompleted) owner.complete(v);
    }, onError: (Object e, StackTrace s) {
      if (!owner.isCompleted) owner.completeError(e, s);
    }).whenComplete(remove);
    return owner.future;
  }

  Future<T> _start() {
    final running = _running;
    if (running != null) return running;
    final completion = Completer<T>();
    _running = completion.future;
    childScope
        .run(() => _source())
        .then(completion.complete, onError: completion.completeError)
        .whenComplete(() {
      _finished = true;
      if (!_inactive) {
        _inactive = true;
        onInactive?.call();
      }
    });
    return completion.future;
  }
}
