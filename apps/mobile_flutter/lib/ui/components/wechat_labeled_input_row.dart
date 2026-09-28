import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../foundation/wechat_tokens.dart';
import 'wechat_gradient_divider.dart';

/// Stable field label; limits apply without rendering a character counter.
final class WeChatLabeledInputRow extends StatelessWidget {
  const WeChatLabeledInputRow(
      {super.key,
      required this.label,
      required this.controller,
      this.placeholder,
      this.enabled = true,
      this.maxLength});
  final String label;
  final TextEditingController controller;
  final String? placeholder;
  final bool enabled;
  final int? maxLength;
  @override
  Widget build(BuildContext context) => Container(
        color: WeChatColors.elevatedSurface(context),
        child: Column(children: [
          ConstrainedBox(
              constraints: const BoxConstraints(
                  minHeight: WeChatDimensions.contactTileHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: WeChatSpacing.lg, vertical: WeChatSpacing.md),
                child: Row(children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: WeChatTypography.callout,
                          color: WeChatColors.resolveTextPrimary(context))),
                  const SizedBox(width: WeChatSpacing.lg),
                  Expanded(
                      child: Semantics(
                          label: label,
                          textField: true,
                          child: CupertinoTextField(
                            controller: controller,
                            enabled: enabled,
                            placeholder: placeholder,
                            textAlign: controller.text.isEmpty
                                ? TextAlign.left
                                : TextAlign.right,
                            padding: EdgeInsets.zero,
                            decoration: null,
                            style: TextStyle(
                                fontSize: WeChatTypography.callout,
                                color:
                                    WeChatColors.resolveTextPrimary(context)),
                            placeholderStyle: const TextStyle(
                                fontSize: WeChatTypography.callout,
                                color: WeChatColors.textSecondary),
                            inputFormatters: [
                              if (maxLength != null)
                                LengthLimitingTextInputFormatter(maxLength)
                            ],
                          ))),
                ]),
              )),
          const WeChatGradientDivider(),
        ]),
      );
}
