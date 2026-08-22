import 'package:flutter/cupertino.dart';

import '../foundation/avatar_cache.dart';
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
            fontSize: widget.size * .4,
            color: WeChatColors.lightTextPrimary,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
      borderRadius: BorderRadius.circular(WeChatRadius.control),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: provider == null
            ? (retained == null
                ? _fallback()
                : Image(image: retained, fit: BoxFit.cover))
            : Image(
                image: provider,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded || frame != null) {
                    AvatarCache.rememberSuccessful(
                        widget.fallbackSeed, provider);
                    return child;
                  }
                  return retained == null
                      ? child
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            Image(image: retained, fit: BoxFit.cover),
                            Opacity(opacity: 0, child: child),
                          ],
                        );
                },
                errorBuilder: (_, __, ___) => retained == null
                    ? _fallback()
                    : Image(image: retained, fit: BoxFit.cover),
              ),
      ),
    );
  }
}
