/// 统一提及模型（规格 #3：修复重复 @）。
///
/// 输入框、发送正文、富文本渲染共用同一份模型：
/// - 一个提及 token = 前导 `@` + 展示名，附带 userId 与**文本范围**；
/// - 选中成员时**替换触发 @ 的文本范围**为一个 token（不再在原 @ 后
///   追加完整 @姓名——旧 `MentionDraft.append` 的追加式实现产生
///   `@兄弟 @兄弟` 双 @）；
/// - 仅对**本次正在生成的 token** 规范化名称开头的装饰性 @；绝不对
///   整段正文全局替换 `@@`（保护用户原文、邮箱与 URL）；
/// - 编辑/删除 token 范围时同步更新元数据（文字已删则不再提醒）。
final class MentionComposerModel {
  MentionComposerModel({this.text = ''});

  String text;

  /// 活动提及（按 token 文本范围登记；范围失效即剔除）。
  final List<MentionToken> tokens = <MentionToken>[];

  /// 触发 @ 的位置（面板打开时记录）；选中成员后由 [replaceTrigger]
  /// 消费。null = 当前没有待完成的 @ 触发。
  int? pendingTriggerStart;

  /// 输入变化后校验：触发位置仍指向 `@` 才保留；否则清除。
  /// 返回是否应显示成员选择面板（群聊场景由调用方再判断 isGroup）。
  bool syncTrigger(String nextText) {
    text = nextText;
    final start = pendingTriggerStart;
    if (start == null ||
        start < 0 ||
        start >= text.length ||
        text.codeUnitAt(start) != 0x40 /* @ */) {
      pendingTriggerStart = null;
      return false;
    }
    return true;
  }

  /// 记录一次新的 @ 触发（输入或组合输入提交了 `@`）。
  /// 重复触发字符（如用户连按两次 @）只保留最近一次。
  void triggerAt(int index) {
    if (index < 0 || index >= text.length) return;
    if (text.codeUnitAt(index) != 0x40) return;
    pendingTriggerStart = index;
  }

  /// 选中成员：把触发 @ 起、到光标的查询片段，整体替换为一个 token。
  ///
  /// - 触发字符与查询片段（如 `@兄`）都被 token 覆盖；
  /// - 展示名开头的装饰性 @ 仅在此 token 内规范化（`@兄弟`→`兄弟`）；
  /// - @所有人：token 固定 `所有人`，userIds 为提醒范围成员。
  /// 返回新的光标位置（token 之后）。
  int replaceTrigger({
    required String displayName,
    required String userId,
    int? cursor,
    List<String>? mentionAllUserIds,
  }) {
    final start = pendingTriggerStart ?? _lastAtBeforeCursor(cursor);
    final safeStart = start == null ? text.length : start.clamp(0, text.length);
    final end = (cursor ?? text.length).clamp(safeStart, text.length);
    // 展示名规范化：仅去掉名称开头的装饰性 @（不影响内部字符）。
    final cleanedName = _stripLeadingAt(displayName);
    final label = mentionAllUserIds != null ? '所有人' : cleanedName;
    final token = MentionToken(
      start: safeStart,
      end: safeStart + label.length + 1,
      display: label,
      userId: mentionAllUserIds != null ? '@all' : userId,
      mentionAllUserIds: mentionAllUserIds == null
          ? null
          : List<String>.unmodifiable(mentionAllUserIds),
    );
    // 替换 [safeStart, end) 为 `@label `；之后的既有 token 平移。
    final insertedLength = label.length + 2; // '@' + label + ' '
    _shiftTokensAfter(safeStart, end, insertedLength);
    final replaced =
        '${text.substring(0, safeStart)}@$label ${text.substring(end)}';
    final caret = safeStart + label.length + 2;
    text = replaced;
    pendingTriggerStart = null;
    tokens.add(token);
    return caret;
  }

  /// 文本编辑（删除/插入）后同步 token 元数据：
  /// 完整落在被删范围内的 token 移除（不再提醒）；范围右移/收缩修正。
  ///
  /// [pendingTriggerStart] 的处理：编辑没有删除触发字符时保留——
  /// 用户在 @ 后继续输入查询词（如 `@兄`），触发范围应存活直到
  /// 选中成员/光标离开/触发字符被删，而不是每次输入都丢失（R1）。
  void applyEdit({required int start, required int removed, required int inserted}) {
    final deleteEnd = start + removed;
    // 触发字符存活判定：触发位置未被删除覆盖。
    final trigger = pendingTriggerStart;
    if (trigger != null) {
      final triggerDeleted =
          trigger >= start && trigger < deleteEnd;
      if (triggerDeleted) {
        pendingTriggerStart = null;
      } else if (trigger >= deleteEnd) {
        pendingTriggerStart = trigger + inserted - removed; // 平移。
      }
      // trigger < start：编辑在触发之后，不影响。
    }
    final kept = <MentionToken>[];
    for (final token in tokens) {
      if (token.start >= start && token.end <= deleteEnd) {
        continue; // token 全部被删：丢弃（发送时不再提醒该用户）。
      }
      int newStart = token.start;
      int newEnd = token.end;
      if (deleteEnd <= token.start) {
        newStart += inserted - removed;
        newEnd += inserted - removed;
      } else if (start < token.start) {
        // 编辑落在 token 前半：保守视为破坏 token（文本与元数据不再
        // 对齐），同样丢弃——避免"文字已删仍通知对方"。
        continue;
      } else if (start < token.end) {
        // 编辑落在 token 内部：token 文本被改，不再是有效提及。
        continue;
      }
      kept.add(MentionToken(
        start: newStart,
        end: newEnd,
        display: token.display,
        userId: token.userId,
        mentionAllUserIds: token.mentionAllUserIds,
      ));
    }
    tokens
      ..clear()
      ..addAll(kept);
  }

  /// 发送时的收件人（按 userId，绝不凭昵称/正文推断）。
  /// token 范围与当前文本不一致时以文本为准重新校验（防御）。
  List<String> recipientUserIds() {
    final ids = <String>{};
    for (final token in tokens) {
      final inText = token.end <= text.length &&
          text.substring(token.start, token.end).startsWith('@');
      if (!inText) continue;
      if (token.mentionAllUserIds != null) {
        ids.addAll(token.mentionAllUserIds!);
      } else {
        ids.add(token.userId);
      }
    }
    return ids.toList(growable: false);
  }

  /// 历史富文本收件解析（规格#3：仅识别合法用户链接；`@@兄弟` 普通
  /// 文本不能推断收件人）。pill 链接形如
  /// `matrix.to/#/@user:server` 且带 body 以 @ 开头。
  static List<String> parseRecipientUserIdsFromHtml(String? formattedBody) {
    if (formattedBody == null) return const [];
    final ids = <String>{};
    final pattern = RegExp(
      r'href="https?://matrix\.to/#/(@[^"]+)"[^>]*>([^<]*)</a>',
    );
    for (final match in pattern.allMatches(formattedBody)) {
      final label = match.group(2) ?? '';
      if (!label.startsWith('@')) continue; // 非提及链接（普通 permalink）。
      final id = match.group(1)!;
      if (id.startsWith('@')) ids.add(id);
    }
    return ids.toList(growable: false);
  }

  /// 长按头像快速 @（无触发字符场景）：在文本末尾追加一个 token；
  /// 非空且不以空白结尾时先补一个空格分隔。
  /// 返回新的光标位置。
  int appendAtEnd({required String displayName, required String userId}) {
    final label = _stripLeadingAt(displayName);
    final separator = text.isEmpty || _endsWithWhitespace(text) ? '' : ' ';
    final base = text.length;
    final inserted = '$separator@$label ';
    text = '$text$inserted';
    tokens.add(MentionToken(
      start: base + separator.length,
      end: base + separator.length + label.length + 1,
      display: label,
      userId: userId,
    ));
    return text.length;
  }

  /// 计算一次文本编辑的差分（onChanged 同步 token 用）。
  /// 返回 (start, removedLength, insertedLength)。
  static (int, int, int) diffEdit(String oldText, String newText) {
    var start = 0;
    final minLen = oldText.length < newText.length ? oldText.length : newText.length;
    while (start < minLen && oldText.codeUnitAt(start) == newText.codeUnitAt(start)) {
      start++;
    }
    var oldEnd = oldText.length;
    var newEnd = newText.length;
    while (oldEnd > start && newEnd > start &&
        oldText.codeUnitAt(oldEnd - 1) == newText.codeUnitAt(newEnd - 1)) {
      oldEnd--;
      newEnd--;
    }
    return (start, oldEnd - start, newEnd - start);
  }

  int? _lastAtBeforeCursor(int? cursor) {
    final limit = cursor ?? text.length;
    for (var i = limit - 1; i >= 0; i--) {
      if (text.codeUnitAt(i) == 0x40) return i;
      // 只回溯到最近的空白（@ 后的查询片段不含空白）。
      final ch = text[i];
      if (ch == ' ' || ch == '\n' || ch == '\t') break;
    }
    return null;
  }

  /// 替换区域之后的既有 token 按长度差平移。
  void _shiftTokensAfter(int replaceStart, int replaceEnd, int insertedLength) {
    final delta = insertedLength - (replaceEnd - replaceStart);
    if (delta == 0) return;
    final shifted = <MentionToken>[];
    for (final token in tokens) {
      if (token.start >= replaceEnd) {
        shifted.add(MentionToken(
          start: token.start + delta,
          end: token.end + delta,
          display: token.display,
          userId: token.userId,
          mentionAllUserIds: token.mentionAllUserIds,
        ));
      } else {
        shifted.add(token);
      }
    }
    tokens
      ..clear()
      ..addAll(shifted);
  }
}

/// 一个已生成的提及 token（文本范围 + 目标）。
final class MentionToken {
  const MentionToken({
    required this.start,
    required this.end,
    required this.display,
    required this.userId,
    this.mentionAllUserIds,
  });

  final int start;
  final int end;
  final String display;

  /// 目标用户 ID（'@all' 表示 @所有人，真实目标见 [mentionAllUserIds]）。
  final String userId;
  final List<String>? mentionAllUserIds;

  String get tokenText => '@$display';
}

String _stripLeadingAt(String name) {
  var cleaned = name.trim();
  while (cleaned.startsWith('@')) {
    cleaned = cleaned.substring(1);
  }
  return cleaned.trim();
}

bool _endsWithWhitespace(String text) {
  if (text.isEmpty) return true;
  final ch = text[text.length - 1];
  return ch == ' ' || ch == '\n' || ch == '\t';
}
