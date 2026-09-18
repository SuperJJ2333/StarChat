import 'package:flutter/cupertino.dart';

import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'legal_documents.dart';
import '../../ui/motion/motion_page_route.dart';

/// 打开内置的协议/政策页（登录页《用户协议》《隐私政策》入口，BUG-02）。
Future<void> openLegalDocument(
        BuildContext context, LegalDocument document) =>
    Navigator.of(context).push(MotionPageRoute<void>(
        builder: (_) => LegalDocumentPage(document: document)));

/// 用户协议 / 隐私政策正文页。
///
/// 使用原生控件渲染本地正文：不依赖外部 URL（不会 404）、不需要 WebView
/// 初始化、iOS 与 Android 表现一致，且离线可读。
final class LegalDocumentPage extends StatelessWidget {
  const LegalDocumentPage({super.key, required this.document});

  final LegalDocument document;

  @override
  Widget build(BuildContext context) => WeChatPageScaffold(
        title: document.title,
        child: SafeArea(
          child: ListView(
            key: Key('legal-document-${document.slug}'),
            padding: const EdgeInsets.fromLTRB(
                WeChatSpacing.lg, WeChatSpacing.lg, WeChatSpacing.lg, WeChatSpacing.xxl),
            children: [
              Text(
                document.title,
                style: const TextStyle(
                    fontSize: WeChatTypography.title1,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: WeChatSpacing.xs),
              Text(
                '更新日期：${document.updatedAt}',
                style: const TextStyle(
                    fontSize: WeChatTypography.caption,
                    color: WeChatColors.textTertiary),
              ),
              const SizedBox(height: WeChatSpacing.md),
              Text(
                document.introduction,
                style: const TextStyle(
                    fontSize: WeChatTypography.subhead,
                    height: 22 / 14,
                    color: WeChatColors.textSecondary),
              ),
              for (final section in document.sections) ...[
                const SizedBox(height: WeChatSpacing.lg),
                Text(
                  section.title,
                  style: const TextStyle(
                      fontSize: WeChatTypography.callout,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: WeChatSpacing.xs),
                for (final paragraph in section.paragraphs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: WeChatSpacing.sm),
                    child: Text(
                      paragraph,
                      style: const TextStyle(
                          fontSize: WeChatTypography.subhead, height: 22 / 14),
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
}
