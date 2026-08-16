import 'package:flutter/cupertino.dart';
import 'user_avatar.dart';

final class UserIdentityHeader extends StatelessWidget {
  const UserIdentityHeader({super.key, required this.username, required this.nickname, required this.signature, required this.fallbackSeed, this.avatarUrl});
  final String username, nickname, fallbackSeed;
  final String? signature, avatarUrl;
  @override Widget build(BuildContext context) => Row(children: [UserAvatar(nickname: nickname, fallbackSeed: fallbackSeed, avatarUrl: avatarUrl, size: 72), const SizedBox(width: 16), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(nickname, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)), const SizedBox(height: 4), Text('畅聊号：$username', style: const TextStyle(color: CupertinoColors.secondaryLabel)), if (signature?.isNotEmpty ?? false) Padding(padding: const EdgeInsets.only(top: 4), child: Text(signature!))]))]);
}
