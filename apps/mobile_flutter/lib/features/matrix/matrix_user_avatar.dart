import 'package:flutter/cupertino.dart';

import '../../core/performance_metrics.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/foundation/avatar_retry.dart';
import 'avatar_url_resolver.dart';

/// Minimal managed capability for resolving Matrix media without exposing a
/// Matrix SDK client to presentation code.
abstract interface class AvatarMediaCapability {
  Future<ResolvedAvatarUrl?> resolveAvatar({
    required Uri? avatarUri,
    required double size,
  });
}

/// Converts Matrix mxc avatars into cacheable thumbnail requests without ever
/// placing the Matrix access token in a cache key or URL.
final class MatrixUserAvatar extends StatefulWidget {
  const MatrixUserAvatar({
    super.key,
    required this.avatarMedia,
    required this.nickname,
    required this.fallbackSeed,
    this.matrixAvatarUri,
    this.fallbackAvatarUrl,
    this.diagnosticSource = 'unspecified',
    this.size = 48,
  });

  final AvatarMediaCapability avatarMedia;
  final String nickname;
  final String fallbackSeed;
  final Uri? matrixAvatarUri;
  final String? fallbackAvatarUrl;
  final String diagnosticSource;
  final double size;

  @override
  State<MatrixUserAvatar> createState() => _MatrixUserAvatarState();
}

final class _MatrixUserAvatarState extends State<MatrixUserAvatar> {
  ResolvedAvatarUrl? resolved;
  int _resolutionGeneration = 0;
  final _retry = AvatarRetry();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _retry.setActive(TickerMode.valuesOf(context).enabled);
  }

  @override
  void initState() {
    super.initState();
    _diagnose('initial');
    _resolve();
  }

  @override
  void didUpdateWidget(covariant MatrixUserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.matrixAvatarUri != widget.matrixAvatarUri ||
        oldWidget.fallbackSeed != widget.fallbackSeed ||
        oldWidget.size != widget.size ||
        oldWidget.avatarMedia != widget.avatarMedia) {
      if (oldWidget.fallbackSeed != widget.fallbackSeed ||
          widget.matrixAvatarUri == null ||
          oldWidget.avatarMedia != widget.avatarMedia) {
        resolved = null;
      }
      _retry.reset();
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final metrics = PerformanceMetrics.instance;
    final watch = metrics.enabled ? (Stopwatch()..start()) : null;
    final generation = ++_resolutionGeneration;
    final avatarUri = widget.matrixAvatarUri;
    final size = widget.size;
    try {
      final value = await widget.avatarMedia.resolveAvatar(
        avatarUri: avatarUri,
        size: size,
      );
      if (!mounted || generation != _resolutionGeneration) return;
      _retry.reset();
      setState(() => resolved = value);
      _diagnose('resolved');
    } catch (_) {
      if (!mounted || generation != _resolutionGeneration) return;
      if (avatarUri != null) {
        _retry.schedule(() {
          PerformanceMetrics.instance.increment(PerformanceCounter.avatarRetry);
          _resolve();
        });
      }
      _diagnose('resolution-failed');
      // Retain the HTTP profile fallback or local text avatar while Matrix
      // media capability discovery is temporarily unavailable.
    } finally {
      if (watch != null) {
        metrics.record(
            PerformanceOperation.avatarResolve, watch.elapsedMicroseconds);
      }
    }
  }

  @override
  void dispose() {
    _resolutionGeneration++;
    _retry.reset();
    super.dispose();
  }

  void _diagnose(String phase) {
    assert(() {
      debugPrint(
        '[AvatarFirstPaint] source=${widget.diagnosticSource} '
        'phase=$phase metadata=${widget.matrixAvatarUri != null || widget.fallbackAvatarUrl != null} '
        'resolved=${resolved != null}',
      );
      return true;
    }());
  }

  @override
  Widget build(BuildContext context) => UserAvatar(
        nickname: widget.nickname,
        fallbackSeed: widget.fallbackSeed,
        avatarUrl: resolved?.url ?? widget.fallbackAvatarUrl,
        avatarHeaders: resolved?.headers,
        diagnosticSource: widget.diagnosticSource,
        size: widget.size,
      );
}
