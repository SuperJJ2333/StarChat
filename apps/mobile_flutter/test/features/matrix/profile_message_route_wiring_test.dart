import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 生产代码里的房间导航必须只有一套：RoomPage 只在 AppHome 的
/// RoomNavigationCoordinator 打开流程里构建，其余入口（好友资料、消息列表、
/// 通知、群聊通讯录、建群后）都经由协调器按 roomId 去重。
void main() {
  test('AppHome 是唯一的 RoomPage 构建者，且保留好友消息入口', () {
    final source = File('lib/app_home.dart').readAsStringSync();
    final entries = source.split('builder: (_) => RoomPage(').skip(1);
    expect(entries, hasLength(1),
        reason: 'AppHome 只允许一个 RoomPage 构建点（_openManagedRoomRoute）');
    for (final entry in entries) {
      final arguments =
          entry.substring(0, entry.indexOf('initialIdentityCache:'));
      expect(arguments, contains('onMessage:'), reason: '房间入口必须保持好友「发消息」可达');
      expect(arguments, contains('onVoice:'));
      expect(arguments, contains('onVideo:'));
    }
  });

  test('消息列表不再自建 RoomLease/RoomPage，改为委托统一入口', () {
    final source =
        File('lib/features/matrix/matrix_home_page.dart').readAsStringSync();
    expect(source, isNot(contains('builder: (_) => RoomPage(')),
        reason: '消息列表不得再构建 RoomPage');
    expect(source, isNot(contains('openRoomLease(')),
        reason: '消息列表不得再自取 RoomLease');
    expect(source, isNot(contains('setOnRevoked(')),
        reason: 'revoke 生命周期由统一入口负责');
    expect(source, contains('widget.onOpenRoom'), reason: '房间打开委托给 AppHome');
    expect(source, contains('final Set<String> _openingRooms'),
        reason: '同一房间重复点击按 roomId 去重（不再用全局 bool）');
    expect(source, isNot(contains('bool _openingRoom =')),
        reason: '全局 _openingRoom 会吞掉其它房间的打开请求');
  });

  test('AppHome 通过策略层 + 协调器按 roomId 去重打开房间', () {
    final source = File('lib/app_home.dart').readAsStringSync();
    expect(source, contains('RoomNavigationCoordinator('));
    // 打开前策略：RoomOpenRequest → RoomOpeningPolicy → 协调器。
    expect(source, contains('RoomOpeningPolicy('));
    expect(source, contains('_roomOpening.open('));
    expect(source, contains('navigate: _roomNavigation.open'));
    expect(source, contains('_openManagedRoomRequest(RoomOpenRequest('));
    expect(source, contains('onOpenRoom: _openManagedRoomRequest'));
    // 账号切换/退出登录清理登记。
    expect(source, contains('_roomNavigation.dispose();'));
    // 建群成功后复用统一房间导航（不再自建 RoomPage/租约）。
    expect(source, contains('RoomOpenSource.groupCreated'));
  });

  test('好友资料「发消息」仍走单一权威身份入口', () {
    final source = File('lib/app_home.dart').readAsStringSync();
    final matrixHome =
        source.substring(source.indexOf('MatrixHomePage(')).split('1 =>')[0];
    expect(matrixHome, contains('onMessage: _openMessage'));

    final root = source.split('final class ContactsTabPage')[0];
    expect(root, contains('Future<void> _openMessage(ContactDetails contact)'));
    expect(root, contains('resolveFriendContact(cache, contact)'));
    expect(root, contains('directChats.open(matrixUserId)'));

    // 生命周期边界：闸门只包住「身份解析 + canonical roomId」，RoomPage/租约
    // （_openManagedRoom）必须在闸门之外，否则 Room A 打开期间再次「发消息」
    // 会被闸门吞掉（真机 BUG）。
    final openMessage = root.substring(
      root.indexOf('Future<void> _openMessage(ContactDetails contact)'),
      root.indexOf('Future<DirectMessageTarget> _resolveDirectMessageTarget'),
    );
    expect(openMessage, contains('() => _resolveDirectMessageTarget(contact)'),
        reason: 'DirectMessageOpenGate 只能持有身份 + canonical 房间解析');
    expect(openMessage, contains('await _openManagedRoom(target.roomId'),
        reason: '_openManagedRoom 必须在闸门之外');
    expect(openMessage.indexOf('_directMessageGate.run('),
        lessThan(openMessage.indexOf('await _openManagedRoom(')),
        reason: '先解析出 DirectMessageTarget，再打开房间页面');
    expect(openMessage, isNot(contains('directChats.open')),
        reason: 'canonical 房间解析只在闸门内完成');

    // 通讯录只是入口：不得再自建 RoomLease / RoomPage / direct chat 查找。
    final contactsTab = source
        .split('final class ContactsTabPage')[1]
        .split('final class ProfileTabPage')[0];
    expect(contactsTab, contains('onMessage: widget.onMessage'),
        reason: '通讯录把 AppHome 的统一入口透传给资料页');
    expect(contactsTab, isNot(contains('openRoomLease')));
    expect(contactsTab, isNot(contains('builder: (_) => RoomPage(')));
    expect(contactsTab, isNot(contains('setOnRevoked')));
    expect(contactsTab, isNot(contains('directChats.open')));
    expect(contactsTab, isNot(contains('_openMessage(ContactDetails')));
  });

  test('canonical direct chat 仲裁仍只在协调网关里', () {
    final source = File('lib/app_home.dart').readAsStringSync();
    expect(source, contains('CoordinatedDirectChatGateway('));
    expect(source, contains('Future<DirectChatRoom> _openCanonicalDirectRoom'));
    expect(source, isNot(contains('createEncryptedDirectRoom(')));
  });
}
