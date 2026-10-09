import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/media_index.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/timeline_scroll_anchor.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'profile_repository_test.dart' show MemoryProfileStore;

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _Client extends Client {
  _Client(this.store, http.Client transport)
      : super('search-context-ui', httpClient: transport) {
    homeserver = Uri.parse('https://matrix.test');
    accessToken = 'synthetic';
  }
  final MatrixSdkDatabase store;
  late final room = _Room(this);
  @override
  String get userID => '@self:matrix.test';
  @override
  String get deviceID => 'SYNTHETIC';
  @override
  DatabaseApi get database => store;
  @override
  Room? getRoomById(String id) => id == room.id ? room : null;
  @override
  List<Room> get rooms => [room];
}

class _Room extends Room {
  _Room(_Client client) : super(id: '!context:matrix.test', client: client);
  final live = <Event>[];
  @override
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) =>
      eventContextId == null
          ? Future.value(_LiveTimeline(live))
          : super
              .getTimeline(onUpdate: onUpdate, eventContextId: eventContextId);
  Completer<void>? localGate;
  var localEntered = Completer<void>();
  @override
  bool get isDirectChat => false;
  @override
  Membership get membership => Membership.join;
  @override
  Future<List<User>> requestParticipants(
          [List<Membership> membershipFilter = const [
            Membership.join,
            Membership.invite,
            Membership.knock
          ],
          bool suppressWarning = false,
          bool cache = true]) async =>
      [];
  @override
  Future<Event?> getLocalEventById(String id,
      {bool Function()? shouldContinue}) async {
    if (id == r'$old-anchor') {
      if (!localEntered.isCompleted) localEntered.complete();
      await localGate?.future;
    }
    return super.getLocalEventById(id, shouldContinue: shouldContinue);
  }
}

class _LiveTimeline extends Fake implements Timeline {
  _LiveTimeline(this.events);
  @override
  final List<Event> events;
  @override
  bool get isFragmentedTimeline => false;
  @override
  bool get canRequestHistory => false;
  @override
  bool get canRequestFuture => false;
  @override
  Future<void> setReadMarker({String? eventId, bool? public}) async {}
  @override
  void cancelSubscriptions() {}
  @override
  void trimLiveHistory({int maximumEvents = 1000}) {}
}

Map<String, dynamic> _event(String id, DateTime time, String body) => {
      'event_id': id,
      'sender': '@peer:matrix.test',
      'origin_server_ts': time.millisecondsSinceEpoch,
      'type': EventTypes.Message,
      'content': {'msgtype': MessageTypes.Text, 'body': body},
    };

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  testWidgets(
      'RoomPage date and keyword jumps retain context and route ownership',
      (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final dateJump in [true, false]) {
      const selected = String.fromEnvironment('CONTEXT_SCENARIO');
      if (selected.isNotEmpty && selected != (dateJump ? 'date' : 'keyword')) {
        continue;
      }
      debugPrint('Scenario: ${dateJump ? "date" : "keyword"}');
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final now = DateTime.now();
      final old = now.subtract(const Duration(days: 10));
      final anchor = _event(r'$old-anchor', old, 'needle old anchor');
      final requests = <Uri>[];
      late Directory directory;
      late MatrixSdkDatabase db;
      late _Client client;
      await tester.runAsync(() async {
        final artifacts = await Directory(
                '../../docs/verification/artifacts/2026-10-04/search-date-context-followup')
            .create(recursive: true);
        directory = await artifacts.createTemp('context-ui-');
        PathProviderPlatform.instance = _Paths(directory.absolute.path);
        MediaIndex.overrideShared(MediaIndex(
            databasePath: '${directory.path}/index.db',
            factory: databaseFactoryFfiNoIsolate));
        final raw = await databaseFactoryFfiNoIsolate
            .openDatabase(inMemoryDatabasePath);
        db = MatrixSdkDatabase('context-ui',
            database: raw, sqfliteFactory: databaseFactoryFfiNoIsolate);
        await db.open();
        client = _Client(db, MockClient((request) async {
          if (request.url.path.contains('/context/')) {
            requests.add(request.url);
            return http.Response(
                jsonEncode({
                  'start': 'older-token',
                  'end': 'newer-token',
                  'event': anchor,
                  'events_before': [
                    _event(r'$older', old.subtract(const Duration(minutes: 1)),
                        'older neighbor'),
                    for (var i = 2; i <= 15; i++)
                      _event('\$older-$i', old.subtract(Duration(minutes: i)),
                          'older neighbor $i')
                  ],
                  'events_after': [
                    _event(r'$newer', old.add(const Duration(minutes: 1)),
                        'newer neighbor'),
                    for (var i = 2; i <= 15; i++)
                      _event('\$newer-$i', old.add(Duration(minutes: i)),
                          'newer neighbor $i')
                  ],
                }),
                200);
          }
          if (request.url.path.endsWith('/messages')) {
            requests.add(request.url);
            final older = request.url.queryParameters['dir'] == 'b';
            return http.Response(
                jsonEncode({
                  'start': request.url.queryParameters['from'],
                  'end': '',
                  'chunk': [
                    _event(
                        older ? r'$page-older' : r'$page-newer',
                        old.add(Duration(minutes: older ? -16 : 16)),
                        older ? 'older page' : 'newer page')
                  ],
                }),
                200);
          }
          if (request.url.path.endsWith('/createRoom')) {
            return http.Response('{"errcode":"M_FORBIDDEN"}', 403);
          }
          return http.Response('{"chunk":[],"events":[]}', 200);
        }));
        for (final event in [
          anchor,
          for (var i = 0; i < 40; i++)
            _event('\$live-$i', now.add(Duration(seconds: i)),
                'current message $i')
        ]) {
          await db.storeEventUpdate(
              EventUpdate(
                  roomID: client.room.id,
                  type: EventUpdateType.timeline,
                  content: event),
              client);
        }
      });
      client.room.live.add(Event.fromJson(
          _event(r'$live-39', now, 'current message 39'), client.room));
      final owner = MatrixSdkE2eeClient(client,
          homeserver: client.homeserver!,
          readContinuityMetadata: (_) async => MatrixClientContinuityMetadata(
              isLoggedIn: true,
              userId: client.userID,
              deviceId: client.deviceID,
              ed25519Fingerprint: 'synthetic',
              databaseGeneration: 'synthetic'));
      final lease = await owner.openRoomLease(client.room.id);
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://business.test'),
          sessionStore: SecureSessionStore(),
          client: MockClient((_) async => http.Response('{}', 404)));
      try {
        final identities = ProfileRepository.forTesting(
            accountKey: 'matrix:@self:matrix.test',
            store: MemoryProfileStore(),
            loadProfile: () async => const ProfileData(
                username: 'self',
                nickname: 'self',
                maskedEmail: '',
                fallbackSeed: 'self'),
            loadContacts: () async => const []);
        await identities.preload();
        await tester.pumpWidget(CupertinoApp(
            home: RoomPage(
                api: api,
                roomLease: lease,
                initialIdentityCache: identities,
                roomName: 'Context fixture',
                onCreateGroup: () {})));
        await _settle(tester);
        final dynamic page = tester.state(find.byType(RoomPage));
        expect(page.controller, isNotNull);
        expect(page.errorMessage, isNull);
        expect(find.text('current message 39'), findsOneWidget);
        expect(page.controller.indexOf(r'$old-anchor'), isNull);
        await tester.tap(find.byKey(const Key('chat-details')));
        await _settle(tester);
        await tester.tap(find.text('查找聊天记录'));
        await _settle(tester);
        if (dateJump) {
          await tester.tap(find.byKey(const Key('chat-search-filter-date')));
          await _settle(tester);
          if (old.month != now.month || old.year != now.year) {
            await tester.tap(find.byKey(const Key('calendar-prev-month')));
            await _settle(tester);
          }
          final day = find.byKey(Key('calendar-day-${old.day}'));
          expect(tester.widget<GestureDetector>(day).onTap, isNotNull);
          expect(
              lease.localAnchorForDay(DateTime(old.year, old.month, old.day)),
              r'$old-anchor');
          expect(day.hitTestable(), findsOneWidget,
              reason: 'The selected date must receive a real pointer tap');
          client.room.localGate = Completer<void>();
          client.room.localEntered = Completer<void>();
          await tester.tap(find.descendant(
              of: day, matching: find.text(old.day.toString())));
          await _settle(tester);
          expect(client.room.localEntered.isCompleted, isTrue,
              reason:
                  'The room owns the pending local lookup after search closes');
          client.room.localGate!.complete();
          await _settle(tester);
          await tester.pump(const Duration(seconds: 1));
          expect(page.controller.indexOf(r'$old-anchor'), isNotNull,
              reason:
                  'Search route cleanup must not cancel the new room-owned date anchor lookup');
          expect(find.text('未找到该消息，请稍后重试'), findsNothing);
          expect(find.text('needle old anchor'), findsOneWidget);
        } else {
          await tester.enterText(
              find.byType(CupertinoSearchTextField).first, 'needle');
          await _settle(tester);
          await tester
              .tap(find.byKey(const Key(r'chat-search-result-$old-anchor')));
          await _settle(tester);
          await tester.pump(const Duration(seconds: 1));
          expect(find.text('needle old anchor'), findsOneWidget);
          expect(page.controller.messages.map((dynamic m) => m.id),
              containsAll([r'$older', r'$old-anchor', r'$newer']),
              reason:
                  'A persisted search hit must include its valid conversation neighbors');
          expect(requests.where((r) => r.path.contains('/context/')),
              hasLength(1));
          final list = find.byType(AnchoredTimelineList);
          final scroll = tester.widget<AnchoredTimelineList>(list).controller;
          Future<void> dragTimeline(Offset distance) async {
            await tester.drag(list, distance);
            await _settle(tester);
            for (var i = 0;
                i < 300 && scroll.position.isScrollingNotifier.value;
                i++) {
              await tester.pump(const Duration(milliseconds: 16));
            }
            expect(scroll.position.isScrollingNotifier.value, isFalse);
            await _settle(tester);
          }

          for (var i = 0;
              i < 12 &&
                  find.text('older page').hitTestable().evaluate().isEmpty;
              i++) {
            await dragTimeline(const Offset(0, 450));
          }
          expect(find.text('older page').hitTestable(), findsOneWidget,
              reason:
                  'Dragging the actual room timeline must expose the older page');
          for (var i = 0;
              i < 20 &&
                  find.text('newer page').hitTestable().evaluate().isEmpty;
              i++) {
            await dragTimeline(const Offset(0, -450));
          }
          expect(find.text('newer page').hitTestable(), findsOneWidget,
              reason:
                  'Dragging back toward newer history must expose the newer page');
          expect(page.controller.allMessages.map((dynamic m) => m.id),
              containsAll([r'$page-older', r'$page-newer']));
          expect(page.controller.messages.length, lessThanOrEqualTo(160));
          expect(
              requests
                  .where((r) => r.path.endsWith('/messages'))
                  .map((r) => r.queryParameters['from']),
              containsAll(['older-token', 'newer-token']));
        }
        expect(page.controller.newestMessage.id, r'$live-39');
        final Future<void> latest = page.controller.showLatest();
        await _settle(tester);
        await latest;
        await _settle(tester);
        expect(page.controller.messages.last.id, r'$live-39');
      } finally {
        if (client.room.localGate?.isCompleted == false) {
          client.room.localGate!.complete();
        }
        tester
            .state<NavigatorState>(find.byType(Navigator).first)
            .popUntil((route) => route.isFirst);
        await _settle(tester);
        await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
        await _settle(tester);
        await tester.runAsync(() async {
          await lease.cancel();
          await MediaIndex.shared.close();
          MediaIndex.overrideShared(null);
          await db.close();
          await client.dispose();
          await directory.delete(recursive: true);
        });
      }
    }
  });
}
