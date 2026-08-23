import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

/// Shared WeChat-style wheel date picker used by history and scheduling flows.
final class WeChatDatePicker extends StatefulWidget {
  const WeChatDatePicker({super.key, required this.initialDate, this.onCancel});
  final DateTime initialDate;
  final VoidCallback? onCancel;

  static Future<DateTime?> show(BuildContext context, {DateTime? initialDate}) =>
      showCupertinoModalPopup<DateTime>(
        context: context,
        builder: (_) => WeChatDatePicker(
          initialDate: initialDate ?? DateTime.now(),
        ),
      );

  @override
  State<WeChatDatePicker> createState() => _WeChatDatePickerState();
}

final class _WeChatDatePickerState extends State<WeChatDatePicker> {
  late DateTime selected = DateTime(
    widget.initialDate.year,
    widget.initialDate.month,
    widget.initialDate.day,
  );

  @override
  Widget build(BuildContext context) => Container(
        height: 320,
        color: WeChatColors.elevatedSurface(context),
        child: Column(
          children: [
            SizedBox(
              height: 52,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CupertinoButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  CupertinoButton(
                    onPressed: () => Navigator.pop(context, selected),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: selected,
                maximumDate: DateTime.now(),
                use24hFormat: true,
                onDateTimeChanged: (value) => selected = value,
              ),
            ),
          ],
        ),
      );
}
