// 规格 #7/#8/#9 的共享纯逻辑：月历日期模型、链接/文件分类规则、
// GIF 真实格式识别与播放门控。

// ──────────────────────────────────────────────────────────────
// #7 月历日期定位
// ──────────────────────────────────────────────────────────────

/// 月历中一天的呈现状态（确认无消息=禁用；扫描中=独立加载态，
/// 不得冒充无消息）。
enum CalendarDayStatus { hasMessages, noMessages, scanning, outOfRange }

final class CalendarMonth {
  const CalendarMonth(this.year, this.month);

  final int year;
  final int month;

  @override
  bool operator ==(Object other) =>
      other is CalendarMonth && other.year == year && other.month == month;

  @override
  int get hashCode => Object.hash(year, month);

  @override
  String toString() => '$year-${month.toString().padLeft(2, '0')}';

  CalendarMonth get previous => month == 1
      ? CalendarMonth(year - 1, 12)
      : CalendarMonth(year, month - 1);

  CalendarMonth get next =>
      month == 12 ? CalendarMonth(year + 1, 1) : CalendarMonth(year, month + 1);

  /// 月标题（yyyy年M月）。
  String get title => '$year年$month月';

  /// 该月总天数。
  int get daysInMonth {
    final firstOfNext = month == 12
        ? DateTime(year + 1, 1, 1)
        : DateTime(year, month + 1, 1);
    return firstOfNext.subtract(const Duration(days: 1)).day;
  }

  /// 该月 1 号是周几（1=周一 … 7=周日；月历按周一开头）。
  int get firstWeekdayMondayBased {
    final raw = DateTime(year, month, 1).weekday; // DateTime: 1=Mon..7=Sun.
    return raw;
  }

  bool contains(DateTime date) => date.year == year && date.month == month;

  /// 月份导航范围限制：最早与最新可访问消息月份之间。
  bool canNavigateTo(CalendarMonth target,
          {required CalendarMonth earliest, required CalendarMonth latest}) =>
      !(target.year < earliest.year ||
          (target.year == earliest.year && target.month < earliest.month) ||
          target.year > latest.year ||
          (target.year == latest.year && target.month > latest.month));
}

/// 设备当前时区下的日期映射（与气泡日期一致：local 时区）。
DateTime calendarDayOf(DateTime time) =>
    DateTime(time.year, time.month, time.day);

/// 月份内各天状态：
/// - [datesWithMessages] 确认有消息（完整历史扫描后）；
/// - [scanningDates] 尚未完成扫描（显示"加载中"独立状态）；
/// - 其余确认无消息 → 禁用灰显（#CCCCCC）。
CalendarDayStatus dayStatus(DateTime date,
    {required Set<DateTime> datesWithMessages, required Set<DateTime> scanningDates}) {
  final day = calendarDayOf(date);
  if (scanningDates.contains(day)) return CalendarDayStatus.scanning;
  if (datesWithMessages.contains(day)) return CalendarDayStatus.hasMessages;
  return CalendarDayStatus.noMessages;
}

/// 点击日期：定位**该日最早一条**可展示消息（非最后一条）。
/// 输入为当日消息列表（timelineOrder 升序=旧→新），返回最早。
T? earliestMessageOfDay<T extends Object>(
  List<T> dayMessages,
  int Function(T) timelineOrderOf,
) {
  if (dayMessages.isEmpty) return null;
  return [...dayMessages]
      .reduce((a, b) => timelineOrderOf(a) <= timelineOrderOf(b) ? a : b);
}

// ──────────────────────────────────────────────────────────────
// #8 链接解析 / 文件展示回退
// ──────────────────────────────────────────────────────────────

/// 从正文解析 HTTP/HTTPS URL。
final _urlPattern = RegExp('https?://[^\\s<>"]+', caseSensitive: false);

List<Uri> extractHttpLinks(String body) => [
      for (final match in _urlPattern.allMatches(body))
        if (Uri.tryParse(match.group(0)!) != null) Uri.parse(match.group(0)!),
    ];

/// 同一消息内相同 URL 去重；不同消息分别保留来源（调用方按消息分组）。
List<Uri> dedupeUrlsInMessage(List<Uri> urls) {
  final seen = <String>{};
  return [
    for (final url in urls)
      if (seen.add(url.toString())) url,
  ];
}

final class LinkPreviewModel {
  const LinkPreviewModel({
    required this.url,
    this.title,
    this.summary,
    this.thumbnailUrl,
  });

  final Uri url;
  final String? title;
  final String? summary;
  final String? thumbnailUrl;

  /// 消息自带预览元数据优先；缺失时：域名作标题、URL 作摘要、
  /// 默认链接图标（thumbnailUrl=null）。
  String get displayTitle =>
      title?.trim().isNotEmpty == true ? title!.trim() : url.host;

  String get displaySummary =>
      summary?.trim().isNotEmpty == true ? summary!.trim() : url.toString();
}

/// 文件展示回退：未知不得伪造。
final class FileDisplayFallback {
  static const unnamedFile = '未命名文件';
  static const unknownSize = '大小未知';

  static String fileName(String? name) {
    final trimmed = name?.trim();
    return (trimmed == null || trimmed.isEmpty) ? unnamedFile : trimmed;
  }

  static String sizeLabel(int? bytes) {
    if (bytes == null || bytes < 0) return unknownSize;
    const kb = 1024;
    const mb = kb * 1024;
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
    return '$bytes B';
  }
}

// ──────────────────────────────────────────────────────────────
// #9 GIF 真实格式识别与播放门控
// ──────────────────────────────────────────────────────────────

/// 真实图片格式（解码器识别，扩展名仅提示；冲突以实际内容为准）。
enum DecodedImageFormat { gifAnimated, gifSingleFrame, png, jpeg, webp, unknown }

/// 基于解码帧数判定：
/// - GIF 且 frameCount > 1 → 动画；
/// - GIF 单帧 → 静态图正常显示；
/// - 扩展名 .jpg 但真实 GIF → 以 GIF 为准。
DecodedImageFormat classifyImageFormat({
  required bool signatureIsGif,
  required int frameCount,
  DecodedImageFormat? codecFormat,
}) {
  if (signatureIsGif) {
    return frameCount > 1
        ? DecodedImageFormat.gifAnimated
        : DecodedImageFormat.gifSingleFrame;
  }
  return codecFormat ?? DecodedImageFormat.unknown;
}

/// GIF 播放门控：
/// - 自动播放开关关闭 → 手动（显示播放按钮）；
/// - 媒体下载偏好未获准 → "点击加载 GIF"（不自动下载）；
/// - 离屏 / 应用后台 / 画廊非当前页 → 暂停（不持续解码）；
/// - 遵循自带帧延迟与循环：有限循环不强制无限（isLooping=false 时
///   播完停在最后一帧）。
bool shouldPlayGif({
  required bool autoPlayEnabled,
  required bool mediaDownloadAllowed,
  required bool isVisiblyOnScreen,
  required bool appInForeground,
  required bool isCurrentGalleryPage,
}) {
  if (!autoPlayEnabled) return false; // 手动模式。
  if (!mediaDownloadAllowed) return false; // 点击加载。
  return isVisiblyOnScreen && appInForeground && isCurrentGalleryPage;
}

/// GIF 帧序列元数据（解码器提供；遵循自带延迟/循环）。
final class GifPlaybackPlan {
  const GifPlaybackPlan({
    required this.frameDelays,
    required this.repetitionMode,
    this.finiteLoops,
  });

  /// 各帧延迟（ms，来自文件自带值，不重排）。
  final List<int> frameDelays;

  /// 自带循环模式：[GifRepetitionMode.infinite] 或
  /// [GifRepetitionMode.finite]（有限次数，播完即停，不强制无限）。
  final GifRepetitionMode repetitionMode;

  /// finite 模式的循环次数（infinite 时忽略）。
  final int? finiteLoops;

  int get frameCount => frameDelays.length;

  /// 总循环次数：infinite → null（持续）；finite → [finiteLoops]。
  int? get loops =>
      repetitionMode == GifRepetitionMode.infinite ? null : finiteLoops;
}

enum GifRepetitionMode { infinite, finite }
