import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/wechat_gradient_divider.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'moment_visibility_people_page.dart';
import 'moment_visibility_selection.dart';
import '../../ui/motion/motion_page_route.dart';

export 'moment_visibility_selection.dart';

final class MomentVisibilityPage extends StatefulWidget {
  const MomentVisibilityPage({
    super.key,
    required this.api,
    required this.initialSelection,
  });

  final BusinessApiClient api;
  final MomentVisibilitySelection initialSelection;

  @override
  State<MomentVisibilityPage> createState() => _MomentVisibilityPageState();
}

final class _MomentVisibilityPageState extends State<MomentVisibilityPage> {
  late MomentVisibilitySelection selection = widget.initialSelection;

  Future<void> _openPeople(String mode) async {
    final current = selection.visibility == mode
        ? selection
        : MomentVisibilitySelection(visibility: mode);
    final result = await Navigator.push<MomentVisibilitySelection>(
      context,
      MotionPageRoute(
        builder: (_) => MomentVisibilityPeoplePage(
          api: widget.api,
          mode: mode,
          initialSelection: current,
        ),
      ),
    );
    if (result != null && mounted) setState(() => selection = result);
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        backgroundColor: WeChatColors.pageBackground(context),
        navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.navigationBackground(context),
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: const Text('谁可以看'),
          trailing: CupertinoButton(
            key: const Key('visibility-complete'),
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.pop(context, selection),
            child: const Text('完成'),
          ),
        ),
        child: SafeArea(
          child: ListView(
            children: [
              Container(
                color: WeChatColors.elevatedSurface(context),
                child: RadioGroup<String>(
                  groupValue: selection.visibility,
                  onChanged: (next) => _selectPrimary(next),
                  child: Column(
                    children: [
                      _primaryRow('公开', 'PUBLIC', '所有朋友可看'),
                      // 需求 1（2026-09-19）：组内行分隔线统一使用共享渐隐
                      // 分割线（同一组件/同一套 token），保留既有 16dp 左缩进；
                      // 缩进由组件参数承担，不再自拼 0.5px 实心 ColoredBox。
                      const WeChatGradientDivider(
                        key: Key('visibility-divider-primary'),
                        indent: WeChatSpacing.lg,
                      ),
                      _primaryRow('私密', 'SELF', '所有朋友不可看'),
                    ],
                  ),
                ),
              ),
              const SizedBox(key: Key('visibility-group-gap'), height: 12),
              Container(
                color: WeChatColors.elevatedSurface(context),
                child: Column(
                  children: [
                    _submenuRow('只给谁看', 'INCLUDE'),
                    // 同上：组内行分隔线复用共享渐隐分割线，缩进 16dp。
                    const WeChatGradientDivider(
                      key: Key('visibility-divider-submenu'),
                      indent: WeChatSpacing.lg,
                    ),
                    _submenuRow('不给谁看', 'EXCLUDE'),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _primaryRow(String label, String value, String hint) =>
      WeChatListTile(
        title: Text(label),
        subtitle: Text(hint, key: Key('visibility-hint-${value.toLowerCase()}')),
        trailing: CupertinoRadio<String>(
          value: value,
          activeColor: WeChatColors.brandPrimary,
        ),
        onTap: () => _selectPrimary(value),
      );

  void _selectPrimary(String? value) {
    if (value == null) return;
    setState(() {
      selection = value == 'SELF'
          ? const MomentVisibilitySelection.private()
          : const MomentVisibilitySelection.public();
    });
  }

  Widget _submenuRow(String label, String mode) => WeChatListTile(
        title: Text(label),
        subtitle: Text(
          selection.visibility == mode && selection.selectedCount > 0
              ? '已选择 ${selection.selectedCount} 项'
              : '选择标签或朋友',
        ),
        trailing: Icon(
          CupertinoIcons.chevron_right,
          key: Key('visibility-${mode.toLowerCase()}-chevron'),
          size: 16,
          color: WeChatColors.textTertiary,
        ),
        onTap: () => _openPeople(mode),
      );
}
