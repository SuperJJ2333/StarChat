import 'package:flutter/cupertino.dart';
import 'package:matrix/matrix.dart';

import '../../ui/components/user_avatar.dart';
import 'avatar_url_resolver.dart';
import 'matrix_e2ee_client.dart';

typedef MatrixAvatarResolver = Future<ResolvedAvatarUrl?> Function(
  Client client,
  Uri? avatarUri,
  double size,
);

/// Converts Matrix mxc avatars into cacheable thumbnail requests without ever
/// placing the Matrix access token in a cache key or URL.
final class MatrixUserAvatar extends StatefulWidget {
  const MatrixUserAvatar({
    super.key,
    this.client,
    this.matrix,
    required this.nickname,
    required this.fallbackSeed,
    this.matrixAvatarUri,
    this.fallbackAvatarUrl,
    this.diagnosticSource = 'unspecified',
    this.size = 48,
    this.resolver,
  }) : assert(client != null || matrix != null);

  final Client? client;
  final MatrixSdkE2eeClient? matrix;
  final String nickname;
  final String fallbackSeed;
  final Uri? matrixAvatarUri;
  final String? fallbackAvatarUrl;
  final String diagnosticSource;
  final double size;
  final MatrixAvatarResolver? resolver;

  @override
  State<MatrixUserAvatar> createState() => _MatrixUserAvatarState();
}

final class _MatrixUserAvatarState extends State<MatrixUserAvatar> {
  ResolvedAvatarUrl? resolved;
  int _resolutionGeneration = 0;

  @override
  void initState() {
    super.initState();
    final client = widget.client;
    if (client != null) {
      resolved = MatrixAvatarUrlResolver.resolveImmediately(
        avatarUri: widget.matrixAvatarUri,
        homeserver: client.homeserver,
        accessToken: client.accessToken,
        size: widget.size,
      );
    }
    _diagnose('initial');
    _resolve();
  }

  @override
  void didUpdateWidget(covariant MatrixUserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.matrixAvatarUri != widget.matrixAvatarUri ||
        oldWidget.size != widget.size ||
        oldWidget.client != widget.client ||
        oldWidget.matrix != widget.matrix) {
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final generation = ++_resolutionGeneration;
    final avatarUri = widget.matrixAvatarUri;
    final size = widget.size;
    final resolver = widget.resolver ??
        (Client client, Uri? uri, double requestedSize) =>
            MatrixAvatarUrlResolver.resolveForClient(
              avatarUri: uri,
              client: client,
              size: requestedSize,
            );
    try {
      final directClient = widget.client;
      final value = directClient == null
          ? await widget.matrix!.resolveAvatar(
              avatarUri: avatarUri,
              size: size,
            )
          : await resolver(directClient, avatarUri, size);
      if (!mounted || generation != _resolutionGeneration) return;
      setState(() => resolved = value);
      _diagnose('resolved');
    } catch (_) {
      if (!mounted || generation != _resolutionGeneration) return;
      _diagnose('resolution-failed');
      // Retain the HTTP profile fallback or local text avatar while Matrix
      // media capability discovery is temporarily unavailable.
    }
  }

  @override
  void dispose() {
    _resolutionGeneration++;
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
