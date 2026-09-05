import 'package:flutter/cupertino.dart';
import 'package:matrix/matrix.dart';

import '../../ui/components/user_avatar.dart';
import 'avatar_url_resolver.dart';

/// Converts Matrix mxc avatars into cacheable thumbnail requests without ever
/// placing the Matrix access token in a cache key or URL.
final class MatrixUserAvatar extends StatefulWidget {
  const MatrixUserAvatar({
    super.key,
    required this.client,
    required this.nickname,
    required this.fallbackSeed,
    this.matrixAvatarUri,
    this.fallbackAvatarUrl,
    this.diagnosticSource = 'unspecified',
    this.size = 48,
  });

  final Client client;
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

  @override
  void initState() {
    super.initState();
    resolved = MatrixAvatarUrlResolver.resolveImmediately(
      avatarUri: widget.matrixAvatarUri,
      homeserver: widget.client.homeserver,
      accessToken: widget.client.accessToken,
      size: widget.size,
    );
    _diagnose('initial');
    _resolve();
  }

  @override
  void didUpdateWidget(covariant MatrixUserAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.matrixAvatarUri != widget.matrixAvatarUri ||
        oldWidget.size != widget.size ||
        oldWidget.client != widget.client) {
      _resolve();
    }
  }

  Future<void> _resolve() async {
    try {
      final value = await MatrixAvatarUrlResolver.resolveForClient(
        avatarUri: widget.matrixAvatarUri,
        client: widget.client,
        size: widget.size,
      );
      if (mounted) setState(() => resolved = value);
      _diagnose('resolved');
    } catch (_) {
      _diagnose('resolution-failed');
      // Retain the HTTP profile fallback or local text avatar while Matrix
      // media capability discovery is temporarily unavailable.
    }
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
