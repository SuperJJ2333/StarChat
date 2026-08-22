import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

abstract final class GroupAvatarLayout {
  /// WeChat-style grids use equal, square cells: 1x1 for one member, 2x2
  /// for 2--4 members and 3x3 for 5--9 members.
  static int gridDimensionForCount(int count) => switch (count.clamp(1, 9)) {
        1 => 1,
        2 || 3 || 4 => 2,
        _ => 3,
      };
}

final class GroupAvatarMosaic extends StatelessWidget {
  const GroupAvatarMosaic({
    super.key,
    required this.avatars,
    this.size = WeChatDimensions.conversationAvatar,
  });

  final List<Widget> avatars;
  final double size;

  @override
  Widget build(BuildContext context) {
    final visible = avatars.take(9).toList(growable: false);
    if (visible.isEmpty) return SizedBox.square(dimension: size);
    final gridDimension =
        GroupAvatarLayout.gridDimensionForCount(visible.length);
    const gapRatio = 0.045;
    final gap = size * gapRatio;
    var index = 0;
    return SizedBox.square(
      dimension: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(WeChatRadius.control),
        child: ColoredBox(
          color: const Color(0xFFD9DDE1),
          child: Padding(
            padding: EdgeInsets.all(gap),
            child: GridView.count(
              crossAxisCount: gridDimension,
              mainAxisSpacing: gap,
              crossAxisSpacing: gap,
              childAspectRatio: 1,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final avatar in visible)
                  Builder(builder: (context) {
                    final memberIndex = index++;
                    return ClipRRect(
                      key: Key('group-avatar-member-$memberIndex'),
                      borderRadius: BorderRadius.circular(size * .1),
                      child: FittedBox(
                        fit: BoxFit.cover,
                        clipBehavior: Clip.hardEdge,
                        child: avatar,
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
