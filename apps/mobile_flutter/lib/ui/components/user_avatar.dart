import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

import '../../core/performance_metrics.dart';
import '../foundation/avatar_cache.dart';
import '../foundation/avatar_retry.dart';
import '../foundation/wechat_tokens.dart';

final class UserAvatar extends StatefulWidget {
  const UserAvatar(
      {super.key,
      required this.nickname,
      required this.fallbackSeed,
      this.avatarUrl,
      this.avatarHeaders,
      this.diagnosticSource = 'unspecified',
      this.size = 48});
  final String nickname;
  final String fallbackSeed;
  final String? avatarUrl;
  final Map<String, String>? avatarHeaders;
  final String diagnosticSource;
  final double size;

  @override
  State<UserAvatar> createState() => _UserAvatarState();
}

final class _UserAvatarState extends State<UserAvatar> {
  final _retry = AvatarRetry();
  int _generation = 0;
  int _imageEpoch = 0;
  bool _retrying = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _retry.setActive(TickerMode.valuesOf(context).enabled);
  }

  @override
  void didUpdateWidget(covariant UserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fallbackSeed != widget.fallbackSeed ||
        oldWidget.avatarUrl != widget.avatarUrl ||
        !mapEquals(oldWidget.avatarHeaders, widget.avatarHeaders)) {
      _generation++;
      _retry.reset();
      _retrying = false;
      _imageEpoch++;
    }
  }

  @override
  void dispose() {
    _generation++;
    _retry.reset();
    super.dispose();
  }

  Future<void> _retryImage(
      AvatarCacheImageProvider provider, int generation) async {
    if (!mounted || generation != _generation || _retrying) return;
    _retrying = true;
    PerformanceMetrics.instance.increment(PerformanceCounter.avatarRetry);
    try {
      await _retry.runAfter(AvatarCache.evictFailedImage(provider), () {
        if (!mounted || generation != _generation) return;
        // The retry owner defers reconstruction if cleanup outlives the
        // foreground/visible interval, preserving the same stable disk key.
        setState(() {
          _imageEpoch++;
          _retrying = false;
        });
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      _retrying = false;
      _retry.schedule(() => unawaited(_retryImage(provider, generation)));
    }
  }

  void _logLoadError(Object error, StackTrace? stackTrace) {
    debugPrint(
      '[AvatarLoadError] source=${widget.diagnosticSource} '
      'errorType=${error.runtimeType}',
    );
    debugPrintStack(
      label: '[AvatarLoadErrorStack] source=${widget.diagnosticSource}',
      stackTrace: stackTrace,
    );
  }

  Color get fallbackColor {
    final value = widget.fallbackSeed.codeUnits.fold<int>(0, (a, b) => a + b);
    return [
      WeChatColors.avatarFallbackBlue,
      WeChatColors.avatarFallbackGreen,
      WeChatColors.avatarFallbackOrange,
      WeChatColors.avatarFallbackPurple
    ][value % 4];
  }

  Widget _fallback() {
    assert(() {
      debugPrint(
        '[AvatarFirstPaint] source=${widget.diagnosticSource} '
        'fallback-rendered=true metadata=false',
      );
      return true;
    }());
    return ColoredBox(
      color: fallbackColor,
      child: Center(
        child: Text(
          widget.nickname.trim().isEmpty
              ? '?'
              : widget.nickname.trim().characters.first,
          style: TextStyle(
            fontSize: widget.size * WeChatTypography.avatarInitialScale,
            color: WeChatColors.lightTextPrimary,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final generation = _generation;
    final url = widget.avatarUrl;
    final provider = url == null
        ? null
        : AvatarCache.imageProvider(
            userId: widget.fallbackSeed,
            avatarUrl: url,
            size: widget.size,
            headers: widget.avatarHeaders,
          );
    final retained = AvatarCache.lastSuccessful(widget.fallbackSeed);
    return ClipRRect(
      borderRadius: BorderRadius.circular(WeChatRadius.avatar),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: provider == null
            ? _fallback()
            : Image(
                key: ValueKey((widget.fallbackSeed, _imageEpoch)),
                image: provider,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (generation != _generation) return const SizedBox.expand();
                  if (wasSynchronouslyLoaded || frame != null) {
                    if (generation == _generation) _retry.reset();
                    AvatarCache.rememberSuccessful(
                        widget.fallbackSeed, provider);
                    if (wasSynchronouslyLoaded || retained != null) {
                      return child;
                    }
                    // 首次展示从透明平滑淡入，避免默认占位与真实头像之间的
                    // 明显跳变；已有 retained 头像时保持无感替换。
                    return TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOut,
                      builder: (_, value, grandChild) =>
                          Opacity(opacity: value, child: grandChild),
                      child: child,
                    );
                  }
                  if (retained != null) {
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Image(image: retained, fit: BoxFit.cover),
                        Opacity(opacity: 0, child: child),
                      ],
                    );
                  }
                  // Nothing cached yet: transparent placeholder until the
                  // custom avatar decodes (fallback only appears on error),
                  // so users never see a default-avatar flash.
                  return const SizedBox.expand();
                },
                errorBuilder: (_, error, stackTrace) {
                  _logLoadError(error, stackTrace);
                  if (generation == _generation && !_retrying) {
                    _retry.schedule(
                        () => unawaited(_retryImage(provider, generation)));
                  }
                  return retained == null
                      ? _fallback()
                      : Image(image: retained, fit: BoxFit.cover);
                },
              ),
      ),
    );
  }
}
