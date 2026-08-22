import 'package:flutter/cupertino.dart';
import 'package:flutter_svg/flutter_svg.dart';

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
        label: '畅聊 Logo',
        image: true,
        child: SizedBox(
          key: const Key('auth-brand-mark'),
          width: WeChatDimensions.authBrandMark,
          height: WeChatDimensions.authBrandMark,
          child: SvgPicture.asset(
            'assets/branding/liuhetong_logo.svg',
            key: const Key('auth-brand-logo'),
            fit: BoxFit.contain,
            excludeFromSemantics: true,
          ),
        ),
      );
}

final class AuthAgreementRow extends StatelessWidget {
  const AuthAgreementRow({
    super.key,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.onUserAgreement,
    this.onPrivacyPolicy,
  });

  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final VoidCallback? onUserAgreement;
  final VoidCallback? onPrivacyPolicy;

  @override
  Widget build(BuildContext context) {
    final activeColor =
        enabled ? WeChatColors.brandPrimary : WeChatColors.textTertiary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          checked: value,
          enabled: enabled,
          label: '同意用户协议和隐私政策',
          child: CupertinoButton(
            key: const Key('auth-agreement-checkbox'),
            padding: EdgeInsets.zero,
            minimumSize: const Size(
              WeChatDimensions.minimumTouchTarget,
              WeChatDimensions.minimumTouchTarget,
            ),
            onPressed: enabled ? () => onChanged(!value) : null,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: value ? activeColor : CupertinoColors.transparent,
                border: Border.all(color: activeColor, width: 1.5),
                borderRadius: BorderRadius.circular(5),
              ),
              child: value
                  ? const Icon(
                      CupertinoIcons.check_mark,
                      color: CupertinoColors.white,
                      size: 14,
                    )
                  : null,
            ),
          ),
        ),
        const SizedBox(width: WeChatSpacing.xs),
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const _AuthInlineText('我已同意'),
              _AuthInlineAction(
                key: const Key('auth-user-agreement-link'),
                label: '《用户协议》',
                enabled: enabled,
                onPressed: onUserAgreement,
              ),
              const _AuthInlineText('和'),
              _AuthInlineAction(
                key: const Key('auth-privacy-policy-link'),
                label: '《隐私政策》',
                enabled: enabled,
                onPressed: onPrivacyPolicy,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

final class AuthInlineRegisterLink extends StatelessWidget {
  const AuthInlineRegisterLink({
    super.key,
    required this.enabled,
    required this.onRegister,
  });

  final bool enabled;
  final VoidCallback onRegister;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            '还没有账号？',
            style: TextStyle(
              color: WeChatColors.textSecondary,
              fontSize: WeChatTypography.subhead,
            ),
          ),
          _AuthInlineAction(
            key: const Key('auth-register-link'),
            label: '立刻注册',
            enabled: enabled,
            onPressed: onRegister,
          ),
        ],
      );
}

final class _AuthInlineText extends StatelessWidget {
  const _AuthInlineText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: WeChatDimensions.minimumTouchTarget,
        child: Align(
          widthFactor: 1,
          heightFactor: 1,
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            style: const TextStyle(
              color: WeChatColors.textSecondary,
              fontSize: WeChatTypography.caption,
            ),
          ),
        ),
      );
}

final class _AuthInlineAction extends StatelessWidget {
  const _AuthInlineAction({
    super.key,
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final bool enabled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: enabled && onPressed != null,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled && onPressed != null ? onPressed : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: WeChatDimensions.minimumTouchTarget,
            ),
            child: Align(
              widthFactor: 1,
              heightFactor: 1,
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                style: TextStyle(
                  color: enabled
                      ? WeChatColors.brandPrimary
                      : WeChatColors.textTertiary,
                  fontSize: WeChatTypography.caption,
                  fontWeight: FontWeight.w500,
                ),
              ),
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
    this.trailing,
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
  final Widget? trailing;

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
              suffix: trailing,
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
