import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/member_directory_service.dart';

/// 规格 #6：统一成员排序服务（拼音分组/过滤/稳定排序）。
void main() {
  const entries = <MemberDirectoryEntry>[
    MemberDirectoryEntry(userId: '@zhang:example.test', nickname: '张三'),
    MemberDirectoryEntry(userId: '@bob:example.test', nickname: 'Bob'),
    MemberDirectoryEntry(userId: '@chen:example.test', nickname: '陈晨'),
    MemberDirectoryEntry(userId: '@aming:example.test', nickname: '阿明'),
    MemberDirectoryEntry(userId: '@num:example.test', nickname: '123'),
  ];

  test('分组：阿明、Bob、陈晨、张三、123 分别归入 A、B、C、Z、#', () {
    final sorted = sortMemberEntries(entries);
    final sections = [
      for (final e in sorted) '${memberSectionLetter(e)}:${e.displayName}',
    ];
    expect(sections, [
      'A:阿明',
      'B:Bob',
      'C:陈晨',
      'Z:张三',
      '#:123',
    ], reason: '拼音首字母分组，数字归 #');
  });

  test('排序键：全拼次序 + 用户 ID 稳定（同名不混）', () {
    final same = sortMemberEntries(const [
      MemberDirectoryEntry(userId: '@b:example.test', nickname: '张三'),
      MemberDirectoryEntry(userId: '@a:example.test', nickname: '李四'),
      MemberDirectoryEntry(userId: '@c:example.test', nickname: '张三'),
    ]);
    expect(
      same.map((e) => e.userId).toList(),
      ['@a:example.test', '@b:example.test', '@c:example.test'],
      reason: '李四(L)先于张三(Z)；两个张三按 userId 稳定排序',
    );
  });

  test('备注优先：修改备注后排序名变化', () {
    final withRemark = sortMemberEntries(const [
      MemberDirectoryEntry(userId: '@z:example.test', nickname: '阿明'),
      MemberDirectoryEntry(
          userId: '@w:example.test',
          nickname: 'Omega',
          remark: '阿发'),
    ]);
    expect(
      withRemark.map((e) => e.userId).toList(),
      ['@w:example.test', '@z:example.test'],
      reason: '备注"阿发"(A)与昵称"阿明"(A)同组，按全拼 afa < aming：阿发在前',
    );
  });

  test('过滤：张、zhang、zs 均命中"张三"；昵称含关键词但正文逻辑不适用（成员名匹配即命中）', () {
    expect(filterMemberEntries(entries, '张').map((e) => e.displayName), ['张三']);
    expect(
        filterMemberEntries(entries, 'zhang').map((e) => e.displayName), ['张三']);
    expect(filterMemberEntries(entries, 'zs').map((e) => e.displayName), ['张三']);
    expect(filterMemberEntries(entries, 'ZS').map((e) => e.displayName), ['张三'],
        reason: '英文忽略大小写');
  });

  test('过滤：备注入查询；无匹配返回空', () {
    const withRemark = <MemberDirectoryEntry>[
      MemberDirectoryEntry(
          userId: '@x:example.test', nickname: '展示名', remark: '小旋风'),
    ];
    expect(filterMemberEntries(withRemark, '旋风'), isNotEmpty);
    expect(filterMemberEntries(entries, '不存在的人'), isEmpty);
  });

  test('组合入口：排序+过滤共用同一规则', () {
    final result = sortAndFilterMemberEntries(entries, 'z');
    expect(result.map((e) => e.displayName), ['张三'],
        reason: 'z 命中张三全拼（Bob 为 b 开头昵称不含 z）');
  });

  test('分桶：# 桶在末尾', () {
    final grouped = groupMemberEntriesBySection(sortMemberEntries(entries));
    expect(grouped.keys.toList(), ['A', 'B', 'C', 'Z', '#']);
  });

  test('英文子串忽略大小写匹配昵称/用户名', () {
    const list = <MemberDirectoryEntry>[
      MemberDirectoryEntry(userId: '@u1:example.test', username: 'Alice'),
    ];
    expect(filterMemberEntries(list, 'ali'), isNotEmpty);
    expect(filterMemberEntries(list, 'ALICE'), isNotEmpty);
  });
}
