import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../features/contacts/member_directory_service.dart';
import '../../features/matrix/chat_media_shared_logic.dart' as logic;
import '../../features/matrix/chat_search_query_controller.dart';

import '../../ui/foundation/wechat_tokens.dart';
import '../components/user_avatar.dart';
import '../components/wechat_gradient_divider.dart';
import '../motion/motion_page_route.dart';

/// The result of an explicit date query. An incomplete bounded scan must not
/// be presented as a confirmed empty day.
enum CalendarDateLookupResult { located, confirmedEmpty, incomplete }

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
    this.identityChanges,
    this.liveMemberEntries,
    this.memberAvatarBuilder,
    this.mediaThumbnailBuilder,
    this.onOpenMedia,
    this.earliestMonth,
    this.latestMonth,
    this.onJumpToDate,
    this.onDateLookup,
    this.onCancelDateLookup,
    this.loadCalendarMonth,
    this.onCancelCalendarMonthLookup,
    this.onCalendarClosed,
    this.onSearchInvalidated,
  });

  /// 是否群聊（决定是否显示"群成员"筛选入口）。
  final bool isGroup;
  final Widget Function(BuildContext, MemberDirectoryEntry)?
      memberAvatarBuilder;
  final Widget Function(BuildContext, ChatSearchMessage)? mediaThumbnailBuilder;
  final void Function(String eventId)? onOpenMedia;

  /// 数据源检索回调（已解密、可访问、未撤回）。
  final Future<List<ChatSearchMessage>> Function(ChatSearchFilters filters,
      {ChatSearchCursor? cursor, int limit}) search;

  /// 群成员目录（成员筛选入口的数据；私聊传空）。
  final List<MemberDirectoryEntry> memberEntries;
  final List<MemberDirectoryEntry> Function()? liveMemberEntries;

  /// 点击结果 → 定位原消息（统一走定位服务）。
  final void Function(String eventId) onJumpToMessage;

  /// 发送者显示名解析（结果行顶部：备注>昵称>用户名）。
  final String Function(String senderId)? senderDisplayName;
  final Listenable? identityChanges;

  /// 可访问历史最早/最新月份（导航钳制）。
  ///
  /// [earliestMonth] 为 null 表示"尚无证据表明更早已无可显示消息"，此时允许
  /// 继续向前翻月（每个月都是独立的有界 metadata 查询），**不得**用它伪造
  /// 1970-01。[latestMonth] 为 null 时使用当前月。
  final logic.CalendarMonth? earliestMonth;
  final logic.CalendarMonth? latestMonth;

  /// 日期定位回调（选中日期后直接定位，不再只弹说明——R6 修复）。
  final void Function(DateTime date)? onJumpToDate;
  final Future<CalendarDateLookupResult> Function(DateTime date)? onDateLookup;
  final VoidCallback? onCancelDateLookup;

  /// 月级日期 metadata 加载（Task A：只读日期状态，不加载正文/媒体）。
  final Future<logic.RoomHistoryMonthDays> Function(logic.CalendarMonth month)?
      loadCalendarMonth;

  /// 取消在途月查询（切月/关闭）。
  final VoidCallback? onCancelCalendarMonthLookup;
  final VoidCallback? onCalendarClosed;
  final VoidCallback? onSearchInvalidated;

  @override
  State<ChatSearchPage> createState() => _ChatSearchPageState();
}

final class _ChatSearchPageState extends State<ChatSearchPage> {
  List<MemberDirectoryEntry> get memberEntries =>
      widget.liveMemberEntries?.call() ?? widget.memberEntries;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  ChatSearchQueryController? _controller;
  ChatSearchStateChange _state = const ChatSearchStateChange.empty();
  ChatSearchResultPage? _lastPage;
  Timer? _debounce;
  bool _loadingMore = false;
  int _queryGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.identityChanges?.addListener(_identityChanged);
    _controller = ChatSearchQueryController(
      search: widget.search,
      debounce: const Duration(milliseconds: 300),
    );
  }

  @override
  void didUpdateWidget(covariant ChatSearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identityChanges != widget.identityChanges) {
      oldWidget.identityChanges?.removeListener(_identityChanged);
      widget.identityChanges?.addListener(_identityChanged);
    }
  }

  void _identityChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.identityChanges?.removeListener(_identityChanged);
    _debounce?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    widget.onSearchInvalidated?.call();
    setState(() => _controller!.setKeyword(value));
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _execute);
  }

  Future<void> _execute() async {
    widget.onSearchInvalidated?.call();
    _debounce?.cancel();
    _queryGeneration++;
    setState(() => _loadingMore = false);
    try {
      await _controller!.executeNow(
        onStateChange: (change) {
          if (!mounted) return;
          setState(() {
            _state = change;
            // 翻页修复：新查询结果到达时更新 _lastPage（此后 _loadMore
            // 追加的页不会被 build 覆盖——build 只读不写）。
            if (change is ChatSearchLoadedState) {
              _lastPage = change.page;
            }
          });
        },
      );
    } catch (_) {
      // The controller already publishes the failure state for the current query.
    }
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
      backgroundColor: dark
          ? WeChatColors.darkPageBackground
          : WeChatColors.lightPageBackground,
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
          media: ChatSearchMediaCategory.imageVideo,
          onTap: () => _toggleMedia(ChatSearchMediaCategory.imageVideo)),
      _chip('文件', ChatSearchFilterKind.media,
          key: const Key('chat-search-filter-file'),
          media: ChatSearchMediaCategory.file,
          onTap: () => _toggleMedia(ChatSearchMediaCategory.file)),
      _chip('链接', ChatSearchFilterKind.media,
          key: const Key('chat-search-filter-link'),
          media: ChatSearchMediaCategory.link,
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
      {required Key key, VoidCallback? onTap, ChatSearchMediaCategory? media}) {
    final active = _controller!.activeFilters.any((f) =>
        f.kind == kind &&
        (kind != ChatSearchFilterKind.media || f.value == media?.name));
    return Padding(
      key: key,
      padding: const EdgeInsets.only(right: 8),
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        color: active
            ? WeChatColors.brandPrimary.withValues(alpha: .15)
            : WeChatColors.elevatedSurface(context),
        borderRadius: BorderRadius.circular(16),
        minimumSize: const Size(0, 30),
        onPressed: onTap,
        child: Text(label,
            style: TextStyle(
                fontSize: 13, color: WeChatColors.resolveTextPrimary(context))),
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
    Widget picker() => MemberPickerPage(
        entries: memberEntries, avatarBuilder: widget.memberAvatarBuilder);
    final picked = await Navigator.of(context).push<MemberDirectoryEntry>(
      MotionPageRoute(
        builder: (_) => widget.identityChanges == null
            ? picker()
            : ListenableBuilder(
                listenable: widget.identityChanges!,
                builder: (context, _) => picker()),
      ),
    );
    if (picked != null && mounted) {
      setState(() => _controller!.setSender(picked.userId));
      _execute();
    }
  }

  Future<void> _openCalendar() async {
    // Task A：月历只读日期 metadata（RoomHistoryMonthDays），与聊天正文解耦。
    // 最早月份缺失时不伪造 1970，交由 room 侧索引/创建时间决定。
    final now = logic.CalendarMonth.of(DateTime.now());
    final picked = await Navigator.of(context).push<DateTime>(
      MotionPageRoute(
        builder: (_) => CalendarPickerPage(
          earliest: widget.earliestMonth,
          latest: widget.latestMonth ?? now,
          loadMonth: widget.loadCalendarMonth,
          onCancelMonthLookup: widget.onCancelCalendarMonthLookup,
          onDateLookup: widget.onDateLookup,
          onCancelDateLookup: widget.onCancelDateLookup,
        ),
      ),
    );
    if (picked == null) widget.onCalendarClosed?.call();
    if (picked != null && mounted) {
      // R6 修复：日期选择后**直接调用定位回调**（不再只弹说明框）。
      if (widget.onJumpToDate != null) {
        widget.onJumpToDate!(picked);
      } else {
        Navigator.of(context).pop();
      }
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
            const Icon(CupertinoIcons.search,
                size: 44, color: WeChatColors.textTertiary),
            const SizedBox(height: 12),
            const Text('请选择筛选条件或输入关键字',
                style:
                    TextStyle(fontSize: 14, color: WeChatColors.textSecondary)),
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
            const Text('查询失败',
                style:
                    TextStyle(fontSize: 14, color: WeChatColors.textSecondary)),
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
    // 翻页修复：渲染只读 _lastPage（不在 build 中被 _state 覆盖）；
    // _lastPage 由 executeNow 的 loaded 回调和 _loadMore 共同维护。
    final page = _lastPage;
    if (page == null || page.items.isEmpty) {
      return const Center(
        key: Key('chat-search-no-results'),
        child: Text('未找到符合条件的聊天记录',
            style: TextStyle(fontSize: 14, color: WeChatColors.textSecondary)),
      );
    }
    if (controller.activeFilters.any((filter) =>
        filter.kind == ChatSearchFilterKind.media &&
        filter.value == ChatSearchMediaCategory.imageVideo.name)) {
      return NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollUpdateNotification &&
              notification.metrics.extentAfter < 200 &&
              !_loadingMore &&
              page.nextCursor != null) {
            _loadMore(page);
          }
          return false;
        },
        child: _MediaGrid(
          messages: page.items,
          controller: _scroll,
          thumbnailBuilder: widget.mediaThumbnailBuilder,
          onOpen: (message) =>
              (widget.onOpenMedia ?? widget.onJumpToMessage)(message.eventId),
          footer: page.nextCursor == null
              ? null
              : Padding(
                  padding: const EdgeInsets.all(12),
                  child: _loadingMore
                      ? const Center(child: CupertinoActivityIndicator())
                      : CupertinoButton(
                          key: const Key('chat-search-load-more'),
                          onPressed: () => _loadMore(page),
                          child: const Text('加载更多')),
                ),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // 滚动接近底部（80%+）且有下一页 → loadMore。
        if (notification is ScrollUpdateNotification &&
            !_loadingMore &&
            page.nextCursor != null &&
            _scroll.position.extentAfter < 200) {
          _loadMore(page);
        }
        return false;
      },
      child: ListView.builder(
        key: const Key('chat-search-results'),
        controller: _scroll,
        itemCount: page.items.length + (page.nextCursor != null ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= page.items.length) {
            // 页脚三态：正在加载 / 已到末尾（无 footer）/ 翻页失败重试。
            if (_loadingMore) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CupertinoActivityIndicator(radius: 10)),
              );
            }
            return Padding(
              padding: const EdgeInsets.all(12),
              child: CupertinoButton(
                key: const Key('chat-search-load-more'),
                minimumSize: Size.zero,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                onPressed: () => _loadMore(page),
                child: const Text('加载更多',
                    style: TextStyle(
                        fontSize: 13, color: WeChatColors.brandPrimary)),
              ),
            );
          }
          final message = page.items[index];
          final member = memberEntries
                  .where((entry) => entry.userId == message.senderId)
                  .firstOrNull ??
              MemberDirectoryEntry(
                userId: message.senderId,
                nickname: message.senderDisplayName,
              );
          return _ResultRow(
            message: message,
            keyword: controller.hasKeywordInput ? _input.text.trim() : '',
            displayName: widget.senderDisplayName?.call(message.senderId) ??
                member.displayName,
            avatar: widget.memberAvatarBuilder?.call(context, member),
            onTap: () => widget.onJumpToMessage(message.eventId),
          );
        },
      ),
    );
  }

  /// 翻页加载（R6 修复：实际调用 loadMore + 追加到状态）。
  Future<void> _loadMore(ChatSearchResultPage current) async {
    if (_loadingMore || current.nextCursor == null) return;
    final generation = _queryGeneration;
    setState(() => _loadingMore = true);
    try {
      final next = await _controller!.loadMore(current);
      if (mounted && generation == _queryGeneration && !next.stale) {
        setState(() => _lastPage = next);
      }
    } catch (_) {
      // 翻页失败保持当前页；下次滚动重试。
    } finally {
      if (mounted && generation == _queryGeneration) {
        setState(() => _loadingMore = false);
      }
    }
  }
}

/// 结果行（#5）：头像 / 备注名>昵称>用户名 / 摘要+高亮 / 时间。
final class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.message,
    required this.keyword,
    required this.displayName,
    required this.onTap,
    this.avatar,
  });

  final ChatSearchMessage message;
  final String keyword;
  final String displayName;
  final VoidCallback onTap;
  final Widget? avatar;

  @override
  Widget build(BuildContext context) {
    final text = message.displayText ?? message.visibleText;
    final segments = keyword.isEmpty
        ? [ChatSearchHighlightSegment(text, false)]
        : buildHighlightSnippet(text, keyword);
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return GestureDetector(
      key: Key('chat-search-result-${message.eventId}'),
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: dark ? WeChatColors.darkSurface : WeChatColors.lightSurface,
        ),
        // 需求 §19：行底分隔线统一由共享渐隐分割线承担。
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(children: [
          avatar ??
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
              child: Icon(CupertinoIcons.photo,
                  size: 40, color: WeChatColors.textTertiary),
            ),
                ]),
              ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: WeChatGradientDivider(
                  key: Key('chat-search-result-row-divider')),
            ),
          ],
        ),
      ),
    );
  }
}

/// 规格 #6：成员选择页（拼音分组 A-Z+#、搜索、点击返回）。
final class MemberPickerPage extends StatefulWidget {
  const MemberPickerPage(
      {super.key, required this.entries, this.avatarBuilder});

  final Widget Function(BuildContext, MemberDirectoryEntry)? avatarBuilder;

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
      backgroundColor: dark
          ? WeChatColors.darkPageBackground
          : WeChatColors.lightPageBackground,
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
                                decoration: BoxDecoration(
                                  color: dark
                                      ? WeChatColors.darkSurface
                                      : WeChatColors.lightSurface,
                                ),
                                // 需求 §19：行底分隔线统一由共享渐隐分割线承担。
                                child: Stack(
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 10),
                                      child: Row(children: [
                                        widget.avatarBuilder
                                                ?.call(context, member) ??
                                            UserAvatar(
                                              nickname: member.displayName,
                                              fallbackSeed: member.userId,
                                              diagnosticSource:
                                                  'search-member-picker',
                                              size: 36,
                                            ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(member.displayName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  fontSize: 15)),
                                        ),
                                        if (member.hasLeftGroup)
                                          const Text('已离群',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: WeChatColors
                                                      .textTertiary)),
                                      ]),
                                    ),
                                    const Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: 0,
                                      child: WeChatGradientDivider(
                                          key: Key(
                                              'chat-search-member-row-divider')),
                                    ),
                                  ],
                                ),
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

/// 规格 #7：月历选择页（周一开头、typed 日期状态、导航钳制）。
///
/// 数据来源是 [logic.RoomHistoryMonthDays]（**只有日期 metadata**，与聊天正文
/// 解耦）：knownPresent 高亮可点；knownEmpty 弱化且不可点（有证据的确认空）；
/// unknown 是普通可点文字（点击触发该日的**有界**定位查询，绝不显示成
/// "无消息"）；未来日期一律不可点；月 metadata 加载中/失败是独立状态，绝不
/// 冒充"本月没有聊天记录"。
///
/// 切月与关闭都会取消在途月查询（generation guard + [onCancelMonthLookup]），
/// 过期响应必须丢弃。
final class CalendarPickerPage extends StatefulWidget {
  const CalendarPickerPage({
    super.key,
    required this.latest,
    this.earliest,
    this.initialMonth,
    this.loadMonth,
    this.onCancelMonthLookup,
    this.onDateTap,
    this.onDateLookup,
    this.onCancelDateLookup,
  });

  /// 最新可访问月份（导航上界，通常是当前月）。
  final logic.CalendarMonth latest;

  /// 已知最早月份。null = 尚无证据；此时允许继续向前翻月（每个月都是独立的
  /// 有界查询），**不得**回退成 1970-01。
  final logic.CalendarMonth? earliest;

  /// 打开时显示的月份；缺省用 [latest]。
  final logic.CalendarMonth? initialMonth;

  /// 月级日期 metadata 加载（本地索引优先；不得加载正文/媒体）。
  final Future<logic.RoomHistoryMonthDays> Function(logic.CalendarMonth month)?
      loadMonth;
  final VoidCallback? onCancelMonthLookup;
  final void Function(DateTime date)? onDateTap;
  final Future<CalendarDateLookupResult> Function(DateTime date)? onDateLookup;
  final VoidCallback? onCancelDateLookup;

  @override
  State<CalendarPickerPage> createState() => _CalendarPickerPageState();
}

final class _CalendarPickerPageState extends State<CalendarPickerPage> {
  late logic.CalendarMonth _current;
  final Map<String, logic.RoomHistoryMonthDays> _months = {};
  int _monthGeneration = 0;
  bool _monthLoading = false;
  Object? _monthError;
  bool _picked = false;
  DateTime? _lookupDate;
  DateTime? _retryDate;
  CalendarDateLookupResult? _lookupResult;
  bool _lookupFailed = false;
  int _lookupGeneration = 0;

  logic.RoomHistoryMonthDays? get _days => _months[_current.key];

  void _discardDateLookup() {
    if (_lookupDate == null) return;
    _lookupGeneration++;
    _lookupDate = null;
    widget.onCancelDateLookup?.call();
  }

  void _cancelDateLookup() {
    _discardDateLookup();
    setState(() {
      _lookupResult = null;
      _lookupFailed = false;
    });
  }

  Future<void> _lookupDateAndPick(DateTime date) async {
    final lookup = widget.onDateLookup;
    if (lookup == null) return _pick(date);
    final generation = ++_lookupGeneration;
    setState(() {
      _lookupDate = date;
      _retryDate = date;
      _lookupResult = null;
      _lookupFailed = false;
    });
    try {
      final result = await lookup(date);
      if (!mounted || generation != _lookupGeneration) return;
      if (result == CalendarDateLookupResult.located) {
        _picked = true;
        Navigator.of(context).pop(date);
        return;
      }
      setState(() {
        _lookupDate = null;
        _lookupResult = result;
      });
    } catch (_) {
      if (!mounted || generation != _lookupGeneration) return;
      setState(() {
        _lookupDate = null;
        _lookupFailed = true;
      });
    }
  }

  Future<void> _retryDateLookup() async {
    final date = _retryDate;
    if (date != null) await _lookupDateAndPick(date);
  }

  /// 读取当前月的日期 metadata。缓存月直接复用，不重复查询。
  ///
  /// [announceLoading] 为 false 时由调用方（initState）直接设置状态字段，
  /// 避免在 initState 内同步 setState。
  Future<void> _loadMonth({bool announceLoading = true}) async {
    final loader = widget.loadMonth;
    final month = _current;
    final generation = ++_monthGeneration;
    if (loader == null) {
      if (announceLoading) {
        setState(() {
          _monthLoading = false;
          _monthError = null;
        });
      }
      return;
    }
    if (announceLoading) {
      setState(() {
        _monthLoading = true;
        _monthError = null;
      });
    }
    try {
      final days = await loader(month);
      if (!mounted || generation != _monthGeneration) return;
      setState(() {
        _months[month.key] = days;
        _monthLoading = false;
        _monthError = days.error;
      });
    } catch (error) {
      if (!mounted || generation != _monthGeneration) return;
      setState(() {
        _monthLoading = false;
        _monthError = error;
      });
    }
  }

  void _navigate(logic.CalendarMonth month) {
    if (month == _current) return;
    _discardDateLookup();
    widget.onCancelMonthLookup?.call();
    setState(() {
      _current = month;
      _monthError = null;
      _retryDate = null;
      _lookupResult = null;
      _lookupFailed = false;
    });
    unawaited(_loadMonth());
  }

  @override
  void initState() {
    super.initState();
    _current = widget.initialMonth ?? widget.latest;
    _monthLoading = widget.loadMonth != null;
    unawaited(_loadMonth(announceLoading: false));
  }

  @override
  void dispose() {
    // 关闭即放弃在途月查询与日期定位：过期结果不得回到已关闭的页面。
    _monthGeneration++;
    widget.onCancelMonthLookup?.call();
    if (!_picked) _discardDateLookup();
    super.dispose();
  }

  bool _canNavigateTo(logic.CalendarMonth target) {
    if (target.compareTo(widget.latest) > 0) return false;
    final earliest = widget.earliest;
    if (earliest == null) return true;
    return target.compareTo(earliest) >= 0;
  }

  @override
  Widget build(BuildContext context) {
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final canPrev = _canNavigateTo(_current.previous);
    final canNext = _canNavigateTo(_current.next);
    final days = _days;
    final today = DateTime.now();
    final todayDay = DateTime(today.year, today.month, today.day);
    final monthKnownEmpty = !_monthLoading &&
        _monthError == null &&
        days != null &&
        !days.hasUnknown &&
        days.presentDates.isEmpty;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !_picked) _discardDateLookup();
      },
      child: CupertinoPageScaffold(
        key: const Key('calendar-picker-page'),
        navigationBar: const CupertinoNavigationBar(
          middle: Text('选择日期'),
          transitionBetweenRoutes: false,
        ),
        backgroundColor: dark
            ? WeChatColors.darkPageBackground
            : WeChatColors.lightPageBackground,
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
                    onPressed:
                        canPrev ? () => _navigate(_current.previous) : null,
                    child: const Icon(CupertinoIcons.chevron_left, size: 20),
                  ),
                  Text(_current.title,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600)),
                  CupertinoButton(
                    key: const Key('calendar-next-month'),
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.all(8),
                    onPressed: canNext ? () => _navigate(_current.next) : null,
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
                                fontSize: 12,
                                color: WeChatColors.textTertiary)),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // 月 metadata 状态：加载中/失败是独立状态，不得显示成本月无记录。
            if (_monthLoading)
              const Padding(
                key: Key('calendar-month-loading'),
                padding: EdgeInsets.all(8),
                child: Text('正在读取日期信息…'),
              ),
            if (!_monthLoading && _monthError != null)
              CupertinoButton(
                key: const Key('calendar-month-error'),
                onPressed: _loadMonth,
                child: const Text('日期信息加载失败，点击重试'),
              ),
            if (monthKnownEmpty)
              const Padding(
                key: Key('calendar-month-empty'),
                padding: EdgeInsets.all(8),
                child: Text('本月没有聊天记录，可切换到其他月份'),
              ),
            if (_lookupDate != null)
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const CupertinoActivityIndicator(
                    key: Key('calendar-date-lookup-loading')),
                const SizedBox(width: 8),
                const Text('正在定位日期…'),
                CupertinoButton(
                  key: const Key('calendar-date-lookup-cancel'),
                  onPressed: _cancelDateLookup,
                  child: const Text('取消'),
                ),
              ]),
            if (_lookupFailed)
              CupertinoButton(
                key: const Key('calendar-date-lookup-retry'),
                onPressed: _retryDateLookup,
                child: const Text('日期定位失败，点击重试'),
              ),
            if (_lookupResult == CalendarDateLookupResult.confirmedEmpty)
              CupertinoButton(
                key: const Key('calendar-date-lookup-empty'),
                onPressed: _retryDateLookup,
                child: const Text('本日暂无聊天记录'),
              ),
            if (_lookupResult == CalendarDateLookupResult.incomplete)
              CupertinoButton(
                key: const Key('calendar-date-lookup-incomplete'),
                onPressed: _retryDateLookup,
                child: const Text('该日期暂时无法确认，点击重试'),
              ),
            // 日期网格。
            Expanded(
              child: GridView.builder(
                key: const Key('calendar-grid'),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7, childAspectRatio: 1),
                itemCount: _leadingBlanks() + _current.daysInMonth,
                itemBuilder: (context, index) {
                  final leading = _leadingBlanks();
                  if (index < leading) return const SizedBox.shrink();
                  final day = index - leading + 1;
                  final date = DateTime(_current.year, _current.month, day);
                  final future = date.isAfter(todayDay);
                  final state = days?.stateOf(day) ??
                      logic.RoomHistoryDayState.unknown;
                  final knownPresent = !future &&
                      state == logic.RoomHistoryDayState.knownPresent;
                  final knownEmpty = !future &&
                      state == logic.RoomHistoryDayState.knownEmpty;
                  final scanning = !future &&
                      !knownPresent &&
                      !knownEmpty &&
                      _monthLoading;
                  // unknown（含加载中未定论的日期）保持可点：点击会走该日的
                  // 有界定位查询；knownEmpty 与未来日期不可点。
                  final enabled = !future && !knownEmpty && _lookupDate == null;
                  return GestureDetector(
                    key: Key('calendar-day-$day'),
                    onTap: enabled ? () => _lookupDateAndPick(date) : null,
                    child: Container(
                      margin: const EdgeInsets.all(2),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: knownPresent
                            ? WeChatColors.brandPrimary.withValues(alpha: .12)
                            : null,
                      ),
                      child: Text(
                        '$day',
                        style: TextStyle(
                          fontSize: 15,
                          color: future || knownEmpty
                              ? const Color(0xFFCCCCCC)
                              : scanning
                                  ? WeChatColors.textTertiary
                                  : WeChatColors.resolveTextPrimary(context),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  int _leadingBlanks() => _current.firstWeekdayMondayBased - 1;

  void _pick(DateTime date) {
    if (_picked) return;
    _picked = true;
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
    this.mediaThumbnailBuilder,
  });

  final Widget Function(BuildContext, ChatSearchMessage)? mediaThumbnailBuilder;
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
      backgroundColor: dark
          ? WeChatColors.darkPageBackground
          : WeChatColors.lightPageBackground,
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

  Widget _mediaGrid() => _MediaGrid(
      messages: messages,
      thumbnailBuilder: mediaThumbnailBuilder,
      onOpen: onOpen);

  Widget _fileList() {
    return ListView.builder(
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        return _listRow(
          context: context,
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
      logic.FileDisplayFallback.fileName(message.visibleText.trim().isEmpty
          ? null
          : message.visibleText.trim());

  Widget _linkList() {
    return ListView.builder(
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        final links = logic.extractHttpLinks(message.visibleText);
        final preview =
            links.isEmpty ? null : logic.LinkPreviewModel(url: links.first);
        return _listRow(
          context: context,
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
    required BuildContext context,
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
      // 需求 §19：行底分隔线统一由共享渐隐分割线承担（原来是自拼的
      // 0.5px 实心 Border(bottom:)）。
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: WeChatGradientDivider(
                key: Key('chat-search-category-row-divider')),
          ),
        ],
      ),
    );
  }
}

/// Lazy slivers keep only visible thumbnail rows alive, including across pages.
final class _MediaGrid extends StatelessWidget {
  const _MediaGrid(
      {required this.messages,
      required this.onOpen,
      this.thumbnailBuilder,
      this.controller,
      this.footer});
  final List<ChatSearchMessage> messages;
  final void Function(ChatSearchMessage) onOpen;
  final Widget Function(BuildContext, ChatSearchMessage)? thumbnailBuilder;
  final ScrollController? controller;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<ChatSearchMessage>>{};
    for (final message in messages) {
      final date = message.timestamp.toLocal();
      groups
          .putIfAbsent('${date.year}-${date.month}-${date.day}', () => [])
          .add(message);
    }
    return CustomScrollView(
      key: const Key('chat-search-media-grid'),
      controller: controller,
      slivers: [
        for (final group in groups.entries) ...[
          SliverToBoxAdapter(
              child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Text(group.key,
                style: const TextStyle(
                    fontSize: 13, color: WeChatColors.textSecondary)),
          )),
          SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final message = group.value[index];
                  final seconds = message.duration?.inSeconds;
                  return Semantics(
                    button: true,
                    label: message.isVideo ? '播放视频' : '查看图片',
                    child: GestureDetector(
                      key: Key('category-media-${message.eventId}'),
                      onTap: () => onOpen(message),
                      child: Stack(fit: StackFit.expand, children: [
                        thumbnailBuilder?.call(context, message) ??
                            const ColoredBox(
                                color: WeChatColors.darkSurface,
                                child: Center(
                                    child: Icon(CupertinoIcons.photo,
                                        color: WeChatColors.textTertiary))),
                        if (message.isVideo) ...[
                          const Center(
                              child: Icon(CupertinoIcons.play_fill,
                                  size: 24, color: CupertinoColors.white)),
                          if (seconds != null)
                            Positioned(
                                right: 6,
                                bottom: 6,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                      color: CupertinoColors.black
                                          .withValues(alpha: .55),
                                      borderRadius: BorderRadius.circular(3)),
                                  child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 4, vertical: 2),
                                      child: Text(
                                          '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: CupertinoColors.white))),
                                )),
                        ],
                      ]),
                    ),
                  );
                }, childCount: group.value.length),
              )),
        ],
        if (footer != null) SliverToBoxAdapter(child: footer),
      ],
    );
  }
}
