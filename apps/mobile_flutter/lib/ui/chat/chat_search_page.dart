import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../../features/contacts/member_directory_service.dart';
import '../../features/matrix/chat_media_shared_logic.dart' as logic;
import '../../features/matrix/chat_search_query_controller.dart';

import '../../ui/foundation/wechat_tokens.dart';
import 'contain_image_bubble.dart';

/// 规格 #4：聊天记录搜索页——默认空态（仅搜索框+五个筛选入口+提示，
/// 不显示任何消息行）；组合筛选（AND）+ 可移除标签；结果列表（#5）。
final class ChatSearchPage extends StatefulWidget {
  const ChatSearchPage({
    super.key,
    required this.isGroup,
    required this.search,
    required this.memberEntries,
    required this.onJumpToMessage,
    this.senderDisplayName,
  });

  /// 是否群聊（决定是否显示"群成员"筛选入口）。
  final bool isGroup;

  /// 数据源检索回调（已解密、可访问、未撤回）。
  final Future<List<ChatSearchMessage>> Function(ChatSearchFilters filters,
      {ChatSearchCursor? cursor, int limit}) search;

  /// 群成员目录（成员筛选入口的数据；私聊传空）。
  final List<MemberDirectoryEntry> memberEntries;

  /// 点击结果 → 定位原消息（统一走定位服务）。
  final void Function(String eventId) onJumpToMessage;

  /// 发送者显示名解析（结果行顶部：备注>昵称>用户名）。
  final String Function(String senderId)? senderDisplayName;

  @override
  State<ChatSearchPage> createState() => _ChatSearchPageState();
}

final class _ChatSearchPageState extends State<ChatSearchPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  ChatSearchQueryController? _controller;
  ChatSearchStateChange _state = const ChatSearchStateChange.empty();
  ChatSearchResultPage? _lastPage;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller = ChatSearchQueryController(
      search: widget.search,
      debounce: const Duration(milliseconds: 300),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() => _controller!.setKeyword(value));
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _execute);
  }

  Future<void> _execute() async {
    await _controller!.executeNow(
      onStateChange: (change) {
        if (mounted) setState(() => _state = change);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller!;
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return CupertinoPageScaffold(
      key: const Key('chat-search-page'),
      navigationBar: CupertinoNavigationBar(
        middle: const Text('查找聊天记录'),
        transitionBetweenRoutes: false,
      ),
      backgroundColor:
          dark ? WeChatColors.darkPageBackground : WeChatColors.lightPageBackground,
      child: SafeArea(
        child: Column(children: [
          _searchBar(dark),
          _filterChips(controller),
          Expanded(child: _body(controller)),
        ]),
      ),
    );
  }

  Widget _searchBar(bool dark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(children: [
        Expanded(
          child: CupertinoSearchTextField(
            key: const Key('chat-search-input'),
            controller: _input,
            placeholder: '搜索',
            onChanged: _onChanged,
            onSubmitted: (_) => _execute(),
          ),
        ),
      ]),
    );
  }

  /// 五个筛选入口（日期/图片与视频/文件/链接/群成员——私聊隐藏成员）。
  Widget _filterChips(ChatSearchQueryController controller) {
    final chips = <Widget>[
      _chip('日期', ChatSearchFilterKind.media,
          key: const Key('chat-search-filter-date'), onTap: _openCalendar),
      _chip('图片与视频', ChatSearchFilterKind.media,
          key: const Key('chat-search-filter-media'),
          onTap: () => _toggleMedia(ChatSearchMediaCategory.imageVideo)),
      _chip('文件', ChatSearchFilterKind.media,
          key: const Key('chat-search-filter-file'),
          onTap: () => _toggleMedia(ChatSearchMediaCategory.file)),
      _chip('链接', ChatSearchFilterKind.media,
          key: const Key('chat-search-filter-link'),
          onTap: () => _toggleMedia(ChatSearchMediaCategory.link)),
      if (widget.isGroup)
        _chip('群成员', ChatSearchFilterKind.sender,
            key: const Key('chat-search-filter-member'), onTap: _pickMember),
    ];
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: chips,
      ),
    );
  }

  Widget _chip(String label, ChatSearchFilterKind kind,
      {required Key key, VoidCallback? onTap}) {
    final active = _controller!.activeFilters.any((f) =>
        f.kind == kind && (kind != ChatSearchFilterKind.media || true));
    return Padding(
      key: key,
      padding: const EdgeInsets.only(right: 8),
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        color: active
            ? WeChatColors.brandPrimary.withValues(alpha: .15)
            : WeChatColors.darkSurface.withValues(alpha: .5),
        borderRadius: BorderRadius.circular(16),
        minimumSize: const Size(0, 30),
        onPressed: onTap,
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                color: active
                    ? WeChatColors.brandPrimary
                    : WeChatColors.resolveTextPrimary(context))),
      ),
    );
  }

  void _toggleMedia(ChatSearchMediaCategory category) {
    setState(() {
      final current = _controller!.activeFilters
          .where((f) => f.kind == ChatSearchFilterKind.media)
          .toList();
      _controller!.setMediaCategory(
          current.any((f) => f.value == category.name) ? null : category);
    });
    _execute();
  }

  Future<void> _pickMember() async {
    final picked = await Navigator.of(context).push<MemberDirectoryEntry>(
      CupertinoPageRoute(
        builder: (_) => MemberPickerPage(entries: widget.memberEntries),
      ),
    );
    if (picked != null) {
      setState(() => _controller!.setSender(picked.userId));
      _execute();
    }
  }

  Future<void> _openCalendar() async {
    final picked = await Navigator.of(context).push<DateTime>(
      CupertinoPageRoute(
        builder: (_) => const CalendarPickerPage(
            earliest: logic.CalendarMonth(2025, 1),
            latest: logic.CalendarMonth(2026, 12)),
      ),
    );
    if (picked != null && mounted) {
      // 日期作为独立定位工具（规格 #4）：提示"按会话全部消息定位"。
      showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('按日期定位'),
          content: Text('将按会话全部消息定位到 '
              '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    }
  }

  Widget _body(ChatSearchQueryController controller) {
    // 默认空态（#4 验收：首次进入无消息行）。
    if (controller.isDefaultEmptyState) {
      return Center(
        key: const Key('chat-search-empty'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(CupertinoIcons.search, size: 44, color: WeChatColors.textTertiary),
            const SizedBox(height: 12),
            const Text('请选择筛选条件或输入关键字',
                style: TextStyle(fontSize: 14, color: WeChatColors.textSecondary)),
          ],
        ),
      );
    }
    if (_state is ChatSearchLoadingState) {
      return const Center(child: CupertinoActivityIndicator());
    }
    if (_state is ChatSearchFailedState) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('查询失败', style: TextStyle(fontSize: 14, color: WeChatColors.textSecondary)),
            const SizedBox(height: 8),
            CupertinoButton(
              key: const Key('chat-search-retry'),
              onPressed: _execute,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final page = _lastPage = (_state is ChatSearchLoadedState)
        ? (_state as ChatSearchLoadedState).page
        : _lastPage;
    if (page == null || page.items.isEmpty) {
      return const Center(
        key: Key('chat-search-no-results'),
        child: Text('未找到符合条件的聊天记录',
            style: TextStyle(fontSize: 14, color: WeChatColors.textSecondary)),
      );
    }
    return ListView.builder(
      key: const Key('chat-search-results'),
      controller: _scroll,
      itemCount: page.items.length,
      itemBuilder: (context, index) {
        final message = page.items[index];
        return _ResultRow(
          message: message,
          keyword: controller.hasKeywordInput ? _input.text.trim() : '',
          displayName: widget.senderDisplayName?.call(message.senderId) ??
              message.senderDisplayName,
          onTap: () => widget.onJumpToMessage(message.eventId),
        );
      },
    );
  }
}

/// 结果行（#5）：头像 / 备注名>昵称>用户名 / 摘要+高亮 / 时间。
final class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.message,
    required this.keyword,
    required this.displayName,
    required this.onTap,
  });

  final ChatSearchMessage message;
  final String keyword;
  final String displayName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final segments = keyword.isEmpty
        ? [const ChatSearchHighlightSegment('', false)]
        : buildHighlightSnippet(message.visibleText, keyword);
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return GestureDetector(
      key: Key('chat-search-result-${message.eventId}'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: dark ? WeChatColors.darkSurface : WeChatColors.lightSurface,
          border: Border(
            bottom: BorderSide(
                width: .5, color: dark ? WeChatColors.darkDivider : WeChatColors.divider),
          ),
        ),
        child: Row(children: [
          // 发送者头像（占位圆形——真实头像由调用方接入缓存）。
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: WeChatColors.brandPrimary,
            ),
            alignment: Alignment.center,
            child: Text(
              displayName.isNotEmpty ? displayName.characters.first : '?',
              style: const TextStyle(
                  fontSize: 16, color: CupertinoColors.white),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    formatSearchResultTime(message.timestamp),
                    style: const TextStyle(
                        fontSize: 12, color: WeChatColors.textTertiary),
                  ),
                ]),
                const SizedBox(height: 2),
                // 摘要 + 关键词高亮（安全文本片段）。
                Text.rich(
                  TextSpan(
                    children: [
                      for (final segment in segments)
                        TextSpan(
                          text: segment.text,
                          style: segment.highlighted
                              ? const TextStyle(
                                  color: WeChatColors.brandPrimary,
                                  fontWeight: FontWeight.w700)
                              : const TextStyle(
                                  color: WeChatColors.textSecondary),
                        ),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
          // 媒体缩略（图片视频/文件图标）。
          if (message.mediaCategory == ChatSearchMediaCategory.imageVideo)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(CupertinoIcons.photo, size: 40, color: WeChatColors.textTertiary),
            ),
        ]),
      ),
    );
  }
}

/// 规格 #6：成员选择页（拼音分组 A-Z+#、搜索、点击返回）。
final class MemberPickerPage extends StatefulWidget {
  const MemberPickerPage({super.key, required this.entries});

  final List<MemberDirectoryEntry> entries;

  @override
  State<MemberPickerPage> createState() => _MemberPickerPageState();
}

final class _MemberPickerPageState extends State<MemberPickerPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final sorted = sortAndFilterMemberEntries(widget.entries, _query);
    final grouped = groupMemberEntriesBySection(sorted);
    return CupertinoPageScaffold(
      key: const Key('member-picker-page'),
      navigationBar: const CupertinoNavigationBar(
        middle: Text('选择群成员'),
        transitionBetweenRoutes: false,
      ),
      backgroundColor:
          dark ? WeChatColors.darkPageBackground : WeChatColors.lightPageBackground,
      child: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: CupertinoSearchTextField(
              key: const Key('member-picker-search'),
              placeholder: '搜索',
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Expanded(
            child: sorted.isEmpty
                ? const Center(
                    key: Key('member-picker-empty'),
                    child: Text('未找到群成员',
                        style: TextStyle(
                            fontSize: 14, color: WeChatColors.textSecondary)))
                : ListView.builder(
                    key: const Key('member-picker-list'),
                    itemCount: grouped.length,
                    itemBuilder: (context, sectionIndex) {
                      final section = grouped.keys.elementAt(sectionIndex);
                      final members = grouped[section]!;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: double.infinity,
                            color: dark
                                ? WeChatColors.darkPageBackground
                                : WeChatColors.lightPageBackground,
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                            child: Text(section,
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: WeChatColors.textTertiary)),
                          ),
                          for (final member in members)
                            GestureDetector(
                              key: Key('member-picker-${member.userId}'),
                              onTap: () => Navigator.of(context).pop(member),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                                decoration: BoxDecoration(
                                  color: dark
                                      ? WeChatColors.darkSurface
                                      : WeChatColors.lightSurface,
                                  border: Border(
                                    bottom: BorderSide(
                                        width: .5,
                                        color: dark
                                            ? WeChatColors.darkDivider
                                            : WeChatColors.divider),
                                  ),
                                ),
                                child: Row(children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: WeChatColors.brandPrimary,
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      member.displayName.isNotEmpty
                                          ? member.displayName.characters.first
                                          : '?',
                                      style: const TextStyle(
                                          fontSize: 15,
                                          color: CupertinoColors.white),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(member.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 15)),
                                  ),
                                  if (member.hasLeftGroup)
                                    const Text('已离群',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: WeChatColors.textTertiary)),
                                ]),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}

/// 规格 #7：月历选择页（周一开头、三态日期、导航钳制）。
final class CalendarPickerPage extends StatefulWidget {
  const CalendarPickerPage({
    super.key,
    required this.earliest,
    required this.latest,
    this.datesWithMessages = const {},
    this.scanningDates = const {},
    this.onDateTap,
  });

  final logic.CalendarMonth earliest;
  final logic.CalendarMonth latest;
  final Set<DateTime> datesWithMessages;
  final Set<DateTime> scanningDates;
  final void Function(DateTime date)? onDateTap;

  @override
  State<CalendarPickerPage> createState() => _CalendarPickerPageState();
}

final class _CalendarPickerPageState extends State<CalendarPickerPage> {
  late logic.CalendarMonth _current;

  @override
  void initState() {
    super.initState();
    _current = widget.latest;
  }

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final canPrev = widget.latest
        .canNavigateTo(_current.previous, earliest: widget.earliest, latest: widget.latest);
    final canNext =
        widget.latest.canNavigateTo(_current.next, earliest: widget.earliest, latest: widget.latest);
    return CupertinoPageScaffold(
      key: const Key('calendar-picker-page'),
      navigationBar: const CupertinoNavigationBar(
        middle: Text('选择日期'),
        transitionBetweenRoutes: false,
      ),
      backgroundColor:
          dark ? WeChatColors.darkPageBackground : WeChatColors.lightPageBackground,
      child: SafeArea(
        child: Column(children: [
          // 月份标题 + 上/下月导航。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                CupertinoButton(
                  key: const Key('calendar-prev-month'),
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.all(8),
                  onPressed: canPrev
                      ? () => setState(() => _current = _current.previous)
                      : null,
                  child: const Icon(CupertinoIcons.chevron_left, size: 20),
                ),
                Text(_current.title,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600)),
                CupertinoButton(
                  key: const Key('calendar-next-month'),
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.all(8),
                  onPressed: canNext
                      ? () => setState(() => _current = _current.next)
                      : null,
                  child: const Icon(CupertinoIcons.chevron_right, size: 20),
                ),
              ],
            ),
          ),
          // 周一至周日表头。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final day in ['一', '二', '三', '四', '五', '六', '日'])
                  Expanded(
                    child: Center(
                      child: Text(day,
                          style: const TextStyle(
                              fontSize: 12, color: WeChatColors.textTertiary)),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // 日期网格。
          Expanded(
            child: GridView.builder(
              key: const Key('calendar-grid'),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 7, childAspectRatio: 1),
              itemCount: _leadingBlanks() + _current.daysInMonth,
              itemBuilder: (context, index) {
                final blank = index < _leadingBlanks();
                if (blank) return const SizedBox.shrink();
                final day = index - _leadingBlanks() + 1;
                final date = DateTime(_current.year, _current.month, day);
                final status = logic.dayStatus(date,
                    datesWithMessages: widget.datesWithMessages,
                    scanningDates: widget.scanningDates);
                final enabled = status == logic.CalendarDayStatus.hasMessages;
                return GestureDetector(
                  key: Key('calendar-day-$day'),
                  onTap: enabled ? () => _pick(date) : null,
                  child: Container(
                    margin: const EdgeInsets.all(2),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: status == logic.CalendarDayStatus.hasMessages
                          ? WeChatColors.brandPrimary.withValues(alpha: .12)
                          : null,
                    ),
                    child: Text(
                      '$day',
                      style: TextStyle(
                        fontSize: 15,
                        color: switch (status) {
                          logic.CalendarDayStatus.hasMessages =>
                            WeChatColors.resolveTextPrimary(context),
                          logic.CalendarDayStatus.scanning =>
                            WeChatColors.textTertiary,
                          _ => const Color(0xFFCCCCCC),
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  int _leadingBlanks() => _current.firstWeekdayMondayBased - 1;

  void _pick(DateTime date) {
    if (widget.onDateTap != null) {
      widget.onDateTap!(date);
      return;
    }
    Navigator.of(context).pop(date);
  }
}

/// 规格 #8：图片与视频 / 文件 / 链接 三分类页（共享分页骨架）。
final class ChatCategoryPage extends StatelessWidget {
  const ChatCategoryPage({
    super.key,
    required this.title,
    required this.category,
    required this.messages,
    required this.onOpen,
  });

  final String title;
  final ChatSearchMediaCategory category;
  final List<ChatSearchMessage> messages;
  final void Function(ChatSearchMessage message) onOpen;

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return CupertinoPageScaffold(
      key: Key('chat-category-$title'),
      navigationBar: CupertinoNavigationBar(
        middle: Text(title),
        transitionBetweenRoutes: false,
      ),
      backgroundColor:
          dark ? WeChatColors.darkPageBackground : WeChatColors.lightPageBackground,
      child: SafeArea(
        child: messages.isEmpty
            ? Center(
                key: const Key('chat-category-empty'),
                child: Text('暂无$title',
                    style: const TextStyle(
                        fontSize: 14, color: WeChatColors.textSecondary)))
            : _categoryBody(),
      ),
    );
  }

  Widget _categoryBody() {
    return switch (category) {
      // 图片与视频：按日期分组三列网格。
      ChatSearchMediaCategory.imageVideo => _mediaGrid(),
      // 文件：列表（图标+文件名+大小+发送者+时间）。
      ChatSearchMediaCategory.file => _fileList(),
      // 链接：列表（标题+摘要+域名+时间）。
      ChatSearchMediaCategory.link => _linkList(),
    };
  }

  Widget _mediaGrid() {
    final grouped = <String, List<ChatSearchMessage>>{};
    for (final m in messages) {
      final key =
          '${m.timestamp.year}-${m.timestamp.month}-${m.timestamp.day}';
      grouped.putIfAbsent(key, () => []).add(m);
    }
    return ListView(
      children: [
        for (final entry in grouped.entries)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                child: Text(entry.key,
                    style: const TextStyle(
                        fontSize: 13, color: WeChatColors.textSecondary)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: GridView.count(
                  crossAxisCount: 3,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 2,
                  crossAxisSpacing: 2,
                  childAspectRatio: 1,
                  children: [
                    for (final message in entry.value)
                      // 缩略图占位（真实缩略图由调用方注入；此处保持
                      // contain 完整适配——规格 #10/#8）。
                      ContainGridCell(
                        key: Key('category-media-${message.eventId}'),
                        bytes: _placeholderBytes(message),
                        cellSize: 120,
                        onTap: () => onOpen(message),
                        overlay: message.mediaCategory ==
                                ChatSearchMediaCategory.imageVideo
                            ? const Center(
                                child: Icon(CupertinoIcons.play_fill,
                                    size: 24,
                                    color: Color(0xCCFFFFFF)))
                            : null,
                      ),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }

  /// 缩略占位（真实图片字节由调用方通过消息事件加载接入会话缓存——
  /// 规格 #1 的 UI 接线点）。
  static final _placeholder = Uint8List.fromList(const [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00,
        0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89,
      ]);
  Uint8List _placeholderBytes(ChatSearchMessage message) => _placeholder;

  Widget _fileList() {
    return ListView.builder(
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        return _listRow(
          key: 'category-file-${message.eventId}',
          icon: CupertinoIcons.doc,
          title: _fileNameOf(message),
          subtitle:
              '${logic.FileDisplayFallback.sizeLabel(null)} · ${message.senderDisplayName}',
          trailing: formatSearchResultTime(message.timestamp),
          message: message,
        );
      },
    );
  }

  String _fileNameOf(ChatSearchMessage message) =>
      logic.FileDisplayFallback.fileName(
          message.visibleText.trim().isEmpty ? null : message.visibleText.trim());

  Widget _linkList() {
    return ListView.builder(
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        final links = logic.extractHttpLinks(message.visibleText);
        final preview = links.isEmpty
            ? null
            : logic.LinkPreviewModel(url: links.first);
        return _listRow(
          key: 'category-link-${message.eventId}',
          icon: CupertinoIcons.link,
          title: preview?.displayTitle ?? '链接',
          subtitle: preview?.displaySummary ?? message.visibleText,
          trailing: formatSearchResultTime(message.timestamp),
          message: message,
        );
      },
    );
  }

  Widget _listRow({
    required String key,
    required IconData icon,
    required String title,
    required String subtitle,
    required String trailing,
    required ChatSearchMessage message,
  }) {
    return GestureDetector(
      key: Key(key),
      onTap: () => onOpen(message),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: const BoxDecoration(
          border:
              Border(bottom: BorderSide(width: .5, color: WeChatColors.divider)),
        ),
        child: Row(children: [
          Icon(icon, size: 36, color: WeChatColors.brandPrimary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: WeChatColors.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(trailing,
              style: const TextStyle(
                  fontSize: 12, color: WeChatColors.textTertiary)),
        ]),
      ),
    );
  }
}
