import 'dart:async';
import 'dart:typed_data';

/// 聊天记录搜索查询控制器（规格 #4/#5）：默认空态、AND 组合筛选、
/// 300ms 防抖、稳定游标分页、事件去重、安全高亮、匹配范围规则。
///
/// 纯逻辑层（可注入时钟/数据源），UI 层订阅 [state] 流渲染。
///
/// 匹配范围（#5）：用户可见正文——文本、说明文字（图片 caption）、
/// 链接文字、正文形式的文件名；不搜索附件内部/OCR/用户 ID/类型代码/
/// 密文。连续子串、英文忽略大小写、中文按字；不做模糊/正则/多词拆分。
final class ChatSearchQueryController {
  ChatSearchQueryController({
    required this.search,
    ChatSearchClock? clock,
    this.debounce = const Duration(milliseconds: 300),
  }) : _clock = clock ?? RealChatSearchClock();

  /// 数据源检索回调（已解密、可访问、未撤回的消息流；按时间新→旧）。
  final Future<List<ChatSearchMessage>> Function(ChatSearchFilters filters,
      {ChatSearchCursor? cursor, int limit}) search;

  final ChatSearchClock _clock;
  final Duration debounce;

  /// 注入时钟（测试用；生产为真实时钟）。
  ChatSearchClock get clock => _clock;

  String _keyword = '';
  String? _senderUserId;
  ChatSearchMediaCategory? _mediaCategory;

  /// 查询执行次数（测试"旧结果不覆盖新查询"）。
  int executedQueries = 0;

  /// 活动条件标签（可移除）。
  List<ChatSearchActiveFilter> get activeFilters => [
        if (_keyword.trim().isNotEmpty)
          ChatSearchActiveFilter(ChatSearchFilterKind.keyword, _keyword.trim()),
        if (_senderUserId != null)
          ChatSearchActiveFilter(
              ChatSearchFilterKind.sender, _senderUserId!),
        if (_mediaCategory != null)
          ChatSearchActiveFilter(
              ChatSearchFilterKind.media, _mediaCategory!.name),
      ];

  /// 默认空态判定：无关键词且无任何筛选。
  bool get isDefaultEmptyState =>
      _keyword.trim().isEmpty && _senderUserId == null && _mediaCategory == null;

  /// —— 筛选变更（组合规则：关键词 ∧ 发送者 ∧ 媒体分类；媒体单选、
  /// 发送者单选；日期是独立定位工具不参与列表条件）——
  void setKeyword(String keyword) {
    _keyword = keyword;
  }

  void setSender(String? userId) {
    _senderUserId = userId;
  }

  void setMediaCategory(ChatSearchMediaCategory? category) {
    _mediaCategory = category;
  }

  bool removeFilter(ChatSearchFilterKind kind) => switch (kind) {
        ChatSearchFilterKind.keyword => () {
          _keyword = '';
          return true;
        }(),
        ChatSearchFilterKind.sender => () {
          _senderUserId = null;
          return true;
        }(),
        ChatSearchFilterKind.media => () {
          _mediaCategory = null;
          return true;
        }(),
      };

  void clearAll() {
    _keyword = '';
    _senderUserId = null;
    _mediaCategory = null;
  }

  /// 关键词是否视为已输入（去首尾空白后为空 = 未输入）。
  bool get hasKeywordInput => _keyword.trim().isNotEmpty;

  /// 输入防抖：300ms 后执行（键盘搜索按钮走 [executeNow] 立即执行）。
  Timer? _debounceTimer;

  Future<ChatSearchResultPage> scheduleDebounced({
    int limit = 50,
    void Function(ChatSearchStateChange change)? onStateChange,
  }) {
    _debounceTimer?.cancel();
    final completer = Completer<ChatSearchResultPage>();
    _debounceTimer = Timer(debounce, () {
      executeNow(limit: limit, onStateChange: onStateChange)
          .then(completer.complete)
          .catchError((Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      });
    });
    return completer.future;
  }

  void cancelDebounce() => _debounceTimer?.cancel();

  /// 立即执行查询（本轮生成 epoch：旧查询的迟到结果被丢弃——
  /// "快速更换关键词只展示最新查询的结果"）。
  Future<ChatSearchResultPage> executeNow({
    int limit = 50,
    void Function(ChatSearchStateChange change)? onStateChange,
  }) async {
    _debounceTimer?.cancel();
    if (isDefaultEmptyState) {
      onStateChange?.call(const ChatSearchStateChange.empty());
      return const ChatSearchResultPage(items: [], nextCursor: null, epoch: -1);
    }
    final epoch = ++executedQueries;
    onStateChange?.call(ChatSearchStateChange.loading(epoch));
    final filters = ChatSearchFilters(
      keyword: hasKeywordInput ? _keyword.trim() : null,
      senderUserId: _senderUserId,
      mediaCategory: _mediaCategory,
    );
    try {
      final page = await search(filters, cursor: null, limit: limit);
      // 迟到的旧查询：epoch 已过期 → 不回调状态。
      if (epoch != executedQueries) {
        return ChatSearchResultPage(
            items: page, nextCursor: null, epoch: epoch, stale: true);
      }
      final result = ChatSearchResultPage(
        items: dedupeByEventId(page),
        nextCursor: _cursorOf(page),
        epoch: epoch,
      );
      onStateChange?.call(ChatSearchStateChange.loaded(result));
      return result;
    } catch (_) {
      if (epoch == executedQueries) {
        onStateChange?.call(ChatSearchStateChange.failed(epoch));
      }
      rethrow;
    }
  }

  /// 追加下一页（稳定游标 + 事件 ID 去重 + 不隐含历史截断）。
  Future<ChatSearchResultPage> loadMore(
    ChatSearchResultPage current, {
    int limit = 50,
    void Function(ChatSearchStateChange change)? onStateChange,
  }) async {
    final cursor = current.nextCursor;
    if (cursor == null) return current;
    final epoch = current.epoch;
    final filters = ChatSearchFilters(
      keyword: hasKeywordInput ? _keyword.trim() : null,
      senderUserId: _senderUserId,
      mediaCategory: _mediaCategory,
    );
    final more = await search(filters, cursor: cursor, limit: limit);
    final merged = dedupeByEventId([...current.items, ...more]);
    return ChatSearchResultPage(
      items: merged,
      nextCursor: _cursorOf(more),
      epoch: epoch,
    );
  }

  ChatSearchCursor? _cursorOf(List<ChatSearchMessage> page) {
    if (page.isEmpty) return null;
    final last = page.last;
    return ChatSearchCursor(order: last.timelineOrder, eventId: last.eventId);
  }

  /// 事件 ID 去重（稳定）。
  static List<ChatSearchMessage> dedupeByEventId(
      Iterable<ChatSearchMessage> items) {
    final seen = <String>{};
    return [
      for (final item in items)
        if (seen.add(item.eventId)) item,
    ];
  }
}

/// 消息模型（检索层）：解密后可访问、未撤回。
final class ChatSearchMessage {
  const ChatSearchMessage({
    required this.eventId,
    required this.senderId,
    required this.senderDisplayName,
    required this.timestamp,
    required this.timelineOrder,
    required this.visibleText,
    this.mediaCategory,
    this.hasMedia = false,
  });

  final String eventId;
  final String senderId;
  final String senderDisplayName;
  final DateTime timestamp;

  /// 房间时间线序号（稳定游标与排序依据）。
  final int timelineOrder;

  /// 用户可见正文（文本/caption/链接文字/正文文件名）。
  final String visibleText;

  /// 消息自身媒体分类（image/video/file/link）。
  final ChatSearchMediaCategory? mediaCategory;
  final bool hasMedia;
}

enum ChatSearchMediaCategory { imageVideo, file, link }

enum ChatSearchFilterKind { keyword, sender, media }

final class ChatSearchActiveFilter {
  const ChatSearchActiveFilter(this.kind, this.value);
  final ChatSearchFilterKind kind;
  final String value;
}

final class ChatSearchFilters {
  const ChatSearchFilters({
    this.keyword,
    this.senderUserId,
    this.mediaCategory,
  });

  final String? keyword;
  final String? senderUserId;
  final ChatSearchMediaCategory? mediaCategory;

  /// 关键词匹配（连续子串、英文忽略大小写、中文按字）。
  bool matchesKeyword(ChatSearchMessage message) {
    final needle = keyword?.trim().toLowerCase();
    if (needle == null || needle.isEmpty) return true;
    return message.visibleText.toLowerCase().contains(needle);
  }

  bool matchesSender(ChatSearchMessage message) =>
      senderUserId == null || message.senderId == senderUserId;

  bool matchesMedia(ChatSearchMessage message) => switch (mediaCategory) {
        null => true,
        ChatSearchMediaCategory.imageVideo => message.mediaCategory ==
            ChatSearchMediaCategory.imageVideo && message.hasMedia,
        ChatSearchMediaCategory.file =>
          message.mediaCategory == ChatSearchMediaCategory.file,
        ChatSearchMediaCategory.link =>
          message.mediaCategory == ChatSearchMediaCategory.link,
      };

  bool matches(ChatSearchMessage message) =>
      matchesKeyword(message) && matchesSender(message) && matchesMedia(message);
}

/// 稳定游标（timelineOrder + eventId 组合键）。
final class ChatSearchCursor {
  const ChatSearchCursor({required this.order, required this.eventId});
  final int order;
  final String eventId;
}

final class ChatSearchResultPage {
  const ChatSearchResultPage({
    required this.items,
    required this.nextCursor,
    required this.epoch,
    this.stale = false,
  });
  final List<ChatSearchMessage> items;
  final ChatSearchCursor? nextCursor;
  final int epoch;

  /// 迟到的旧查询结果（调用方应丢弃，不覆盖新结果）。
  final bool stale;
}

/// UI 状态变化（加载中/已加载/失败/默认空态）。
sealed class ChatSearchStateChange {
  const ChatSearchStateChange();
  const factory ChatSearchStateChange.empty() = ChatSearchEmptyState;
  const factory ChatSearchStateChange.loading(int epoch) = ChatSearchLoadingState;
  const factory ChatSearchStateChange.loaded(ChatSearchResultPage page) =
      ChatSearchLoadedState;
  const factory ChatSearchStateChange.failed(int epoch) = ChatSearchFailedState;
}

final class ChatSearchEmptyState extends ChatSearchStateChange {
  const ChatSearchEmptyState();
}

final class ChatSearchLoadingState extends ChatSearchStateChange {
  const ChatSearchLoadingState(this.epoch);
  final int epoch;
}

final class ChatSearchLoadedState extends ChatSearchStateChange {
  const ChatSearchLoadedState(this.page);
  final ChatSearchResultPage page;
}

final class ChatSearchFailedState extends ChatSearchStateChange {
  const ChatSearchFailedState(this.epoch);
  final int epoch;
}

abstract class ChatSearchClock {
  DateTime now();
}

final class RealChatSearchClock implements ChatSearchClock {
  @override
  DateTime now() => DateTime.now();
}

/// 安全高亮：基于纯文本片段构建（不执行消息中的 HTML）。
/// 返回命中片段前后各 [context] 字符的摘要与命中区间。
List<ChatSearchHighlightSegment> buildHighlightSnippet(
  String text,
  String keyword, {
  int context = 24,
}) {
  final needle = keyword.trim().toLowerCase();
  if (needle.isEmpty) {
    return [ChatSearchHighlightSegment(text, false)];
  }
  final haystack = text.toLowerCase();
  final index = haystack.indexOf(needle);
  if (index < 0) {
    final head = text.length > context * 2
        ? '${text.substring(0, context * 2)}…'
        : text;
    return [ChatSearchHighlightSegment(head, false)];
  }
  final start = index > context ? index - context : 0;
  var end = index + needle.length + context;
  if (end > text.length) end = text.length;
  final segments = <ChatSearchHighlightSegment>[
    if (start > 0)
      ChatSearchHighlightSegment('…${text.substring(start, index)}', false)
    else if (index > 0)
      ChatSearchHighlightSegment(text.substring(0, index), false),
    ChatSearchHighlightSegment(
        text.substring(index, index + needle.length), true),
    if (end < text.length)
      ChatSearchHighlightSegment('${text.substring(index + needle.length, end)}…', false)
    else
      ChatSearchHighlightSegment(text.substring(index + needle.length), false),
  ];
  return segments;
}

final class ChatSearchHighlightSegment {
  const ChatSearchHighlightSegment(this.text, this.highlighted);
  final String text;
  final bool highlighted;
}

/// 时间展示：当天 HH:mm；其他日期 yyyy-MM-dd HH:mm。
String formatSearchResultTime(DateTime time, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final isSameDay = time.year == reference.year &&
      time.month == reference.month &&
      time.day == reference.day;
  String two(int v) => v.toString().padLeft(2, '0');
  if (isSameDay) {
    return '${two(time.hour)}:${two(time.minute)}';
  }
  return '${time.year.toString().padLeft(4, '0')}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

/// 图片消息缩略图占位（避免测试环境解码）。
final class ChatSearchThumbPlaceholder {
  static final Uint8List empty = Uint8List(0);
}
