import 'package:flutter/cupertino.dart';

import '../../ui/foundation/wechat_tokens.dart';

/// “选择聊天”转发候选：由宿主预组装（头像/标题已按备注优先解析）。
final class ChatForwardCandidate {
  const ChatForwardCandidate({
    required this.roomId,
    required this.title,
    required this.avatar,
    this.isGroup = false,
    this.memberCount = 0,
  });

  final String roomId;
  final String title;
  final Widget avatar;
  final bool isGroup;
  final int memberCount;
}

/// “选择聊天”转发页（微信式独立页面，严禁底部弹层）：
/// - 导航栏右上角“多选”；
/// - 第一行搜索栏（按会话名过滤）；
/// - 第二行“最近转发”（最近转发过的会话头像横排，点击即转发）；
/// - 第三行起“最近聊天”列表（按最后活动时间排序，群聊显示人数）；
/// - 多选模式下勾选多个会话，底部“发送(N)”批量转发。
final class ChatForwardPickerPage extends StatefulWidget {
  const ChatForwardPickerPage({
    super.key,
    required this.candidates,
    required this.recentRoomIds,
    required this.onForward,
  });

  final List<ChatForwardCandidate> candidates;
  final List<String> recentRoomIds;
  final Future<void> Function(List<String> roomIds) onForward;

  @override
  State<ChatForwardPickerPage> createState() => _ChatForwardPickerPageState();
}

final class _ChatForwardPickerPageState extends State<ChatForwardPickerPage> {
  String query = '';
  bool multiSelect = false;
  final Set<String> selected = <String>{};
  bool sending = false;

  late final recentCandidates = [
    for (final id in widget.recentRoomIds)
      if (widget.candidates.any((c) => c.roomId == id))
        widget.candidates.firstWhere((c) => c.roomId == id),
  ];

  late final List<ChatForwardCandidate> sortedCandidates = [
    ...widget.candidates
      ..sort((a, b) => b.title.compareTo(a.title) * -1), // 保持调用方顺序
  ];

  List<ChatForwardCandidate> get visibleCandidates {
    final keyword = query.trim();
    if (keyword.isEmpty) return sortedCandidates;
    return [
      for (final c in sortedCandidates)
        if (c.title.toLowerCase().contains(keyword.toLowerCase())) c,
    ];
  }

  Future<void> _forward(List<String> roomIds) async {
    if (sending || roomIds.isEmpty) return;
    setState(() => sending = true);
    await widget.onForward(roomIds);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return CupertinoPageScaffold(
      backgroundColor:
          dark ? WeChatColors.darkPageBackground : WeChatColors.lightPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor:
            dark ? WeChatColors.darkSurface : WeChatColors.lightSurface,
        middle: const Text('选择聊天'),
        transitionBetweenRoutes: false,
        leading: CupertinoButton(
          key: const Key('forward-picker-back'),
          minimumSize: Size.zero,
          padding: const EdgeInsets.all(8),
          onPressed: () => Navigator.pop(context),
          child: const Icon(CupertinoIcons.chevron_down, size: 20),
        ),
        trailing: CupertinoButton(
          key: const Key('forward-picker-multi'),
          minimumSize: Size.zero,
          padding: const EdgeInsets.all(8),
          onPressed: () => setState(() {
            multiSelect = !multiSelect;
            selected.clear();
          }),
          child: Text(multiSelect ? '取消' : '多选',
              style: const TextStyle(fontSize: 16)),
        ),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: CupertinoSearchTextField(
            key: const Key('forward-picker-search'),
            placeholder: '搜索',
            onChanged: (value) => setState(() => query = value),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (recentCandidates.isNotEmpty) ...[
                  const Padding(
                    key: Key('forward-picker-recent-section'),
                    padding: EdgeInsets.fromLTRB(16, 6, 16, 8),
                    child: Text('最近转发',
                        style: TextStyle(
                            fontSize: 13, color: WeChatColors.textSecondary)),
                  ),
                  SizedBox(
                    height: 108,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        for (final candidate in recentCandidates)
                          _RecentAvatar(
                            key: Key(
                                'forward-recent-${candidate.roomId}'),
                            candidate: candidate,
                            enabled: !sending,
                            onTap: () => _forward([candidate.roomId]),
                          ),
                      ],
                    ),
                  ),
                ],
                Container(
                  height: .5,
                  color: WeChatColors.divider,
                  margin: const EdgeInsets.only(top: 8),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
                  child: Text('最近聊天',
                      style: TextStyle(
                          fontSize: 13, color: WeChatColors.textSecondary)),
                ),
                for (final candidate in visibleCandidates)
                  _ChatRow(
                    key: Key('forward-chat-${candidate.roomId}'),
                    candidate: candidate,
                    multiSelect: multiSelect,
                    selected: selected.contains(candidate.roomId),
                    enabled: !sending,
                    onTap: () {
                      if (multiSelect) {
                        setState(() {
                          if (!selected.add(candidate.roomId)) {
                            selected.remove(candidate.roomId);
                          }
                        });
                      } else {
                        _forward([candidate.roomId]);
                      }
                    },
                  ),
              ],
            ),
          ),
        ),
        if (multiSelect)
          SafeArea(
            top: false,
            child: Container(
              key: const Key('forward-picker-sendbar'),
              height: 54,
              color: dark
                  ? WeChatColors.darkSurface
                  : WeChatColors.lightSurface,
              child: Row(children: [
                const Spacer(),
                CupertinoButton(
                  key: const Key('forward-picker-send'),
                  color: selected.isEmpty
                      ? WeChatColors.divider
                      : WeChatColors.brandPrimary,
                  borderRadius: BorderRadius.circular(6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
                  onPressed:
                      selected.isEmpty || sending ? null : () => _forward([
                            for (final id in selected) id,
                          ]),
                  child: Text('发送(${selected.length})',
                      style: TextStyle(
                          fontSize: 15,
                          color: selected.isEmpty
                              ? WeChatColors.textTertiary
                              : CupertinoColors.white)),
                ),
                const SizedBox(width: 16),
              ]),
            ),
          ),
      ]),
    );
  }
}

final class _RecentAvatar extends StatelessWidget {
  const _RecentAvatar({
    super.key,
    required this.candidate,
    required this.onTap,
    required this.enabled,
  });

  final ChatForwardCandidate candidate;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 16),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 60,
            child: Column(children: [
              SizedBox(width: 52, height: 52, child: candidate.avatar),
              const SizedBox(height: 5),
              Text(
                candidate.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11),
              ),
            ]),
          ),
        ),
      );
}

final class _ChatRow extends StatelessWidget {
  const _ChatRow({
    super.key,
    required this.candidate,
    required this.multiSelect,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final ChatForwardCandidate candidate;
  final bool multiSelect;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: ColoredBox(
          color: selected && multiSelect
              ? WeChatColors.divider.withValues(alpha: .4)
              : CupertinoColors.transparent,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(children: [
              SizedBox(width: 42, height: 42, child: candidate.avatar),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  candidate.isGroup && candidate.memberCount > 0
                      ? '${candidate.title} (${candidate.memberCount}人)'
                      : candidate.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
              if (multiSelect)
                Icon(
                  selected
                      ? CupertinoIcons.check_mark_circled_solid
                      : CupertinoIcons.circle,
                  size: 22,
                  color: selected
                      ? WeChatColors.brandPrimary
                      : WeChatColors.textTertiary,
                ),
            ]),
          ),
        ),
      );
}
