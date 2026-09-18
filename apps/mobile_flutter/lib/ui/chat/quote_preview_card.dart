import 'package:flutter/cupertino.dart';

import '../../features/matrix/reply_message_resolution.dart';
import '../../features/matrix/room_timeline_controller.dart';
import '../foundation/wechat_tokens.dart';

/// 引用卡片摘要截断：超过 10 个字符（按字素簇计）加省略号。
String truncateQuoteText(String value) {
  final characters = value.characters;
  return characters.length > 10
      ? '${characters.take(10).toString()}...'
      : value;
}

/// 已解析原消息的引用摘要（选中片段优先）。
///
/// [excerpt] 是发送方随消息携带的「选中片段」引用（`io.changliao.selected_quote`），
/// 它在原消息不可用时仍可展示；[message] 为按 event_id 解析出的原消息。
String? quoteSummaryFor(RoomMessageViewModel? message, String? excerpt) {
  if (excerpt != null && excerpt.isNotEmpty) return truncateQuoteText(excerpt);
  if (message == null) return null;
  return switch (message.kind) {
    RoomMessageKind.image => '图片',
    RoomMessageKind.video => '视频',
    RoomMessageKind.voice => '语音 ${message.voiceDuration.inSeconds}″',
    RoomMessageKind.file => truncateQuoteText('文件：${message.text}'),
    _ => truncateQuoteText(message.text),
  };
}

/// 引用消息卡片（气泡上方的小卡片）。
///
/// 关键不变量：**永不永久显示「原消息加载中」**。加载、成功、不存在、
/// 无权限、网络失败五种状态各有明确文案；可重试的失败态提供点击重试，
/// 由 [onRetry] 触达（成功态与加载态点击跳转到原消息）。
final class QuotePreviewCard extends StatelessWidget {
  const QuotePreviewCard({
    super.key,
    required this.targetEventId,
    required this.resolution,
    required this.displayName,
    required this.onTap,
    this.message,
    this.excerpt,
    this.onRetry,
  });

  /// 被引用的原消息 event_id。
  final String targetEventId;

  /// 加载状态机结果。
  final ReplyMessageResolution resolution;

  /// 已在本机 timeline 命中的原消息（优先于 [resolution]）。
  final RoomMessageViewModel? message;

  /// 发送方随消息携带的选中片段（局部引用）。
  final String? excerpt;

  /// 展示名（引用已解析时是发送者显示名）。
  final String displayName;

  final VoidCallback onTap;

  /// 失败态重试；为 null 时失败态不可点。
  final VoidCallback? onRetry;

  RoomMessageViewModel? get _resolved => message ?? resolution.message;

  bool get _canRetry => onRetry != null && resolution.canRetry;

  @override
  Widget build(BuildContext context) {
    final resolved = _resolved;
    final summary = quoteSummaryFor(resolved, excerpt);
    final failed = summary == null && resolution.isSettled;
    final loading = summary == null && !resolution.isSettled;
    final label = summary != null
        ? '$displayName：$summary'
        : loading
            ? replyMessageLoadingLabel
            : resolution.label;
    final retryable = failed && _canRetry;
    return CupertinoButton(
      key: Key('reply-preview-$targetEventId'),
      padding: const EdgeInsets.only(top: 4),
      minimumSize: Size.zero,
      onPressed: retryable ? onRetry : onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 236),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: WeChatColors.resolve(context, WeChatColors.divider),
          borderRadius: BorderRadius.circular(WeChatRadius.control),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (summary == null)
            Padding(
              padding: const EdgeInsets.only(right: 5),
              child: _statusIcon(context, loading: loading, retryable: retryable),
            )
          else if (resolved?.kind == RoomMessageKind.image)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(CupertinoIcons.photo,
                  size: 15, color: WeChatColors.textSecondary),
            )
          else if (resolved?.kind == RoomMessageKind.voice)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(CupertinoIcons.speaker_2,
                  size: 15, color: WeChatColors.textSecondary),
            ),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: WeChatColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _statusIcon(BuildContext context,
      {required bool loading, required bool retryable}) {
    if (loading) {
      return const CupertinoActivityIndicator(radius: 6);
    }
    return Icon(
      retryable ? CupertinoIcons.arrow_clockwise : CupertinoIcons.exclamationmark_circle,
      size: 14,
      color: retryable ? WeChatColors.brandPrimary : WeChatColors.textSecondary,
    );
  }
}
