import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';

/// A codec seam for deterministic lifecycle tests; production uses the engine codec.
abstract interface class EmojiFrameCodec {
  int get frameCount;
  Future<EmojiDecodedFrame> nextFrame();
  void dispose();
}

final class EmojiDecodedFrame {
  const EmojiDecodedFrame(this.image, this.duration);
  final ui.Image image;
  final Duration duration;
}

typedef EmojiCodecLoader = Future<EmojiFrameCodec> Function(
    File file, int size);

final class _EngineCodec implements EmojiFrameCodec {
  _EngineCodec(this.codec);
  final ui.Codec codec;
  @override
  int get frameCount => codec.frameCount;
  @override
  Future<EmojiDecodedFrame> nextFrame() async {
    final frame = await codec.getNextFrame();
    return EmojiDecodedFrame(frame.image, frame.duration);
  }

  @override
  void dispose() => codec.dispose();
}

/// Visible emoji are not subject to the general animated-media count ceiling.
/// Active and short-lived idle entries retain only their current frame. Startup and frame decode share a bounded
/// FIFO queue, so a grid cannot create an unbounded burst of engine work.
final class SharedEmojiPlayerPool with WidgetsBindingObserver {
  SharedEmojiPlayerPool(
      {EmojiCodecLoader? loader,
      this.maxConcurrentDecodes = 2,
      this.maxIdleEntries = 64,
      this.maxIdleFrameBytes = 4 * 1024 * 1024,
      this.maxIdleCodecs = 8,
      this.idleTtl = const Duration(seconds: 30)})
      : assert(maxConcurrentDecodes > 0),
        assert(maxIdleEntries >= 0 &&
            maxIdleFrameBytes >= 0 &&
            maxIdleCodecs >= 0),
        assert(idleTtl > Duration.zero),
        _loader = loader ?? _load {
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }
  static final instance = SharedEmojiPlayerPool();
  static int decodeSize(int size) => ((size.clamp(1, 256) + 15) ~/ 16) * 16;
  static Future<EmojiFrameCodec> _load(File file, int size) async =>
      _EngineCodec(await ui.instantiateImageCodec(await file.readAsBytes(),
          targetWidth: size, targetHeight: size, allowUpscaling: false));

  static Future<ui.Image> _boundImage(ui.Image image, int size) async {
    if (image.width <= size && image.height <= size) return image;
    // Some native animated WebP codecs ignore requested target dimensions.
    // Enforce the retained/painted bitmap bound after decode as well. This does
    // not bound the engine codec's source-size scratch buffers or decode CPU.
    final scale =
        size / (image.width > image.height ? image.width : image.height);
    final width = (image.width * scale).round().clamp(1, size);
    final height = (image.height * scale).round().clamp(1, size);
    final recorder = ui.PictureRecorder();
    ui.Picture? picture;
    try {
      ui.Canvas(recorder).drawImageRect(
          image,
          ui.Rect.fromLTWH(
              0, 0, image.width.toDouble(), image.height.toDouble()),
          ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          ui.Paint()..filterQuality = ui.FilterQuality.low);
      picture = recorder.endRecording();
      return await picture.toImage(width, height);
    } finally {
      picture?.dispose();
      image.dispose();
    }
  }

  final EmojiCodecLoader _loader;
  final int maxConcurrentDecodes;
  final int maxIdleEntries, maxIdleFrameBytes, maxIdleCodecs;
  final Duration idleTtl;
  final LinkedHashMap<String, _Entry> _idle = LinkedHashMap();
  int _warmHits = 0, _cacheMisses = 0;
  int _bytes(_Entry e) =>
      e.frame == null ? 0 : e.frame!.width * e.frame!.height * 4;
  String _key(EmojiPlayback h) => '${h._file.absolute.path}@${h._size}';
  ui.Image? _cached(EmojiPlayback h) => _entries[_key(h)]?.frame;
  void _trimIdle() {
    while (_idle.length > maxIdleEntries ||
        _idle.values.fold<int>(0, (n, e) => n + _bytes(e)) >
            maxIdleFrameBytes) {
      _release(_idle.values.first);
    }
    final codecs = _idle.values
        .where((e) => e.codec != null && !e.dropCodec)
        .toList()
      ..sort((a, b) => (a.busy ? 1 : 0).compareTo(b.busy ? 1 : 0));
    for (final e in codecs
        .take((codecs.length - maxIdleCodecs).clamp(0, codecs.length))) {
      e.dropCodec = true;
      if (!e.busy) {
        e.codec?.dispose();
        e.codec = null;
      }
    }
  }

  void _idleEntry(_Entry e) {
    e.timer?.cancel();
    e.timer = null;
    _queue.remove(e);
    e.queued = false;
    if (_disposed ||
        !_foreground ||
        _pressureResume != null ||
        e.frame == null ||
        e.failed) {
      _release(e);
      return;
    }
    _idle.remove(e.key);
    _idle[e.key] = e;
    e.expiry?.cancel();
    e.expiry = Timer(idleTtl, () => _release(e));
    _trimIdle();
  }

  void _clear() {
    for (final e in _entries.values.toList()) {
      _release(e);
    }
  }

  final Map<String, _Entry> _entries = {};
  final Set<EmojiPlayback> _handles = {};
  final Queue<_Entry> _queue = Queue();
  int _inFlight = 0, _peak = 0, _creates = 0, _frames = 0;
  bool _disposed = false;
  bool _foreground = true;
  Timer? _pressureResume;

  EmojiPlayback subscribe(File file, int physicalSize) {
    if (_disposed) throw StateError('Emoji pool disposed');
    final handle = EmojiPlayback._(this, file, decodeSize(physicalSize));
    _handles.add(handle);
    return handle;
  }

  Map<String, Object> get diagnostics => {
        'activeEntries':
            _entries.values.where((e) => e.handles.isNotEmpty).length,
        'idleEntries': _idle.length,
        'activeFrameBytes': _entries.values
            .where((e) => e.handles.isNotEmpty)
            .fold<int>(0, (n, e) => n + _bytes(e)),
        'idleFrameBytes': _idle.values.fold<int>(0, (n, e) => n + _bytes(e)),
        'totalFrameBytes':
            _entries.values.fold<int>(0, (n, e) => n + _bytes(e)),
        'idleCodecCount': _idle.values.where((e) => e.codec != null).length,
        'warmHits': _warmHits,
        'cacheMisses': _cacheMisses,
        'subscribers': _handles.where((h) => h._visible).length,
        'inFlight': _inFlight,
        'peakInFlight': _peak,
        'codecCreates': _creates,
        'framesEmitted': _frames,
        'activeFrameCounts': {
          for (final e in _entries.values.where((e) => e.handles.isNotEmpty))
            e.key: e.frames
        },
        'decodeSizes': _entries.values
            .where((e) => e.handles.isNotEmpty)
            .map((e) => e.size)
            .toList(),
        'decodedImageBytes': _entries.values
            .where((e) => e.handles.isNotEmpty)
            .fold<int>(
                0,
                (sum, e) =>
                    sum +
                    (e.frame == null
                        ? 0
                        : e.frame!.width * e.frame!.height * 4)),
      };

  void _attach(EmojiPlayback handle) {
    if (_disposed || !_foreground || _pressureResume != null) return;
    final key = _key(handle);
    if (_idle.remove(key) != null) {
      _warmHits++;
    } else if (!_entries.containsKey(key)) {
      _cacheMisses++;
    }
    final entry = _entries.putIfAbsent(
        key, () => _Entry(key, handle._file, handle._size));
    entry.expiry?.cancel();
    entry.expiry = null;
    entry.dropCodec = false;
    handle._entry = entry;
    entry.handles.add(handle);
    if (!entry.failed && entry.timer == null) {
      _enqueue(entry);
    }
  }

  void _detach(EmojiPlayback handle) {
    final entry = handle._entry;
    handle._entry = null;
    if (entry == null) return;
    entry.handles.remove(handle);
    if (entry.handles.isEmpty) _idleEntry(entry);
  }

  void _release(_Entry entry) {
    entry.alive = false;
    if (identical(_entries[entry.key], entry)) _entries.remove(entry.key);
    _idle.remove(entry.key);
    entry.expiry?.cancel();
    _queue.remove(entry);
    entry.timer?.cancel();
    entry.frame?.dispose();
    entry.frame = null;
    // A codec must not be disposed while its asynchronous getNextFrame is pending.
    if (!entry.busy) {
      entry.codec?.dispose();
      entry.codec = null;
    }
  }

  void _enqueue(_Entry entry) {
    if (!entry.alive ||
        entry.handles.isEmpty ||
        entry.busy ||
        entry.queued ||
        _disposed) {
      return;
    }
    entry.queued = true;
    _queue.add(entry);
    _drain();
  }

  void _drain() {
    while (
        !_disposed && _inFlight < maxConcurrentDecodes && _queue.isNotEmpty) {
      final entry = _queue.removeFirst()..queued = false;
      if (!entry.alive || entry.handles.isEmpty) continue;
      entry.busy = true;
      _inFlight++;
      if (_inFlight > _peak) _peak = _inFlight;
      unawaited(_decode(entry));
    }
  }

  Future<void> _decode(_Entry entry) async {
    try {
      if (entry.codec == null) {
        entry.codec = await _loader(entry.file, entry.size);
        _creates++;
      }
      if (!entry.alive) return;
      final next = await entry.codec!.nextFrame();
      if (!entry.alive) {
        next.image.dispose();
        return;
      }
      final image = await _boundImage(next.image, entry.size);
      if (!entry.alive) {
        image.dispose();
        return;
      }
      if (entry.handles.isEmpty) {
        image.dispose();
        return;
      }
      final old = entry.frame;
      entry.frame = image;
      entry.frames++;
      _frames++;
      for (final handle in entry.handles.toList()) {
        handle._publish();
      }
      old?.dispose();
      if (entry.alive &&
          entry.handles.isNotEmpty &&
          entry.codec!.frameCount > 1) {
        entry.timer = Timer(
            next.duration < const Duration(milliseconds: 16)
                ? const Duration(milliseconds: 16)
                : next.duration, () {
          entry.timer = null;
          _enqueue(entry);
        });
      }
    } catch (_) {
      if (entry.alive) {
        entry.failed = true;
        entry.frame?.dispose();
        entry.frame = null;
        for (final handle in entry.handles.toList()) {
          handle._publish();
        }
      }
    } finally {
      entry.busy = false;
      if (!entry.alive || entry.failed || entry.dropCodec) {
        entry.codec?.dispose();
        entry.codec = null;
      }
      if (entry.alive && entry.handles.isEmpty) {
        if (entry.failed) {
          _release(entry);
        } else {
          _trimIdle();
        }
      }
      _inFlight--;
      _drain();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    _foreground = foreground;
    if (foreground) {
      for (final handle in _handles.toList()) {
        if (handle._visible) _attach(handle);
      }
    } else {
      // A paused engine may never render another widget frame. Stop decoding
      // synchronously rather than waiting for visibility setState to rebuild.
      for (final handle in _handles.toList()) {
        _detach(handle);
      }
      _clear();
      for (final handle in _handles.toList()) {
        handle._publish();
      }
    }
  }

  @override
  void didHaveMemoryPressure() {
    if (_disposed) return;
    _pressureResume?.cancel();
    _pressureResume = Timer(const Duration(days: 1), () {});
    // Drop current bitmaps immediately, then allow visible subscriptions to
    // restart gradually through the same bounded queue.
    for (final handle in _handles.toList()) {
      _detach(handle);
    }
    _clear();
    for (final handle in _handles.toList()) {
      handle._publish();
    }
    _pressureResume?.cancel();
    _pressureResume = Timer(const Duration(milliseconds: 100), () {
      _pressureResume = null;
      for (final handle in _handles.toList()) {
        if (handle._visible) _attach(handle);
      }
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _pressureResume?.cancel();
    _pressureResume = null;
    for (final handle in _handles.toList()) {
      handle.dispose();
    }
    _clear();
  }
}

final class _Entry {
  _Entry(this.key, this.file, this.size);
  final String key;
  final File file;
  final int size;
  final Set<EmojiPlayback> handles = {};
  EmojiFrameCodec? codec;
  ui.Image? frame;
  Timer? timer, expiry;
  bool dropCodec = false;
  bool alive = true, busy = false, queued = false, failed = false;
  int frames = 0;
}

/// Notifications are consumed by CustomPainter.repaint, never by frame setState.
final class EmojiPlayback extends ChangeNotifier {
  EmojiPlayback._(this._pool, this._file, this._size);
  final SharedEmojiPlayerPool _pool;
  final File _file;
  final int _size;
  _Entry? _entry;
  bool _visible = false, _disposed = false;
  ui.Image? get frame =>
      _disposed ? null : (_entry?.frame ?? _pool._cached(this));
  bool get failed => _entry?.failed ?? false;
  void setVisible(bool value) {
    if (_disposed || _visible == value) return;
    _visible = value;
    if (value) {
      _pool._attach(this);
    } else {
      _pool._detach(this);
    }
    _publish();
  }

  void _publish() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pool._detach(this);
    _pool._handles.remove(this);
    super.dispose();
  }
}
