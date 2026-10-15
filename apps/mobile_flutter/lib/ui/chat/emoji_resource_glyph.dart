import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/maintenance_activity.dart';
import '../../features/emoji/emoji_resource_manifest.dart';
import '../../features/emoji/emoji_resource_store.dart';
import '../../features/emoji/fluent_emoji_catalog.dart';
import '../../features/emoji/fluent_vector_emoji_catalog.dart';
import 'shared_emoji_image.dart';
import 'shared_emoji_player.dart';
import 'media_visibility.dart';

Future<EmojiResourceStore?>? _runtimeStore;
EmojiResourceStore? _readyStore;
Future<EmojiResourceStore?> _store() => _runtimeStore ??= () async {
      try {
        final root = await getApplicationSupportDirectory();
        final manifest = EmojiResourceManifest.parse(emojiManifestJson,
            expectedDigest: emojiManifestDigest);
        final store = EmojiResourceStore(
            directory: Directory('${root.path}/emoji-resources'),
            manifest: manifest);
        // Connectivity errors do not affect display. Only Wi-Fi schedules quiet prefetch.
        unawaited(store
            .prefetchWifi(
              isWifi: () async => (await Connectivity().checkConnectivity())
                  .contains(ConnectivityResult.wifi),
              networkChanges: Connectivity()
                  .onConnectivityChanged
                  .map((results) => results.contains(ConnectivityResult.wifi)),
            )
            .catchError((Object _) {}));
        _readyStore = store;
        return store;
      } catch (_) {
        return null;
      }
    }();

/// A fixed layout box from the first offline frame through verified cache arrival.
/// Every display still sends only the catalog's original Unicode character.
final class EmojiResourceGlyph extends StatefulWidget {
  const EmojiResourceGlyph(
      {super.key,
      required this.asset,
      required this.size,
      this.playOnTap = false,
      this.store,
      this.pool});
  final String asset;
  final double size;

  /// Picker tiles keep autoplay; message rows opt into explicit playback.
  final bool playOnTap;
  final EmojiResourceStore? store;
  final SharedEmojiPlayerPool? pool;
  @override
  State<EmojiResourceGlyph> createState() => _EmojiResourceGlyphState();
}

final class _EmojiResourceGlyphState extends State<EmojiResourceGlyph> {
  File? _file;
  EmojiResourceStore? _boundStore;
  String? _pinned;
  bool _visible = false, _loading = false, _playing = false;
  bool get _animate => !widget.playOnTap || _playing;
  int _generation = 0;
  String get _id => widget.asset.split('/').last.replaceAll('.webp', '');
  FluentEmoji? get _emoji {
    for (final emoji in fluentEmojis) {
      if (emoji.asset == widget.asset) return emoji;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    MaintenanceActivity.instance.install();
    _useVerified();
  }

  @override
  void didUpdateWidget(covariant EmojiResourceGlyph old) {
    super.didUpdateWidget(old);
    if (old.asset != widget.asset ||
        old.store != widget.store ||
        old.playOnTap != widget.playOnTap) {
      _generation++;
      _release();
      _file = null;
      _playing = false;
      _loading = false;
      _useVerified();
      if (_visible && _animate) unawaited(_load());
    }
  }

  void _useVerified() {
    if (!_animate || _file != null) return;
    final store = widget.store ?? _readyStore;
    final file = store?.verifiedFile(_id);
    if (file == null) {
      if (store == null || store.hasLocalCandidate(_id)) unawaited(_load());
      return;
    }
    _boundStore = store;
    _pinned = _id;
    store!.pin(_id);
    _file = file;
  }

  void _release() {
    if (_pinned != null) _boundStore?.unpin(_pinned!);
    _boundStore = null;
    _pinned = null;
  }

  Future<void> _load() async {
    if (!_animate || _loading || _file != null) return;
    _loading = true;
    final generation = _generation, id = _id;
    final store = widget.store ?? await _store();
    if (!mounted || generation != _generation) return;
    _release();
    _boundStore = store;
    _pinned = id;
    store?.pin(id);
    final file = await store?.resolve(id);
    if (!mounted || generation != _generation) return;
    _loading = false;
    setState(() {
      _file = file;
    });
  }

  @override
  void dispose() {
    _generation++;
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final emoji = _emoji;
    final vector = emoji == null ? null : vectorEmojiByChar(emoji.char);
    final unicode = Center(
        child: Text(emoji?.char ?? '◉',
            style: TextStyle(fontSize: widget.size * .75)));
    final fallback = vector != null
        ? SvgPicture.asset(vector.asset,
            width: widget.size,
            height: widget.size,
            fit: BoxFit.contain,
            placeholderBuilder: (_) => unicode)
        : unicode;
    return SizedBox(
        width: widget.size,
        height: widget.size,
        child: MediaVisibility(
          onChanged: (visible) {
            if (!mounted) return;
            if (_visible != visible) {
              setState(() {
                _visible = visible;
                if (!visible && widget.playOnTap) _playing = false;
              });
            }
            if (visible && _animate) unawaited(_load());
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.playOnTap
                ? () {
                    setState(() => _playing = !_playing);
                    if (_playing) {
                      _useVerified();
                      unawaited(_load());
                    }
                  }
                : null,
            child: !_animate || _file == null
                ? fallback
                : SharedEmojiImage(
                    file: _file!,
                    size: widget.size,
                    visible: _visible,
                    pool: widget.pool,
                    fallback: fallback,
                  ),
          ),
        ));
  }
}
