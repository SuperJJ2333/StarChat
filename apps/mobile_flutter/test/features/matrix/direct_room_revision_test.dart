import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/duplicate_room_registry.dart';
import 'package:liuhetong_mobile/features/matrix/direct_room_directory_convergence.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:matrix/matrix.dart';
import 'logical_conversation_reliability_test.dart' show AssociationClient;

class DelayedHistoryStore extends InMemorySharedPreferencesStore {
  DelayedHistoryStore() : super.empty();
  final paused = Completer<void>();
  final release = Completer<void>();
  bool enabled = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (enabled &&
        value is String &&
        value.contains('!history:test') &&
        !paused.isCompleted) {
      paused.complete();
      await release.future;
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({
        'duplicate-room-registry-v1:%40me%3Atest': jsonEncode({
          'entries': [],
          'primaries': {'@peer:test': '!new:test'},
          'revisions': {'@peer:test': 5},
        }),
      }));

  test('late unversioned directory cannot roll back durable primary', () async {
    final registry = DuplicateRoomRegistry();
    await registry.rememberPrimary('@me:test', '@peer:test', '!old:test');
    expect(
        registry.primaryRoomIdForPeer('@me:test', '@peer:test'), '!new:test');
  });

  test('old source association retains history without changing primary',
      () async {
    final registry = DuplicateRoomRegistry();
    await registry.record(
        accountId: '@me:test',
        peerId: '@peer:test',
        primaryRoomId: '!old:test',
        duplicateRoomId: '!history:test');
    expect(
        registry.primaryRoomIdForPeer('@me:test', '@peer:test'), '!new:test');
    expect(registry.primaryRoomIdForDuplicate('@me:test', '!history:test'),
        '!new:test');
  });

  test('new revision persists across restart and fences equal or older claims',
      () async {
    final registry = DuplicateRoomRegistry();
    expect(
        await registry.rememberPrimary('@me:test', '@peer:test', '!next:test',
            revision: 6),
        isTrue);
    final restarted = DuplicateRoomRegistry();
    expect(
        await restarted.rememberPrimary('@me:test', '@peer:test', '!old:test',
            revision: 5),
        isFalse);
    expect(
        await restarted.rememberPrimary('@me:test', '@peer:test', '!other:test',
            revision: 6),
        isFalse);
    expect(restarted.revisionForPeer('@me:test', '@peer:test'), 6);
    expect(
        restarted.primaryRoomIdForPeer('@me:test', '@peer:test'), '!next:test');
    expect(restarted.primaryRoomIdForDuplicate('@me:test', '!new:test'),
        '!next:test');
    expect(
        await restarted.rememberPrimary(
            '@other:test', '@peer:test', '!other:test',
            revision: 1),
        isTrue);
  });

  test('same primary newer revision must also persist', () async {
    final registry = DuplicateRoomRegistry();
    await registry.rememberPrimary('@me:test', '@peer:test', '!new:test',
        revision: 9);
    final restarted = DuplicateRoomRegistry();
    await restarted.ensureLoaded('@me:test');
    expect(restarted.revisionForPeer('@me:test', '@peer:test'), 9);
    expect(
        await restarted.rememberPrimary('@me:test', '@peer:test', '!other:test',
            revision: -1),
        isFalse);
  });

  test(
      'late old association response retains source but publishes current primary',
      () async {
    final client = AssociationClient();
    client.directory['@peer:test'] = ['!new:test'];
    final registry = DuplicateRoomRegistry();
    await convergeDirectDirectory(client,
        registry: registry,
        businessUserIdOf: (_) => 'peer',
        associationsOf: (_) async => const DirectRoomAssociations(
            primaryRoomId: '!old:test',
            roomIds: ['!old:test', '!history:test'],
            revision: 2));
    expect(
        registry.primaryRoomIdForPeer('@me:test', '@peer:test'), '!new:test');
    expect(registry.primaryRoomIdForDuplicate('@me:test', '!history:test'),
        '!new:test');
    expect(client.accountWrites, isNotEmpty);
    expect(
        client.accountWrites.every((body) =>
            body['primary_room_id'] == '!new:test' && body['revision'] == 5),
        isTrue);
  });

  test('concurrent old response cannot roll back newer resolved directory',
      () async {
    final client = AssociationClient();
    client.directory['@peer:test'] = ['!new:test'];
    final registry = DuplicateRoomRegistry();
    final started = Completer<void>();
    final delayed = Completer<DirectRoomAssociations?>();
    final old = convergeDirectDirectory(client,
        registry: registry,
        businessUserIdOf: (_) => 'peer',
        associationsOf: (_) {
          started.complete();
          return delayed.future;
        });
    await started.future;
    await convergeDirectDirectory(client,
        registry: registry,
        businessUserIdOf: (_) => 'peer',
        associationsOf: (_) async => const DirectRoomAssociations(
            primaryRoomId: '!next:test',
            roomIds: ['!new:test', '!next:test'],
            revision: 6));
    delayed.complete(const DirectRoomAssociations(
        primaryRoomId: '!old:test', roomIds: ['!old:test'], revision: 1));
    await old;
    expect(
        registry.primaryRoomIdForPeer('@me:test', '@peer:test'), '!next:test');
    expect(registry.revisionForPeer('@me:test', '@peer:test'), 6);
    expect(
        client.accountWrites
            .every((body) => body['primary_room_id'] == '!next:test'),
        isTrue);
  });

  test('older primary-only metadata still restores its historical identity',
      () async {
    final client = AssociationClient();
    final type =
        '$directConversationAssociationPrefix${Uri.encodeComponent('!old:test')}';
    client.accountData[type] = BasicEvent(type: type, content: {
      'room_id': '!old:test',
      'primary_room_id': '!old:test',
      'peer_id': '@peer:test',
      'revision': 2,
    });
    final registry = DuplicateRoomRegistry();
    await loadDirectRoomAssociations(client, registry);
    expect(
        registry.primaryRoomIdForPeer('@me:test', '@peer:test'), '!new:test');
    expect(registry.primaryRoomIdForDuplicate('@me:test', '!old:test'),
        '!new:test');
  });

  test('revision change during history persistence fences account-data upload',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = DelayedHistoryStore();
    SharedPreferencesStorePlatform.instance = store;
    final client = AssociationClient();
    client.directory['@peer:test'] = ['!new:test'];
    final registry = DuplicateRoomRegistry();
    await registry.rememberPrimary('@me:test', '@peer:test', '!new:test',
        revision: 5);
    store.enabled = true;
    final convergence = convergeDirectDirectory(client,
        registry: registry,
        businessUserIdOf: (_) => 'peer',
        associationsOf: (_) async => const DirectRoomAssociations(
            primaryRoomId: '!new:test',
            roomIds: ['!new:test', '!history:test'],
            revision: 5));
    await store.paused.future;
    // rememberPrimary updates memory before awaiting its queued disk write.
    final advance = registry
        .rememberPrimary('@me:test', '@peer:test', '!next:test', revision: 6);
    await Future<void>.delayed(Duration.zero);
    store.release.complete();
    await Future.wait([convergence, advance]);
    expect(
        client.accountWrites
            .where((body) => body['room_id'] == '!history:test'),
        isEmpty);
    expect(registry.primaryRoomIdForDuplicate('@me:test', '!history:test'),
        '!next:test');
  });
}
