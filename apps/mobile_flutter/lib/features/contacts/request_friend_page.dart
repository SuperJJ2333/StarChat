import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../ui/components/modern_action_button.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'contact_models.dart';

/// 微信风格的「申请添加朋友」页：打招呼（≤50 字）、备注（≤20 字）、
/// 标签（多选 ≤5，可新建）、朋友圈权限（默认"不让他看我的朋友圈和状态"）。
/// 备注与标签在对方通过申请后写入申请人的通讯录。
final class RequestFriendPage extends StatefulWidget {
  const RequestFriendPage({
    super.key,
    required this.api,
    required this.userId,
    required this.username,
    required this.nickname,
    this.avatarUrl,
  });

  final AddFriendGateway api;
  final String userId;
  final String username;
  final String nickname;
  final String? avatarUrl;

  @override
  State<RequestFriendPage> createState() => _RequestFriendPageState();
}

const _momentsPermissionOptions = <String, String>{
  'HIDE_MINE': '不让他看我的朋友圈和状态',
  'HIDE_THEIRS': '不看他的朋友圈和状态',
  'CHAT_ONLY': '仅聊天',
};

final class _RequestFriendPageState extends State<RequestFriendPage> {
  static const _maxGreetingLength = 50;
  static const _maxRemarkLength = 20;
  static const _maxTagCount = 5;

  final greeting = TextEditingController(text: '我是');
  final remark = TextEditingController();
  final newTag = TextEditingController();
  List<String> allTags = const [];
  final Set<String> selectedTags = <String>{};
  String momentsPermission = 'HIDE_MINE';
  bool submitting = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _loadTags();
  }

  @override
  void dispose() {
    greeting.dispose();
    remark.dispose();
    newTag.dispose();
    super.dispose();
  }

  Future<void> _loadTags() async {
    try {
      final body = await widget.api.contactTags();
      final items = (body['items'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        allTags = [
          for (final item in items)
            if (item is Map) item['name']?.toString() ?? '',
        ].where((name) => name.isNotEmpty).toList();
      });
    } catch (_) {
      // 标签为可选项；加载失败不阻塞申请流程。
    }
  }

  void _toggleTag(String name) {
    setState(() {
      if (selectedTags.contains(name)) {
        selectedTags.remove(name);
      } else if (selectedTags.length < _maxTagCount) {
        selectedTags.add(name);
      } else {
        error = '最多添加 $_maxTagCount 个标签';
      }
    });
  }

  void _createTag() {
    final name = newTag.text.trim();
    if (name.isEmpty) return;
    if (name.length > 64) {
      setState(() => error = '单个标签不能超过 64 个字符');
      return;
    }
    if (selectedTags.contains(name) || allTags.contains(name)) {
      setState(() => error = '标签已存在');
      return;
    }
    setState(() {
      error = null;
      allTags = [...allTags, name];
      newTag.clear();
    });
    _toggleTag(name);
  }

  Future<void> _submit() async {
    if (submitting) return;
    final message = greeting.text.trim();
    final remarkText = remark.text.trim();
    if (message.isEmpty) {
      setState(() => error = '打个招呼再发送吧');
      return;
    }
    if (message.characters.length > _maxGreetingLength) {
      setState(() => error = '打招呼内容最多 $_maxGreetingLength 个字');
      return;
    }
    if (remarkText.characters.length > _maxRemarkLength) {
      setState(() => error = '备注最多 $_maxRemarkLength 个字');
      return;
    }
    setState(() {
      submitting = true;
      error = null;
    });
    try {
      await widget.api.requestFriend(
        widget.userId,
        message: message,
        remark: remarkText.isEmpty ? null : remarkText,
        tags: selectedTags.toList(growable: false),
        momentsPermission: momentsPermission,
      );
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('申请已发送'),
          content: const Text('等待对方验证通过后即可开始聊天'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('好的'),
            ),
          ],
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        submitting = false;
        error = failure.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: const Text('申请添加朋友'),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
            children: [
              Center(
                child: UserAvatar(
                  nickname: widget.nickname,
                  fallbackSeed: widget.userId,
                  avatarUrl: widget.avatarUrl,
                  diagnosticSource: 'request-friend',
                  size: 72,
                ),
              ),
              const SizedBox(height: 10),
              Center(
                child: Text(
                  '${widget.nickname}（畅聊号：${widget.username}）',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    color: WeChatColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 22),
              const Text('打招呼内容'),
              const SizedBox(height: 6),
              CupertinoTextField(
                key: const Key('request-friend-greeting'),
                controller: greeting,
                maxLength: _maxGreetingLength,
                maxLines: 2,
                onChanged: (_) => setState(() {}),
                inputFormatters: [
                  LengthLimitingTextInputFormatter(_maxGreetingLength),
                ],
              ),
              const SizedBox(height: 18),
              const Text('备注（对方通过后生效）'),
              const SizedBox(height: 6),
              CupertinoTextField(
                key: const Key('request-friend-remark'),
                controller: remark,
                maxLength: _maxRemarkLength,
                placeholder: '填写备注名（最多 $_maxRemarkLength 个字）',
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('标签（最多 5 个）'),
                  Text(
                    '${selectedTags.length}/$_maxTagCount',
                    style: const TextStyle(
                      fontSize: 12,
                      color: WeChatColors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final name in allTags)
                    _tagChip(
                      name,
                      selected: selectedTags.contains(name),
                      key: Key('request-friend-tag-$name'),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: CupertinoTextField(
                    key: const Key('request-friend-new-tag'),
                    controller: newTag,
                    placeholder: '新建标签',
                  ),
                ),
                const SizedBox(width: 8),
                CupertinoButton(
                  key: const Key('request-friend-add-tag'),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  color: WeChatColors.brandPrimary,
                  minimumSize: const Size(0, 36),
                  onPressed: _createTag,
                  child: const Text(
                    '添加',
                    style: TextStyle(color: CupertinoColors.white, fontSize: 14),
                  ),
                ),
              ]),
              const SizedBox(height: 18),
              const Text('朋友圈权限'),
              const SizedBox(height: 8),
              for (final entry in _momentsPermissionOptions.entries)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      setState(() => momentsPermission = entry.key),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      Icon(
                        momentsPermission == entry.key
                            ? CupertinoIcons.check_mark_circled_solid
                            : CupertinoIcons.circle,
                        size: 20,
                        color: momentsPermission == entry.key
                            ? WeChatColors.brandPrimary
                            : WeChatColors.textTertiary,
                      ),
                      const SizedBox(width: 8),
                      Text(entry.value),
                    ]),
                  ),
                ),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(
                  error!,
                  key: const Key('request-friend-error'),
                  style: const TextStyle(color: WeChatColors.danger, fontSize: 13),
                ),
              ],
              const SizedBox(height: 24),
              ModernActionButton(
                key: const Key('request-friend-submit'),
                icon: CupertinoIcons.paperplane_fill,
                label: '发送申请',
                loading: submitting,
                onPressed: submitting ? null : _submit,
              ),
            ],
          ),
        ),
      );

  Widget _tagChip(String name, {required bool selected, required Key key}) {
    return GestureDetector(
      key: key,
      onTap: () => _toggleTag(name),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? WeChatColors.brandPrimary.withValues(alpha: .12)
              : CupertinoColors.tertiarySystemFill.resolveFrom(context),
          border: Border.all(
            color: selected ? WeChatColors.brandPrimary : WeChatColors.divider,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name,
              style: TextStyle(
                fontSize: 13,
                color: selected
                    ? WeChatColors.brandPrimary
                    : WeChatColors.lightTextPrimary,
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 4),
              const Icon(
                CupertinoIcons.check_mark,
                size: 12,
                color: WeChatColors.brandPrimary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
