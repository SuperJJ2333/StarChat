import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

final class UserAvatar extends StatelessWidget {
  const UserAvatar(
      {super.key,
      required this.nickname,
      required this.fallbackSeed,
      this.avatarUrl,
      this.size = 48});
  final String nickname;
  final String fallbackSeed;
  final String? avatarUrl;
  final double size;
  Color get fallbackColor {
    final value = fallbackSeed.codeUnits.fold<int>(0, (a, b) => a + b);
    return [
      const Color(0xffd8e8ff),
      const Color(0xffdff2e4),
      const Color(0xffffe5d5),
      const Color(0xffeee1ff)
    ][value % 4];
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
      borderRadius: BorderRadius.circular(WeChatRadius.control),
      child: SizedBox(
          width: size,
          height: size,
          child: avatarUrl == null
              ? ColoredBox(
                  color: fallbackColor,
                  child: Center(
                      child: Text(
                          nickname.trim().isEmpty
                              ? '?'
                              : nickname.trim().characters.first,
                          style: TextStyle(
                              fontSize: size * .4,
                              color: const Color(0xff191919)))))
              : Image.network(avatarUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => ColoredBox(
                      color: fallbackColor,
                      child: Center(
                          child: Text(nickname.trim().isEmpty
                              ? '?'
                              : nickname.trim().characters.first))))));
}
