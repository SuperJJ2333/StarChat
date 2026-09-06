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

  test('message tab passes its existing canonical opener into room navigation',
      () {
    final source = File('lib/app_home.dart').readAsStringSync();
    final matrixHome = source.split(': MatrixHomePage(')[1].split('1 =>')[0];
    expect(matrixHome, contains('onMessage: _openMessage'));
    final root = source.split('final class ContactsTabPage')[0];
    expect(root, contains('Future<void> _openMessage(ContactDetails contact)'));
    expect(root, contains('directChats.open(contact.matrixUserId)'));
  });
}
