import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';
import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Synthetic identity/HTTP only. The database, cipher, SDK Room/Timeline, room
// leases, presentation controller and anchored list are production code.
// This shell deliberately does not pretend to be the full RoomPage/AppHome.
class _Client extends Client {
  _Client(this.store)
      : super('native-history', httpClient: MockClient((request) async {
          throw StateError('Native local history attempted network access');
        })) {
    homeserver = Uri.parse('https://native-history.invalid');
    backgroundSync = false;
  }
  final MatrixSdkDatabase store;
  final localRooms = <Room>[];
  @override
  DatabaseApi get database => store;
  @override
  List<Room> get rooms => localRooms;
  @override
  String get userID => '@synthetic:native-history.invalid';
  @override
  String get deviceID => 'SYNTHETIC';
  @override
  bool isLogged() => true;
}

class _Database extends MatrixSdkDatabase {
  _Database(Database sql) : super('native-history', database: sql);
  Completer<void>? holdRead;
  Completer<void>? readEntered;
  final optionalEntered = Completer<void>();
  final optionalRelease = Completer<void>();
  int initialReadLimit = -1;

  @override
  Future<List<Event>> getEventList(Room room,
      {int start = 0, bool onlySending = false, int? limit}) async {
    initialReadLimit = limit ?? -1;
    final held = holdRead;
    if (held != null) {
      if (!readEntered!.isCompleted) readEntered!.complete();
      await held.future;
    }
    return super.getEventList(room,
        start: start, onlySending: onlySending, limit: limit);
  }

  @override
  Future<Map<String, int>> getTimelineEventPositions(
      Room room, Iterable<String> ids) async {
    if (!optionalEntered.isCompleted) optionalEntered.complete();
    await optionalRelease.future;
    return super.getTimelineEventPositions(room, ids);
  }

  void releaseAll() {
    if (!optionalRelease.isCompleted) optionalRelease.complete();
    if (holdRead != null && !holdRead!.isCompleted) holdRead!.complete();
  }
}

class _Fixture {
  Directory? _root;
  Database? _sql;
  _Database? _database;
  _Client? _client;
  MatrixSdkE2eeClient? _matrix;
  Directory get root => _root!;
  _Database get database => _database!;
  _Client get client => _client!;
  MatrixSdkE2eeClient get matrix => _matrix!;
  late Room room;
  final leases = <MatrixRoomLease>[];
  final controllers = <RoomTimelineController>[];
  final operations = <Future<void>>[];
  bool _closed = false;
  bool _databaseOpened = false;
  bool _opened = false;

  Future<void> open() async {
    expect(Platform.isAndroid, isTrue);
    final parent = await PendingMediaDirectory.directory();
    _root = await parent.createTemp('native-history-');
    expect(p.isWithin(parent.absolute.path, root.absolute.path), isTrue);
    final factory =
        createDatabaseFactoryFfi(ffiInit: SQfLiteEncryptionHelper.ffiInit);
    final encryption = SQfLiteEncryptionHelper(
        factory: factory,
        path: p.join(root.path, 'history.db'),
        cipher: 'synthetic-native-history-key');
    final sql = await factory.openDatabase(encryption.path,
        options: OpenDatabaseOptions(
            singleInstance: false, onConfigure: encryption.applyPragmaKey));
    _sql = sql;
    expect(await sql.rawQuery('PRAGMA cipher_version'), isNotEmpty);
    _database = _Database(sql);
    await database.open();
    _databaseOpened = true;
    _client = _Client(database);
    room = Room(
        id: '!history:native-history.invalid',
        client: client,
        membership: Membership.join);
    client.localRooms.add(room);
    final batch = sql.batch();
    batch.insert('box_timeline_fragments', {
      'k': '${room.id}|',
      'v': jsonEncode(List.generate(360, (i) => 'native-$i')),
    });
    for (var i = 0; i < 360; i++) {
      batch.insert('box_events', {
        'k': '${room.id}|native-$i',
        'v': jsonEncode({
          'event_id': 'native-$i',
          'type': EventTypes.Message,
          'sender': '@peer:native-history.invalid',
          'origin_server_ts': DateTime.utc(2026, 10, 16)
              .subtract(Duration(minutes: i))
              .millisecondsSinceEpoch,
          'content': {'msgtype': 'm.text', 'body': 'Native cached row $i'},
        }),
      });
    }
    await batch.commit(noResult: true);
    _matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://native-history.invalid'),
        suspendClient: (_) async {},
        readContinuityMetadata: (_) async => MatrixClientContinuityMetadata(
            isLoggedIn: true,
            userId: client.userID,
            deviceId: client.deviceID,
            ed25519Fingerprint: 'synthetic',
            databaseGeneration: root.path));
    _opened = true;
  }

  Future<MatrixRoomLease> lease() async {
    final result = await matrix.openRoomLease(room.id);
    leases.add(result);
    return result;
  }

  Future<RoomTimelineController> timeline(MatrixRoomLease lease) async {
    RoomTimelineController? controller;
    final capability = await lease.openRoomTimeline(
        onUpdate: () => controller?.scheduleRefresh());
    controller = RoomTimelineController(MatrixRoomTimelineAdapter(capability),
        windowed: true);
    controllers.add(controller);
    return controller;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _database?.releaseAll();
    // Every intentionally held operation has an observer before its release.
    await Future.wait(operations);
    for (final controller in controllers) {
      controller.dispose();
    }
    for (final lease in leases) {
      await lease.cancel();
    }
    await _matrix?.suspend();
    await _client?.dispose(closeDatabase: false);
    if (_databaseOpened) {
      await _database!.close();
    } else {
      await _sql?.close();
    }
    if (_root == null) return;
    try {
      if (_opened) {
        final header = await File(p.join(root.path, 'history.db'))
            .openRead(0, 16)
            .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
        expect(header, isNot(utf8.encode('SQLite format 3\u0000')));
      }
    } finally {
      final parent = await PendingMediaDirectory.directory();
      expect(
          p.isWithin(await parent.resolveSymbolicLinks(),
              await root.resolveSymbolicLinks()),
          isTrue);
      await root.delete(recursive: true);
    }
  }
}

class _View extends StatelessWidget {
  const _View(this.timeline, this.scroll, this.keys, this.viewport);
  final RoomTimelineController timeline;
  final ScrollController scroll;
  final Map<String, GlobalKey> keys;
  final GlobalKey viewport;
  @override
  Widget build(BuildContext context) => CupertinoApp(
      home: CupertinoPageScaffold(
          child: SafeArea(
              child: AnimatedBuilder(
                  animation: timeline,
                  builder: (_, __) {
                    final rows = timeline.messages.reversed.toList();
                    return SizedBox(
                        key: viewport,
                        child: AnchoredTimelineList(
                            controller: scroll,
                            followLatest: false,
                            eventIds: rows.map((row) => row.stableId).toList(),
                            messageKeys: keys,
                            itemBuilder: (_, index) {
                              final row = rows[index];
                              return SizedBox(
                                  key: keys.putIfAbsent(
                                      row.stableId, GlobalKey.new),
                                  height: 56,
                                  child: Text(row.text));
                            }));
                  }))));
}

Future<void> _until(
    WidgetTester tester, bool Function() condition, String milestone) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Native history milestone not reached: $milestone');
    }
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'native cipher history paints, pages and retains a visible anchor',
      (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.close);
    await fixture.open();
    final scroll = ScrollController();
    final keys = <String, GlobalKey>{};
    final viewport = GlobalKey();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    });
    final optional = fixture.database.getTimelineEventPositions(
        fixture.room, ['native-0']).then<void>((_) {});
    fixture.operations.add(optional);
    await fixture.database.optionalEntered.future;
    final lease = await fixture.lease();
    final timeline = await fixture.timeline(lease);
    expect(fixture.database.initialReadLimit, Room.defaultHistoryCount);
    expect(timeline.messages.length, Room.defaultHistoryCount);
    await tester.pumpWidget(_View(timeline, scroll, keys, viewport));
    await _until(
        tester,
        () => find.text('Native cached row 0').evaluate().isNotEmpty,
        'first real encrypted local row');
    expect(fixture.database.optionalRelease.isCompleted, isFalse,
        reason: 'optional position work must not gate first local paint');
    fixture.database.optionalRelease.complete();
    await optional;
    await timeline.loadHistory();
    expect(timeline.messages.length, 40);
    expect(timeline.messages.last.id, 'native-0');
    for (var page = 0; page < 4; page++) {
      await timeline.loadHistory();
      expect(timeline.messages.length, lessThanOrEqualTo(200));
    }
    expect(await timeline.openAnchor('native-150'), isTrue);
    expect(timeline.messages, hasLength(200));
    expect(timeline.hasEarlierWindow, isTrue);
    final beforeIds = timeline.messages.map((row) => row.id).toList();
    final beforeOldest = beforeIds.first;
    await tester.pump();
    await _until(
        tester,
        () => scroll.hasClients && scroll.position.hasContentDimensions,
        'anchored viewport layout');
    scroll.jumpTo(
        (scroll.position.minScrollExtent + scroll.position.maxScrollExtent) /
            2);
    await tester.pump();
    final anchor = TimelineScrollAnchor.capture(keys, viewport);
    expect(anchor, isNotNull);
    expect(beforeIds, contains(anchor!.eventId));
    await timeline.showEarlierWindow(retainEventId: anchor.eventId);
    await tester.pump();
    final afterIds = timeline.messages.map((row) => row.id).toList();
    expect(afterIds, hasLength(200));
    expect(afterIds.first, isNot(beforeOldest),
        reason: 'earlier-window selection must move the oldest boundary');
    expect(afterIds, isNot(orderedEquals(beforeIds)));
    expect(afterIds.toSet().intersection(beforeIds.toSet()),
        contains(anchor.eventId));
    expect(timeline.indexOf(anchor.eventId), isNotNull);
    expect(tester.getTopLeft(find.byKey(keys[anchor.eventId]!)).dy,
        closeTo(anchor.globalY, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'native held local read retires before a fresh room lease reopens',
      (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.close);
    await fixture.open();
    final scroll = ScrollController();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    });
    fixture.database.optionalRelease.complete();
    final oldLease = await fixture.lease();
    fixture.database.holdRead = Completer<void>();
    fixture.database.readEntered = Completer<void>();
    var oldPublished = false;
    Object? oldError;
    final oldRead =
        oldLease.openRoomTimeline(onUpdate: () {}).then<void>((value) {
      oldPublished = true;
      value.dispose();
    }, onError: (Object error, StackTrace _) {
      oldError = error;
    });
    fixture.operations.add(oldRead);
    await fixture.database.readEntered!.future
        .timeout(const Duration(seconds: 10));
    final retiring = oldLease.cancel();
    fixture.database.holdRead!.complete();
    await oldRead;
    await retiring;
    expect(oldPublished, isFalse);
    expect(oldError, isA<StateError>());
    fixture.database.holdRead = null;
    final freshLease = await fixture.lease();
    final fresh = await fixture.timeline(freshLease);
    await tester.pumpWidget(_View(fresh, scroll, {}, GlobalKey()));
    await _until(
        tester,
        () => find.text('Native cached row 0').evaluate().isNotEmpty,
        'fresh lease cached row');
    expect(fresh.messages.length, Room.defaultHistoryCount);
    expect(oldLease.canceled, isTrue);
    expect(freshLease.canceled, isFalse);
    expect(tester.takeException(), isNull);
  });
}
