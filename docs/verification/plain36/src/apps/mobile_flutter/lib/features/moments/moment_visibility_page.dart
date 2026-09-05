import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'moment_visibility_people_page.dart';
import 'moment_visibility_selection.dart';

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
      CupertinoPageRoute(
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
        backgroundColor: WeChatColors.tabRootPageBackground,
        navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
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
                color: CupertinoColors.white,
                child: RadioGroup<String>(
                  groupValue: selection.visibility,
                  onChanged: (next) => _selectPrimary(next),
                  child: Column(
                    children: [
                      _primaryRow('公开', 'PUBLIC'),
                      const Padding(
                        padding: EdgeInsets.only(left: 16),
                        child: SizedBox(
                          height: .5,
                          child: ColoredBox(color: WeChatColors.divider),
                        ),
                      ),
                      _primaryRow('私密', 'SELF'),
                    ],
                  ),
                ),
              ),
              const SizedBox(key: Key('visibility-group-gap'), height: 12),
              Container(
                color: CupertinoColors.white,
                child: Column(
                  children: [
                    _submenuRow('只给谁看', 'INCLUDE'),
                    const Padding(
                      padding: EdgeInsets.only(left: 16),
                      child: SizedBox(
                        height: .5,
                        child: ColoredBox(color: WeChatColors.divider),
                      ),
                    ),
                    _submenuRow('不给谁看', 'EXCLUDE'),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _primaryRow(String label, String value) => WeChatListTile(
        title: Text(label),
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
