import 'package:flutter/cupertino.dart';
import 'dart:io';

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

/// Optional local-only lookup so a cold disk cache never waits on discovery.
abstract interface class ImmediateAvatarMediaCapability {
  ResolvedAvatarUrl? resolveAvatarImmediately({
    required Uri? avatarUri,
    required double size,
  });
}

abstract interface class CachedAvatarMediaCapability {
  bool get usesLocalAvatarCacheOnly;
  String? avatarCacheIdentity(String displayIdentity);
  Future<File?> readCachedAvatar(
      {required Uri? avatarUri, required String displayIdentity});
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
  File? _localFile;
  bool _localOnly = false;
  AvatarMediaCapability? _fileOwner;
  String? _fileIdentity;
  Uri? _fileUri;
  bool _localPainted = false;

  bool get _fileIsCurrent =>
      _localFile != null &&
      identical(_fileOwner, widget.avatarMedia) &&
      _fileIdentity != null &&
      _fileIdentity == _cacheMedia?.avatarCacheIdentity(widget.fallbackSeed) &&
      _fileUri == _effectiveUri &&
      _fileUri != null &&
      _fileUri.toString().isNotEmpty;

  void _clearLocalFile() {
    _localFile = null;
    _fileOwner = null;
    _fileIdentity = null;
    _fileUri = null;
    _localPainted = false;
  }

  CachedAvatarMediaCapability? get _cacheMedia =>
      widget.avatarMedia is CachedAvatarMediaCapability
          ? widget.avatarMedia as CachedAvatarMediaCapability
          : null;
  Uri? get _effectiveUri =>
      widget.matrixAvatarUri ?? Uri.tryParse(widget.fallbackAvatarUrl ?? '');
  int _resolutionGeneration = 0;
  final _retry = AvatarRetry();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _retry.setActive(TickerMode.valuesOf(context).enabled);
    if (resolved == null) _primeImmediate();
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
        oldWidget.fallbackAvatarUrl != widget.fallbackAvatarUrl ||
        _localOnly != (_cacheMedia?.usesLocalAvatarCacheOnly ?? false) ||
        oldWidget.fallbackSeed != widget.fallbackSeed ||
        oldWidget.size != widget.size ||
        oldWidget.avatarMedia != widget.avatarMedia) {
      if (oldWidget.fallbackSeed != widget.fallbackSeed ||
          widget.matrixAvatarUri == null ||
          oldWidget.avatarMedia != widget.avatarMedia) {
        resolved = null;
      }
      _retry.reset();
      if (!_fileIsCurrent) _clearLocalFile();
      _primeImmediate();
      _resolve();
    }
  }

  void _primeImmediate() {
    if (_cacheMedia?.usesLocalAvatarCacheOnly == true) return;
    final media = widget.avatarMedia;
    if (!_retry.isActive || media is! ImmediateAvatarMediaCapability) return;
    try {
      resolved =
          (media as ImmediateAvatarMediaCapability).resolveAvatarImmediately(
        avatarUri: widget.matrixAvatarUri,
        size: widget.size,
      );
    } catch (_) {
      // A suspended/revoked owner must not publish its former credentials.
      resolved = null;
    }
  }

  Future<void> _resolve() async {
    final metrics = PerformanceMetrics.instance;
    final watch = metrics.enabled ? (Stopwatch()..start()) : null;
    final generation = ++_resolutionGeneration;
    final cache = _cacheMedia;
    _localOnly = cache?.usesLocalAvatarCacheOnly ?? false;
    if (_localOnly) {
      resolved = null;
      try {
        final owner = widget.avatarMedia;
        final identity = cache!.avatarCacheIdentity(widget.fallbackSeed);
        final uri = _effectiveUri;
        final file = await cache.readCachedAvatar(
            avatarUri: _effectiveUri, displayIdentity: widget.fallbackSeed);
        if (!mounted ||
            generation != _resolutionGeneration ||
            !cache.usesLocalAvatarCacheOnly ||
            !identical(owner, widget.avatarMedia) ||
            identity == null ||
            identity != cache.avatarCacheIdentity(widget.fallbackSeed) ||
            uri != _effectiveUri) {
          return;
        }
        setState(() {
          _localFile = file;
          _fileOwner = owner;
          _fileIdentity = identity;
          _fileUri = uri;
          _localPainted = false;
        });
      } catch (_) {
        if (mounted && generation == _resolutionGeneration) {
          setState(_clearLocalFile);
        }
      }
      return;
    }
    final avatarUri = widget.matrixAvatarUri;
    final size = widget.size;
    try {
      ResolvedAvatarUrl? value;
      await _retry.runAfter(
        widget.avatarMedia
            .resolveAvatar(avatarUri: avatarUri, size: size)
            .then((fresh) {
          value = fresh;
        }),
        () {
          if (!mounted || generation != _resolutionGeneration) return;
          _retry.reset();
          setState(() => resolved = value);
          _diagnose('resolved');
        },
      );
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
  Widget build(BuildContext context) {
    final cache = _cacheMedia;
    final identity = cache?.avatarCacheIdentity(widget.fallbackSeed);
    final admitted = cache == null || identity != null;
    if (!_fileIsCurrent) _clearLocalFile();
    final file = _localFile;
    return UserAvatar(
      nickname: widget.nickname,
      fallbackSeed: widget.fallbackSeed,
      avatarCacheKey: identity,
      localOnly: _localOnly || !admitted,
      localImageProvider:
          !admitted || file == null || (!_localOnly && !_localPainted)
              ? null
              : FileImage(file),
      onLocalImagePainted: () {
        if (mounted && identical(file, _localFile) && _fileIsCurrent) {
          _localPainted = true;
        }
      },
      avatarUrl: _localOnly ? null : resolved?.url ?? widget.fallbackAvatarUrl,
      avatarHeaders: resolved?.headers,
      diagnosticSource: widget.diagnosticSource,
      size: widget.size,
    );
  }
}
