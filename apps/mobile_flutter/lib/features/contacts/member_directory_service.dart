import 'package:characters/characters.dart';
import 'package:lpinyin/lpinyin.dart';

/// 统一成员名称解析/排序/过滤服务（规格 #6）。
///
/// 供群成员页、@选择器、邀请/转发选人等**所有成员列表**共用：
/// - 排序名称优先级：备注 → 昵称 → 用户名；
/// - 中文用固定版本拼音字典（lpinyin）生成**全拼排序键**：先按首字母
///   A-Z 分组，组内按完整排序键、再按用户 ID 稳定排序（同名不混）；
/// - 无法转写、数字及符号开头归入末尾 `#`；
/// - 实时过滤同时匹配备注/昵称/用户名：中文子串、英文忽略大小写、
///   拼音全拼及首字母（zhang/zs 均命中"张三"）；不支持模糊错字。
final class MemberDirectoryEntry {
  const MemberDirectoryEntry({
    required this.userId,
    this.remark,
    this.nickname,
    this.username,
    this.hasLeftGroup = false,
  });

  /// 不可变用户 ID（查询/点击以此为准，避免改名重名混淆）。
  final String userId;
  final String? remark;
  final String? nickname;

  /// 用户名（业务账号名，兜底展示）。
  final String? username;

  /// 已退群但存在可访问历史消息（检索仍可用，标记"已离群"）。
  final bool hasLeftGroup;

  /// 展示名：备注 > 昵称 > 用户名 > userId 本地部分。
  String get displayName {
    final r = remark?.trim();
    if (r != null && r.isNotEmpty) return r;
    final n = nickname?.trim();
    if (n != null && n.isNotEmpty) return n;
    final u = username?.trim();
    if (u != null && u.isNotEmpty) return u;
    return localPart(userId);
  }

  /// 检索用名称集合（备注、昵称、用户名）。
  List<String> get searchableNames {
    final names = <String>[
      if ((remark?.trim() ?? '').isNotEmpty) remark!.trim(),
      if ((nickname?.trim() ?? '').isNotEmpty) nickname!.trim(),
      if ((username?.trim() ?? '').isNotEmpty) username!.trim(),
    ];
    return names;
  }
}

String localPart(String userId) =>
    userId.startsWith('@') ? userId.substring(1).split(':').first : userId;

/// 拼音全拼（小写、无分隔），无法转写的非中文字符保留原字符小写。
String pinyinFullKey(String name) =>
    PinyinHelper.getPinyinE(name, separator: '', defPinyin: name.toLowerCase())
        .toLowerCase();

/// 拼音首字母键（如 zs）。
String pinyinInitialsKey(String name) =>
    PinyinHelper.getShortPinyin(name).toLowerCase();

/// A-Z 分组字母：可转写拼音或 A-Z 开头 → 对应字母；数字/符号/其他 → '#'。
String memberSectionLetter(MemberDirectoryEntry entry) {
  final name = entry.displayName.trim();
  if (name.isEmpty) return '#';
  final first = name.characters.first.toUpperCase();
  final code = first.codeUnitAt(0);
  if (code >= 0x41 && code <= 0x5A) return first; // A-Z。
  if (RegExp(r'[\u4e00-\u9fff]').hasMatch(first)) {
    final initial = pinyinInitialsKey(name);
    if (initial.isNotEmpty) {
      final upper = initial[0].toUpperCase();
      final initialCode = upper.codeUnitAt(0);
      if (initialCode >= 0x41 && initialCode <= 0x5A) return upper;
    }
  }
  return '#';
}

/// 统一排序：分组字母 → 完整排序键（拼音全拼）→ 用户 ID 稳定排序。
/// "所有人"等功能项不进入本排序（调用方固定在列表之外）。
List<MemberDirectoryEntry> sortMemberEntries(
    List<MemberDirectoryEntry> entries) {
  final decorated = <({MemberDirectoryEntry entry, String section, String fullKey})>[
    for (final entry in entries)
      (
        entry: entry,
        section: memberSectionLetter(entry),
        fullKey: _sortKeyOf(entry),
      ),
  ];
  decorated.sort((a, b) {
    final section = _sectionOrder(a.section) - _sectionOrder(b.section);
    if (section != 0) return section;
    final full = a.fullKey.compareTo(b.fullKey);
    if (full != 0) return full;
    return a.entry.userId.compareTo(b.entry.userId); // 稳定：同名不混。
  });
  return [for (final item in decorated) item.entry];
}

/// 按分组字母分桶（保持排序；# 在末尾）。
Map<String, List<MemberDirectoryEntry>> groupMemberEntriesBySection(
    List<MemberDirectoryEntry> sortedEntries) {
  final grouped = <String, List<MemberDirectoryEntry>>{};
  for (final entry in sortedEntries) {
    grouped.putIfAbsent(memberSectionLetter(entry), () => []).add(entry);
  }
  return grouped;
}

/// # 桶排在 Z（0x5A）之后。
int _sectionOrder(String section) =>
    section == '#' ? 0x5B : section.codeUnitAt(0);

/// 排序键：展示名的拼音全拼；无法转写时退化为小写原名。
String _sortKeyOf(MemberDirectoryEntry entry) =>
    pinyinFullKey(entry.displayName);

/// 统一过滤：中文子串、英文忽略大小写、拼音全拼与首字母。
/// 不做模糊错字；查询空白返回原列表。
List<MemberDirectoryEntry> filterMemberEntries(
  List<MemberDirectoryEntry> entries,
  String query,
) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return entries;
  return entries.where((entry) {
    for (final name in entry.searchableNames) {
      if (name.toLowerCase().contains(needle)) return true; // 中文子串/英文。
      if (pinyinFullKey(name).contains(needle)) return true; // 全拼 zhang。
      if (pinyinInitialsKey(name).contains(needle)) return true; // 首字母 zs。
    }
    return false;
  }).toList(growable: false);
}

/// 排序 + 过滤的组合入口（成员页/选择器共用同一规则）。
List<MemberDirectoryEntry> sortAndFilterMemberEntries(
        List<MemberDirectoryEntry> entries, String query) =>
    sortMemberEntries(filterMemberEntries(entries, query));
