import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

abstract final class GroupAvatarLayout {
  static List<int> rowsForCount(int count) => switch (count.clamp(1, 9)) {
        1 => const [1],
        2 => const [2],
        3 => const [1, 2],
        4 => const [2, 2],
        5 => const [2, 3],
        6 => const [3, 3],
        7 => const [2, 2, 3],
        8 => const [3, 3, 2],
        _ => const [3, 3, 3],
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
    final rows = GroupAvatarLayout.rowsForCount(visible.length);
    const gapRatio = 0.045;
    final gap = size * gapRatio;
    final cell = (size - gap * 4) / 3;
    var index = 0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(WeChatRadius.control),
      child: ColoredBox(
        color: const Color(0xFFD9DDE1),
        child: Padding(
          padding: EdgeInsets.all(gap),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) ...[
                if (rowIndex > 0) SizedBox(height: gap),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var column = 0; column < rows[rowIndex]; column++) ...[
                      if (column > 0) SizedBox(width: gap),
                      Builder(builder: (context) {
                        final memberIndex = index++;
                        return ClipRRect(
                          key: Key('group-avatar-member-$memberIndex'),
                          borderRadius: BorderRadius.circular(cell * 0.12),
                          child: SizedBox.square(
                            dimension: cell,
                            child: FittedBox(
                              fit: BoxFit.cover,
                              clipBehavior: Clip.hardEdge,
                              child: SizedBox.square(
                                dimension: cell,
                                child: visible[memberIndex],
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
