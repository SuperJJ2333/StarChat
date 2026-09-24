import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _roomId = '!cold-preview:test';

class _SyncCountingClient extends Client {
  _SyncCountingClient(MatrixSdkDatabase database)
      : super('cold-preview', databaseBuilder: (_) => database);
  int syncCalls = 0;
  @override
  Future<void> handleSync(SyncUpdate sync, {Direction? direction}) {
    syncCalls++;
    return super.handleSync(sync, direction: direction);
  }
}

class _ReadRecordingDatabase extends Fake implements Database {
  _ReadRecordingDatabase(this.delegate, this.eventReads);
  final Database delegate;
  final List<List<Object?>?> eventReads;
  @override
  Batch batch() => delegate.batch();
  @override
  Future<void> close() => delegate.close();
  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      delegate.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);
  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      delegate.delete(table, where: where, whereArgs: whereArgs);
  @override
  Future<List<Map<String, Object?>>> query(String table,
      {bool? distinct,
      List<String>? columns,
      String? where,
      List<Object?>? whereArgs,
      String? groupBy,
      String? having,
      String? orderBy,
      int? limit,
      int? offset}) {
    if (table == 'box_events') eventReads.add(whereArgs?.toList());
    return delegate.query(table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset);
  }
}

Map<String, dynamic> _message(String id, int timestamp,
        {EventStatus status = EventStatus.synced}) =>
    {
      'event_id': id,
      'type': EventTypes.Message,
      'sender': '@self:test',
      'origin_server_ts': timestamp,
      'status': status.intValue,
      'unsigned': {messageSendingStatusKey: status.intValue},
      'content': {'msgtype': 'm.text', 'body': 'synthetic $id'},
    };

Map<String, dynamic> _recall(String target, int timestamp) => {
      'event_id': '\$recall-$target',
      'type': EventTypes.Redaction,
      'sender': '@self:test',
      'origin_server_ts': timestamp,
      'redacts': target,
      'content': <String, dynamic>{},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late Directory directory;
  late String path;
  late MatrixSdkDatabase database;
  late _SyncCountingClient client;
  final eventReads = <List<Object?>?>[];
  final now = DateTime.now().millisecondsSinceEpoch;

  Future<void> open() async {
    database = MatrixSdkDatabase(path,
        sqfliteFactory: databaseFactoryFfi,
        database: _ReadRecordingDatabase(
            await databaseFactoryFfi.openDatabase(path), eventReads));
    await database.open();
    client = _SyncCountingClient(database);
    await client.init();
  }

  Future<void> sync(List<Map<String, dynamic>> events,
          {Direction? direction}) =>
      database.transaction(() => client.handleSync(
          SyncUpdate.fromJson({
            'next_batch': '',
            'rooms': {
              'join': {
                _roomId: {
                  'timeline': {'events': events, 'limited': false},
                },
              },
            },
          }),
          direction: direction));

  Future<Room> reopen() async {
    await client.dispose();
    await open();
    return (await database.getRoomList(client)).single;
  }

  // A supported independent persistence path (also used by push retrieval)
  // updates canonical events/fragments without rewriting the room snapshot.
  // This reproduces legacy cache drift, not a partial committed normal sync.
  Future<void> canonical(Map<String, dynamic> event,
          {EventUpdateType type = EventUpdateType.timeline}) =>
      database.storeEventUpdate(
          EventUpdate(roomID: _roomId, type: type, content: event), client);

  Map<String, dynamic> edit(String id, String target, int timestamp) => {
        ..._message(id, timestamp),
        'content': {
          'msgtype': 'm.text',
          'body': 'synthetic edit',
          'm.new_content': {
            'msgtype': 'm.text',
            'body': 'synthetic edited text'
          },
          'm.relates_to': {'rel_type': 'm.replace', 'event_id': target},
        },
      };

  setUp(() async {
    final root = Directory(
        '../../docs/verification/artifacts/2026-09-24/cold-start-cache');
    await root.create(recursive: true);
    directory = await root.createTemp('preview-');
    path = '${directory.path}/matrix.sqlite';
    await open();
  });

  tearDown(() async {
    await client.dispose();
    await databaseFactoryFfi.deleteDatabase(path);
    await directory.delete();
  });

  test('complete sync preserves newest preview across disk reopen', () async {
    await sync([_message(r'$old', now)]);
    await sync([_recall(r'$old', now + 1)]);
    await sync([_message(r'$new', now + 2)]);
    final room = await reopen();
    expect(room.lastEvent?.eventId, r'$new');
    expect(room.lastEvent?.redacted, isFalse);
  });

  test('recall remains irreversible after stale history replay and reopen',
      () async {
    await sync([_message(r'$latest', now)]);
    await sync([_recall(r'$latest', now + 1)]);
    await sync([_message(r'$latest', now)], direction: Direction.b);
    final room = await reopen();
    expect((await database.getEventById(r'$latest', room))?.redacted, isTrue);
    expect(room.lastEvent?.eventId, r'$latest');
    expect(room.lastEvent?.redacted, isTrue,
        reason: 'cold-start preview must use the durable redaction tombstone');
  });

  test('older history cannot displace the latest preview', () async {
    await sync([_message(r'$latest', now)]);
    await sync([_message(r'$older', now - 100)], direction: Direction.b);
    final room = await reopen();
    expect(room.lastEvent?.eventId, r'$latest');
  });

  test('local pending preview retains sending state across reopen', () async {
    await sync([_message(r'$synced', now)]);
    await sync([
      _message(r'$local', now + 1, status: EventStatus.sending),
    ]);
    final room = await reopen();
    expect(room.lastEvent?.eventId, r'$local');
    expect(room.lastEvent?.status, EventStatus.sending);
  });

  test('legacy recalled room snapshot yields to newer canonical timeline',
      () async {
    await sync([_message(r'$old', now)]);
    await sync([_recall(r'$old', now + 1)]);
    await canonical(_message(r'$new', now + 2));
    final before = client.getRoomById(_roomId)!;
    expect(before.lastEvent?.redacted, isTrue);
    expect((await database.getEventList(before)).first.eventId, r'$new');
    final room = await reopen();
    expect(room.lastEvent?.eventId, r'$new');
    expect(room.lastEvent?.redacted, isFalse);
  });

  test('canonical same-event recall cannot revive from stale room plaintext',
      () async {
    await sync([_message(r'$latest', now)]);
    await canonical(_recall(r'$latest', now + 1));
    final room = await reopen();
    expect(room.lastEvent?.eventId, r'$latest');
    expect(room.lastEvent?.redacted, isTrue);
    expect(room.lastEvent?.content, isEmpty);
  });

  test('latest canonical recalled message stays recalled during repair',
      () async {
    await sync([_message(r'$old', now)]);
    await canonical(_message(r'$new', now + 1));
    await canonical(_recall(r'$new', now + 2));
    final room = await reopen();
    expect(room.lastEvent?.eventId, r'$new');
    expect(room.lastEvent?.redacted, isTrue);
  });

  test(
      'history appended behind current event cannot steal preview by timestamp',
      () async {
    await sync([_message(r'$latest', now)]);
    await canonical(_message(r'$historical-clock-skew', now + 1000),
        type: EventUpdateType.history);
    expect((await reopen()).lastEvent?.eventId, r'$latest');
  });

  test('limited fragment gap cannot regress a newer room snapshot', () async {
    await sync([_message(r'$latest', now + 100)]);
    await database.deleteTimelineForRoom(_roomId);
    await canonical(_message(r'$older', now), type: EventUpdateType.history);
    expect((await reopen()).lastEvent?.eventId, r'$latest');
  });

  test('newer pending local message beats older repaired synced timeline',
      () async {
    await sync([_message(r'$old', now)]);
    await canonical(_message(r'$new', now + 1));
    await canonical(
        _message(r'$pending', now + 2, status: EventStatus.sending));
    final room = await reopen();
    expect(room.lastEvent?.eventId, r'$pending');
    expect(room.lastEvent?.status, EventStatus.sending);
  });

  test('newer synced message beats stale pending local message', () async {
    await sync([_message(r'$pending', now, status: EventStatus.sending)]);
    await canonical(_message(r'$new', now + 1));
    final room = await reopen();
    expect(room.lastEvent?.eventId, r'$new');
    expect(room.lastEvent?.status, EventStatus.synced);
  });

  test('canonical acknowledgement advances same-event send status', () async {
    await sync([_message(r'$pending', now, status: EventStatus.sending)]);
    await canonical(_message(r'$pending', now));
    expect((await reopen()).lastEvent?.status, EventStatus.synced);
  });

  test('edit of older message does not replace current conversation preview',
      () async {
    await sync([_message(r'$older', now), _message(r'$latest', now + 1)]);
    await canonical(edit(r'$edit-old', r'$older', now + 2));
    expect((await reopen()).lastEvent?.eventId, r'$latest');
  });

  test('edit of repaired newest message becomes the preview', () async {
    await sync([_message(r'$older', now)]);
    await canonical(_message(r'$latest', now + 1));
    await canonical(edit(r'$edit-new', r'$latest', now + 2));
    expect((await reopen()).lastEvent?.eventId, r'$edit-new');
  });

  test(
      'old edit cannot steal preview after selecting a newer canonical message',
      () async {
    await sync([_message(r'$older', now)]);
    await canonical(_message(r'$newest', now + 1));
    await canonical(edit(r'$edit-old', r'$older', now + 2));
    expect((await reopen()).lastEvent?.eventId, r'$newest');
  });

  test('canonical recall of edit root wins even outside the bounded fragment',
      () async {
    await sync([_message(r'$original', now)]);
    await sync([edit(r'$edit', r'$original', now + 1)]);
    await database.deleteTimelineForRoom(_roomId);
    await canonical(_recall(r'$original', now + 2));
    final room = await reopen();
    expect(room.lastEvent?.eventId, r'$edit');
    expect(room.lastEvent?.redacted, isTrue);
    expect(room.lastEvent?.content, isEmpty);
  });

  test('decrypted same-ID room snapshot survives canonical encrypted envelope',
      () async {
    await sync([_message(r'$latest', now)]);
    await canonical({
      ..._message(r'$latest', now),
      'type': EventTypes.Encrypted,
      'content': {
        'algorithm': 'm.megolm.v1.aes-sha2',
        'ciphertext': 'synthetic'
      },
    });
    final room = await reopen();
    expect(room.lastEvent?.type, EventTypes.Message);
    expect(room.lastEvent?.body, r'synthetic $latest');
  });

  test(
      'encrypted same-ID acknowledgement advances status without losing plaintext',
      () async {
    await sync([_message(r'$latest', now, status: EventStatus.sending)]);
    await canonical({
      ..._message(r'$latest', now + 1),
      'type': EventTypes.Encrypted,
      'content': {
        'algorithm': 'm.megolm.v1.aes-sha2',
        'ciphertext': 'synthetic'
      },
    });
    final room = await reopen();
    expect(room.lastEvent?.type, EventTypes.Message);
    expect(room.lastEvent?.body, r'synthetic $latest');
    expect(room.lastEvent?.status, EventStatus.synced);
    expect(room.lastEvent?.originServerTs.millisecondsSinceEpoch, now + 1);
  });

  test(
      'startup event reads are batched and bounded to head and pending windows',
      () async {
    await sync([_message(r'$baseline', now)]);
    for (var i = 0; i < 60; i++) {
      await canonical(_message('\$timeline-$i', now + i + 1));
      await canonical(
          _message('\$pending-$i', now + i + 100, status: EventStatus.sending));
    }
    eventReads.clear();
    final room = await reopen();
    expect(room.lastEvent?.eventId, r'$pending-59');
    expect(eventReads.length, 1,
        reason: 'one batched event lookup per room set');
    expect(eventReads.single, isNotNull, reason: 'never scan the event table');
    expect(eventReads.single!.length, lessThanOrEqualTo(41));
  });

  test('reading a stale non-head pending event does not invoke sync self-heal',
      () async {
    await sync([_message(r'$latest', now)]);
    await canonical(_message(r'$stale-nonhead', now - 3600000,
        status: EventStatus.sending));
    final room = await reopen();
    await Future<void>.delayed(Duration.zero);
    expect(room.lastEvent?.eventId, r'$latest');
    expect(client.syncCalls, 0,
        reason:
            'optional preview projection must not invoke the send lifecycle');
  });

  test('malformed optional event candidate leaves valid room preview available',
      () async {
    await sync([_message(r'$latest', now)]);
    await canonical({..._message(r'$malformed', now + 1), 'type': 42});
    expect((await reopen()).lastEvent?.eventId, r'$latest');
  });
}
