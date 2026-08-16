import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

final class AuthSurfaceCard extends StatelessWidget {
  const AuthSurfaceCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    return Container(
      key: const Key('auth-surface-card'),
      width: double.infinity,
      constraints: const BoxConstraints(
        maxWidth: WeChatDimensions.authCardMaxWidth,
      ),
      padding: const EdgeInsets.all(WeChatSpacing.xl),
      decoration: BoxDecoration(
        color: dark ? WeChatColors.darkElevated : WeChatColors.lightElevated,
        borderRadius: BorderRadius.circular(WeChatRadius.authCard),
        boxShadow: WeChatEffects.authCardShadow,
      ),
      child: child,
    );
  }
}

final class AuthBrandMark extends StatelessWidget {
  const AuthBrandMark({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
        label: '畅聊',
        image: true,
        child: Container(
          key: const Key('auth-brand-mark'),
          width: WeChatDimensions.authBrandMark,
          height: WeChatDimensions.authBrandMark,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: WeChatColors.brandPrimary,
            borderRadius: BorderRadius.circular(WeChatRadius.dialog),
          ),
          child: const Text(
            '畅',
            style: TextStyle(
              color: CupertinoColors.white,
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
}

final class AuthTextField extends StatelessWidget {
  const AuthTextField({
    super.key,
    required this.label,
    required this.placeholder,
    required this.controller,
    this.enabled = true,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.onChanged,
  });

  final String label;
  final String placeholder;
  final TextEditingController controller;
  final bool enabled;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.of(context).brightness == Brightness.dark;
    final secondary = WeChatColors.textSecondary;
    final border = dark ? WeChatColors.darkDivider : WeChatColors.divider;
    final background =
        dark ? WeChatColors.darkSurface : WeChatColors.lightSurface;
    return Semantics(
      textField: true,
      label: label,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: WeChatColors.textSecondary,
              fontSize: WeChatTypography.caption,
              height: 17 / 12,
            ),
          ),
          const SizedBox(height: WeChatSpacing.xs),
          SizedBox(
            height: WeChatDimensions.controlHeight,
            child: CupertinoTextField(
              controller: controller,
              enabled: enabled,
              obscureText: obscureText,
              keyboardType: keyboardType,
              textInputAction: textInputAction,
              autofillHints: autofillHints,
              onChanged: onChanged,
              placeholder: placeholder,
              placeholderStyle: TextStyle(color: secondary, fontSize: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: background,
                border: Border.all(color: border),
                borderRadius: BorderRadius.circular(WeChatRadius.authControl),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
