import 'package:flutter/cupertino.dart';

import '../../ui/components/modern_action_button.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'complaint_models.dart';

const complaintCategories = <String>[
  '发布不实信息',
  '涉嫌欺诈骗钱',
  '存在侵权行为',
  '骚扰行为',
  '其他问题',
];

/// 微信式「投诉」页：选择投诉类型 → 填写描述 → 提交。
final class ComplaintPage extends StatefulWidget {
  const ComplaintPage({super.key, required this.api});

  final ComplaintGateway api;

  @override
  State<ComplaintPage> createState() => _ComplaintPageState();
}

final class _ComplaintPageState extends State<ComplaintPage> {
  String? category;
  final description = TextEditingController();
  bool submitting = false;
  String? error;
  bool submitted = false;

  @override
  void dispose() {
    description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final chosen = category;
    if (chosen == null) {
      setState(() => error = '请先选择投诉类型');
      return;
    }
    final text = description.text.trim();
    if (text.isEmpty) {
      setState(() => error = '请填写投诉描述');
      return;
    }
    setState(() {
      submitting = true;
      error = null;
    });
    try {
      await widget.api.submitComplaint(
        category: chosen,
        description: text,
      );
      if (!mounted) return;
      setState(() {
        submitting = false;
        submitted = true;
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        submitting = false;
        error = failure.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (submitted) {
      return WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: const Text('投诉'),
        ),
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  CupertinoIcons.check_mark_circled_solid,
                  size: 64,
                  color: WeChatColors.brandPrimary,
                ),
                const SizedBox(height: 16),
                const Text('投诉已提交', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                const Text(
                  '我们会尽快核实处理，感谢你的反馈',
                  style: TextStyle(fontSize: 13, color: WeChatColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: const Text('投诉'),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            CupertinoListSection.insetGrouped(
              margin: EdgeInsets.zero,
              header: const Text('选择投诉类型'),
              children: [
                for (final name in complaintCategories)
                  CupertinoListTile(
                    key: Key('complaint-type-$name'),
                    title: Text(name),
                    trailing: category == name
                        ? const Icon(
                            CupertinoIcons.check_mark,
                            color: WeChatColors.brandPrimary,
                            size: 18,
                          )
                        : null,
                    onTap: () => setState(() => category = name),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            CupertinoTextField(
              key: const Key('complaint-description'),
              controller: description,
              placeholder: '请填写投诉描述（300 字以内）',
              maxLength: 300,
              minLines: 4,
              maxLines: 6,
              padding: const EdgeInsets.all(14),
            ),
            if (error != null) ...[
              const SizedBox(height: 10),
              Text(
                error!,
                key: const Key('complaint-error'),
                style: const TextStyle(color: WeChatColors.danger, fontSize: 13),
              ),
            ],
            const SizedBox(height: 20),
            ModernActionButton(
              key: const Key('complaint-submit'),
              icon: CupertinoIcons.paperplane_fill,
              label: submitting ? '提交中…' : '提交投诉',
              loading: submitting,
              onPressed: submitting ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}
