import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every production room entry wires the profile message action', () {
    for (final path in [
      'lib/app_home.dart',
      'lib/features/matrix/matrix_home_page.dart',
    ]) {
      final source = File(path).readAsStringSync();
      final entries = source.split('builder: (_) => RoomPage(').skip(1);
      expect(entries, isNotEmpty);
      for (final entry in entries) {
        final arguments =
            entry.substring(0, entry.indexOf('initialIdentityCache:'));
        expect(arguments, contains('onMessage:'),
            reason: '$path room entry must keep friend messaging reachable');
      }
    }
  });

  test('friends profile messaging goes through the single canonical opener',
      () {
    final source = File('lib/app_home.dart').readAsStringSync();
    // 朋友圈/群聊/会话资料入口持有的 onMessage 必须仍是 AppHome 的统一实现。
    final matrixHome =
        source.substring(source.indexOf('MatrixHomePage(')).split('1 =>')[0];
    expect(matrixHome, contains('onMessage: _openMessage'));

    final root = source.split('final class ContactsTabPage')[0];
    expect(root, contains('Future<void> _openMessage(ContactDetails contact)'));
    // 统一入口按权威 matrixUserId 打开 canonical 私密会话（不是入口快照里的旧值）。
    expect(root, contains('resolveFriendContact(cache, contact)'));
    expect(root, contains('directChats.open(authoritative.matrixUserId.trim())'));
    // 同一好友的打开请求单飞，避免重复 push RoomPage。
    expect(root, contains('_directMessageGate.claim(openingKey)'));

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

  test('canonical direct chat arbitration stays in the coordinated gateway', () {
    final source = File('lib/app_home.dart').readAsStringSync();
    expect(source, contains('CoordinatedDirectChatGateway('));
    // 统一入口必须经 DirectChatController（并发合并 + 规范房间登记），
    // 不得自行调用 createOnce/createEncryptedDirectRoom。
    expect(source, contains('Future<DirectChatRoom> _openCanonicalDirectRoom'));
    expect(source, isNot(contains('createEncryptedDirectRoom(')));
  });
}
