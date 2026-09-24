import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'session_store_test.dart' show MemorySecureKeyValueStore;
import 'account_chat_store_test.dart' show binding;

final class _PeekOnlyStore
    implements SecureKeyValueStore, PeekableSecureKeyValueStore {
  _PeekOnlyStore(this.values);

  final Map<String, String> values;
  final reads = <String>[];
  final writes = <String>[];
  final deletes = <String>[];

  @override
  Future<String?> peek(String key) async => values[key];

  @override
  Future<String?> read(String key) async {
    reads.add(key);
    throw StateError('legacy Keychain read may update accessibility');
  }

  @override
  Future<void> write(String key, String value) async {
    writes.add(key);
    throw StateError('preflight must not write');
  }

  @override
  Future<void> delete(String key) async {
    deletes.add(key);
    throw StateError('preflight must not delete');
  }
}

void main() {
  test('prelogin metadata validation uses only non-mutating Keychain peeks',
      () async {
    final oldBinding = binding('@a:test', 'device-A');
    final memory = _PeekOnlyStore({
      'liuhetong.matrix_local_binding.v1': jsonEncode(oldBinding.toJson()),
      'liuhetong.matrix_database_key.v1': 'retained-cipher',
    });

    await SecureSessionStore(memory).validateLocalLoginStorage();

    expect(memory.reads, isEmpty);
    expect(memory.writes, isEmpty);
    expect(memory.deletes, isEmpty);
  });

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
