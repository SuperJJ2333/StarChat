import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/contacts/user_display_name_resolver.dart';

ContactSummary _contact({
  String? remark,
  String? nickname,
  String username = 'user_a',
}) =>
    ContactSummary(
      userId: 'u1',
      username: username,
      matrixUserId: '@a:matrix.localhost',
      nickname: nickname,
      remark: remark,
    );

void main() {
  test('优先级：备注 > 昵称 > Matrix displayName > username > Matrix ID', () {
    final withRemark = ContactBackedUserDisplayNameResolver(
      contactFor: (id) => _contact(remark: '张三', nickname: '阿三'),
    );
    expect(withRemark.resolveSync('@a:matrix.localhost'), '张三');

    final noRemark = ContactBackedUserDisplayNameResolver(
      contactFor: (id) => _contact(nickname: '阿三'),
    );
    expect(noRemark.resolveSync('@a:matrix.localhost'), '阿三');

    final stranger = ContactBackedUserDisplayNameResolver(
      contactFor: (id) => null,
    );
    expect(
      stranger.resolveSync('@a:matrix.localhost', matrixDisplayName: '矩阵昵称'),
      '矩阵昵称',
    );

    final usernameOnly = ContactBackedUserDisplayNameResolver(
      contactFor: (id) => _contact(username: 'zhangsan'),
    );
    expect(usernameOnly.resolveSync('@a:matrix.localhost'), 'zhangsan');

    final lastResort = ContactBackedUserDisplayNameResolver(
      contactFor: (id) => null,
    );
    expect(lastResort.resolveSync('@a:matrix.localhost'), 'a',
        reason: '无资料时仅显示用户名');
  });

  test('空备注/空昵称跳过；预热失败回退同步结果', () async {
    final resolver = ContactBackedUserDisplayNameResolver(
      contactFor: (id) => _contact(remark: '', nickname: '', username: 'u1'),
      warmContacts: () async => throw StateError('cache cold'),
    );
    expect(resolver.resolveSync('@a:matrix.localhost'), 'u1');
    expect(await resolver.resolve('@a:matrix.localhost',
        matrixDisplayName: ''), 'u1');
  });
}
