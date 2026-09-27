import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/emoji_vault.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_emoji_vault.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:typed_data';
import '../features/matrix/matrix_client_factory_test.dart'
    show SnapshotClient, CountingSnapshotRoom;

final class _BaseBackend
    implements MatrixEmojiVaultBackend, MatrixEmojiVaultMetadataBackend {
  String? storedRoomId;
  bool encrypted = true;
  var creates = 0;
  var stores = 0;
  final events = <EmojiVaultEvent>[];
  final sentTypes = <String>[];
  List<EmojiVaultEvent>? cachedEvents;
  bool offline = false;
  Uint8List? uploaded;
  @override
  Future<List<EmojiVaultEvent>?> readCachedEvents(String roomId) async =>
      cachedEvents;

  @override
  String? readStoredRoomId() => storedRoomId;

  @override
  Future<String> createEncryptedVaultRoom() async {
    creates++;
    return '!emoji-vault:example.test';
  }

  @override
  Future<void> storeRoomId(String roomId) async {
    stores++;
    storedRoomId = roomId;
  }

  @override
  Future<bool> isRoomEncrypted(String roomId) async => encrypted;

  @override
  Future<List<EmojiVaultEvent>> loadEvents(String roomId) async {
    if (offline) throw StateError('offline');
    return events;
  }

  @override
  Future<Uint8List> downloadAndDecrypt(
    String roomId,
    Map<String, Object?> encryptedFile,
  ) async =>
      Uint8List.fromList(uploaded ?? const [9, 8, 7]);

  @override
  Future<Map<String, Object?>> uploadEncrypted(
    String roomId,
    Uint8List bytes,
    String mimeType,
  ) async {
    uploaded = Uint8List.fromList(bytes);
    return {
      'url': 'mxc://example.test/encrypted',
      'key': const {'k': 'secret'}
    };
  }

  @override
  Future<void> sendEncryptedEvent(
    String roomId,
    String type,
    Map<String, Object?> content,
  ) async {
    sentTypes.add(type);
  }
}

final class _Backend extends _BaseBackend
    implements MatrixEmojiVaultRevisionBackend {
  int calls = 0;
  @override
  int metadataRevision = 0;
  Completer<List<EmojiVaultEvent>>? pending;
  @override
  Future<List<EmojiVaultEvent>> loadEvents(String roomId) {
    calls++;
    return pending?.future ?? super.loadEvents(roomId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('rooms share account backend beyond the originating room lifetime',
      () async {
    final client = SnapshotClient();
    client.snapshotRooms.addAll([
      CountingSnapshotRoom(id: '!a:test', client: client, joined: true),
      CountingSnapshotRoom(id: '!b:test', client: client, joined: true),
    ]);
    final owner = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://matrix.example'));
    final a = await owner.openRoomLease('!a:test');
    final b = await owner.openRoomLease('!b:test');
    final first = await a.openEmojiVaultBackend();
    expect(identical(first, await b.openEmojiVaultBackend()), isTrue);
    await a.cancel();
    expect(first.readStoredRoomId(), isNull);
    client.matrixUserId = '@other:test';
    expect(first.readStoredRoomId, throwsStateError,
        reason: 'same SDK object cannot reuse an old-account backend');
    final other = await b.openEmojiVaultBackend();
    expect(identical(first, other), isFalse);
    expect((other as MatrixEmojiVaultCacheIdentity).cacheIdentity,
        contains('@other:test'));
    await b.cancel();
    await owner.suspend();
    expect(first.readStoredRoomId, throwsStateError);
    await client.dispose();
  });

  test('an event racing initial history loading cannot be marked fresh',
      () async {
    final backend = _Backend()..storedRoomId = '!vault';
    final pending = backend.pending = Completer<List<EmojiVaultEvent>>();
    final opening = MatrixEmojiVault.open(backend);
    for (var i = 0; i < 10 && backend.calls == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(backend.calls, 1);
    backend.metadataRevision++;
    backend.pending = null;
    pending.complete([]);
    final session = await opening;
    await session.refresh(force: false);
    expect(backend.calls, 2,
        reason: 'initial result predates the latest event');
  });

  test('concurrent and repeated background refreshes share successful work',
      () async {
    final backend = _Backend()
      ..storedRoomId = '!vault'
      ..cachedEvents = [];
    final session = await MatrixEmojiVault.open(backend);
    backend.pending = Completer<List<EmojiVaultEvent>>();
    final a = session.refresh(force: false);
    final b = session.refresh(force: false);
    expect(backend.calls, 1);
    backend.pending!.complete([]);
    await Future.wait([a, b]);
    backend.pending = null;
    await session.refresh(force: false);
    expect(backend.calls, 1);
    backend.metadataRevision++;
    await session.refresh(force: false);
    expect(backend.calls, 2, reason: 'remote changes invalidate freshness');
    await session.refresh();
    expect(backend.calls, 3,
        reason: 'explicit refresh bypasses the background window');
  });

  test(
      'failed refresh is retryable and in-flight invalidation gets a trailing pass',
      () async {
    final backend = _Backend()
      ..storedRoomId = '!vault'
      ..cachedEvents = []
      ..offline = true;
    final session = await MatrixEmojiVault.open(backend);
    await expectLater(session.refresh(force: false), throwsStateError);
    backend.offline = false;
    backend.pending = Completer<List<EmojiVaultEvent>>();
    final pending = backend.pending!;
    final result = session.refresh(force: false);
    backend.metadataRevision++;
    backend.pending = null;
    pending.complete([]);
    await result;
    expect(backend.calls, 3, reason: 'failed + old revision + fresh revision');
  });
}
