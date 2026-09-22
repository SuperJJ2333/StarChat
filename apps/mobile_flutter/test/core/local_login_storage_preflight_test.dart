import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'session_store_test.dart' show MemorySecureKeyValueStore;
import 'account_chat_store_test.dart' show binding;

void main() {
  test('preflight never creates keys on first login', () async {
    final memory = MemorySecureKeyValueStore();
    await (SecureSessionStore(memory) as dynamic).validateLocalLoginStorage();
    expect(memory.values, isEmpty);
    expect(memory.attemptedDeletes, isEmpty);
  });
  test(
      'preflight rejects the conflicting registry before remote login without writes',
      () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    await store.matrixDatabaseKey();
    await store.saveMatrixBinding(binding('@a:test', 'device-A'));
    await store.selectMatrixAccount('https://matrix.example', '@a:test');
    final registry =
        jsonDecode(memory.values['liuhetong.matrix_account_slots.v1']!)
            as Map<String, dynamic>;
    registry[registry.keys.single] = 'b' * 64;
    // Keep empty slot registered under a different identity, so scope is valid
    // but the existing binding is incorrectly associated with another slot.
    registry['c' * 64] = '';
    memory.values['liuhetong.matrix_account_slots.v1'] = jsonEncode(registry);
    final before = Map<String, String>.from(memory.values);
    await expectLater(
        (store as dynamic).validateLocalLoginStorage(), throwsFormatException);
    expect(memory.values, before);
    expect(memory.attemptedDeletes, isEmpty);
  });
  test('missing retained key fails without generating a replacement', () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    await store.saveMatrixBinding(binding('@a:test', 'device-A'));
    final before = Map<String, String>.from(memory.values);
    await expectLater(
        (store as dynamic).validateLocalLoginStorage(), throwsFormatException);
    expect(memory.values, before);
  });
}
