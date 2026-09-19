import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 会话身份层架构守卫（重复会话缺陷 0919 · 用户要求第十三节）：
///
/// 1. 生产代码里任何 `.rooms` 枚举都必须登记在允许清单中（附用途理由）——
///   新增未登记的枚举点会让本测试失败，强制走一次评审；
/// 2. 用户可见的会话展示出口（消息列表 snapshot / 转发·分享·群发目标）必须
///   经过 `ConversationIdentityResolver` 的身份解析。
///
/// 允许清单分两类：
/// - 「消费去重后的 snapshot.rooms」：数据已经过解析器，属合规展示；
/// - 「内部控制」：未读计数、偏好 reconcile、邀请自动加入、通知聚合等
///   非用户可见的房间枚举。

String _stripComments(String code) {
  final withoutBlock = code.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final buffer = StringBuffer();
  for (final line in withoutBlock.split('\n')) {
    final commentIndex = line.indexOf('//');
    buffer.writeln(commentIndex >= 0 ? line.substring(0, commentIndex) : line);
  }
  return buffer.toString();
}

void main() {
  test('lib/ 中所有 .rooms 枚举都必须登记在允许清单中', () {
    const allowlist = <String, String>{
      // —— 用户可见展示出口：数据源出口已接线身份解析 ——
      'matrix_e2ee_client.dart':
          '唯一 client.rooms 枚举点：内部控制（未读/偏好/邀请/成员刷新/头像/收敛）+ 两处已接线出口（snapshot/forwardingDestinations）',
      'matrix_home_page.dart': '消费去重后的 snapshot.rooms（消息列表）',
      'global_search_page.dart': '消费去重后的 snapshot.rooms（搜索·群聊分节）',
      'global_search_controller.dart': '消费搜索结果模型 rooms（源自去重快照）',
      'global_search_models.dart': '搜索结果模型字段，非 client 枚举',
      'group_address_list_page.dart': '消费去重后的 snapshot.rooms（通讯录群聊页）',
      // —— 纯内部控制（非展示） ——
      'conversation_preferences.dart': '偏好 reconcile/ack 清理',
      'direct_invitation_auto_join.dart': '好友私聊邀请自动加入',
      'group_announcement_service.dart': '群公告 sync 事件解析',
      'matrix_direct_chat_adapter.dart': '开私聊时受邀房间扫描（自动 join）',
      'matrix_notification_event_source.dart': '本地通知聚合与角标未读快照',
    };

    final offenders = <String>[];
    final lib = Directory('lib');
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      final code = _stripComments(entity.readAsStringSync());
      if (!code.contains(RegExp(r'\.rooms\b'))) continue;
      final fileName = path.split('/').last;
      if (!allowlist.containsKey(fileName)) offenders.add(path);
    }
    expect(offenders, isEmpty,
        reason: '新的 .rooms 枚举必须先评审：用户可见的会话入口必须经 '
            'ConversationIdentityResolver 去重，内部用途请补入允许清单并写明理由：'
            '$offenders');
    // 允许清单不得包含已经不存在的文件（防止清单腐化）。
    for (final fileName in allowlist.keys) {
      expect(
        File('lib/features/matrix/$fileName').existsSync() ||
            File('lib/features/search/$fileName').existsSync() ||
            File('lib/features/contacts/$fileName').existsSync(),
        isTrue,
        reason: '允许清单中的 $fileName 已不存在，请移除该条目',
      );
    }
  });

  test('用户可见会话展示出口必须经过 ConversationIdentityResolver', () {
    final e2ee = _stripComments(
        File('lib/features/matrix/matrix_e2ee_client.dart').readAsStringSync());
    expect(e2ee, contains('resolveConversationIdentities('),
        reason: '消息列表数据源出口（snapshot）必须接入身份解析');
    expect(e2ee, contains('resolveIdentityRepresentatives<MatrixForwardDestinationSnapshot>('),
        reason: '转发/分享/群发目标（forwardingDestinations）必须接入身份解析');
    // 身份解析规则本体必须存在且暴露 primary 规则注入点。
    final resolver = _stripComments(File(
            'lib/features/matrix/conversation_identity_resolver.dart')
        .readAsStringSync());
    expect(resolver, contains('primaryRoomIdOf'));
    expect(resolver, contains('localMessageCountOf'));
  });
}
