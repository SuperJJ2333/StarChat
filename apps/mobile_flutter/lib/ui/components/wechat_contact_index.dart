import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

final class WeChatContactIndex extends StatefulWidget {
  const WeChatContactIndex(
      {super.key, required this.labels, required this.onSelected});
  final List<String> labels;
  final ValueChanged<String> onSelected;

  @override
  State<WeChatContactIndex> createState() => _WeChatContactIndexState();
}

final class _WeChatContactIndexState extends State<WeChatContactIndex> {
  String? selected;

  void _select(String label) {
    setState(() => selected = label);
    widget.onSelected(label);
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      if (mounted) setState(() => selected = null);
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final hasBoundedHeight = constraints.hasBoundedHeight;
          return Stack(
            alignment: Alignment.center,
            children: [
              ColoredBox(
                key: const Key('contact-index'),
                color: WeChatColors.elevatedSurface(context),
                child: Column(
                  mainAxisSize:
                      hasBoundedHeight ? MainAxisSize.max : MainAxisSize.min,
                  children: [
                    for (final label in widget.labels)
                      hasBoundedHeight
                          ? Expanded(child: _letter(label))
                          : SizedBox(
                              height:
                                  WeChatTypography.callout + WeChatSpacing.xs,
                              child: _letter(label),
                            ),
                  ],
                ),
              ),
              if (selected case final label?)
                DecoratedBox(
                  key: const Key('contact-index-feedback'),
                  decoration: BoxDecoration(
                    color: WeChatColors.darkSurface,
                    borderRadius: BorderRadius.circular(WeChatRadius.dialog),
                  ),
                  child: SizedBox.square(
                    dimension: WeChatDimensions.contactIndexFeedback,
                    child: Center(
                      child: Text(label,
                          style: const TextStyle(
                              color: WeChatColors.darkTextPrimary,
                              fontSize: WeChatTypography.title1)),
                    ),
                  ),
                ),
            ],
          );
        },
      );

  Widget _letter(String label) => CupertinoButton(
        minimumSize: Size.zero,
        padding: EdgeInsets.zero,
        onPressed: () => _select(label),
        child: Text(label,
            style: const TextStyle(
                color: WeChatColors.textSecondary,
                fontSize: WeChatTypography.badge)),
      );
}
