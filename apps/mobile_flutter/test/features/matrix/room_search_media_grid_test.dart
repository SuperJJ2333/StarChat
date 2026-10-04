import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/media_index.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';
import 'package:liuhetong_mobile/features/matrix/profile_repository.dart';
import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'package:liuhetong_mobile/ui/chat/room_image_gallery.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_video_message.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'profile_repository_test.dart' show MemoryProfileStore;

final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');

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
  _Client(this.store, http.Client transport, this.scope)
      : super('search-media-ui', httpClient: transport) {
    homeserver = Uri.parse('https://matrix.test');
    accessToken = 'synthetic';
  }
  final MatrixSdkDatabase store;
  final String scope;
  late final room = _Room(this);
  @override
  String get userID => '@self-$scope:matrix.test';
  @override
  String get deviceID => 'SYNTHETIC';
  @override
  DatabaseApi get database => store;
  @override
  Room? getRoomById(String id) => id == room.id ? room : null;
  @override
  List<Room> get rooms => [room];
  @override
  Future<bool> authenticatedMediaSupported() async => true;
}

class _Room extends Room {
  _Room(_Client client)
      : super(id: '!search-media-${client.scope}:matrix.test', client: client);
  final lookupIds = <String>[];
  final live = <Event>[];
  Completer<void>? lookupGate;
  bool foreignResult = false;
  int lookupFailures = 0;
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
  Future<Timeline> getTimeline(
          {void Function(int)? onChange,
          void Function(int)? onRemove,
          void Function(int)? onInsert,
          void Function()? onNewEvent,
          void Function()? onUpdate,
          String? eventContextId}) async =>
      _Timeline(live);
  @override
  Future<Event?> getEventById(String id) async {
    lookupIds.add(id);
    if (lookupFailures > 0) {
      lookupFailures--;
      throw StateError('temporary SDK lookup unavailable');
    }
    await lookupGate?.future;
    final event = await super.getEventById(id);
    return foreignResult && event != null
        ? Event.fromJson(
            event.toJson(), Room(id: '!foreign:matrix.test', client: client))
        : event;
  }
}

class _Timeline extends Fake implements Timeline {
  _Timeline(this.events);
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

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

// Shared encrypted preview persistence serializes writes in the caller zone.
// Keep these real-I/O scenarios in one widget-test zone and give each an
// independent synthetic account, room, database, and media directory.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  testWidgets(
      'RoomPage current and old media decode and open; late and foreign results are rejected',
      (tester) async {
    for (final scenario in [
      'current image',
      'old image',
      'old video',
      'late hidden',
      'late disposed',
      'foreign source',
      'retry image',
      'visible grid',
      'late revoked',
      'flash excluded'
    ]) {
      const selected = String.fromEnvironment('SEARCH_MEDIA_SCENARIO');
      if (selected.isNotEmpty && selected != scenario) continue;
      debugPrint('Scenario: $scenario');
      final kind = scenario == 'old video' ? 'video' : 'image';
      final current = scenario == 'current image';
      final late = scenario.startsWith('late');

      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      clearMediaMemoryCaches();
      final downloads = <String>[];
      late Directory directory;
      late MatrixSdkDatabase db;
      late _Client client;
      await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(_png);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 1);
        frame.image.dispose();
        codec.dispose();
        final artifacts = await Directory(
                '../../docs/verification/artifacts/2026-10-04/search-media-grid-followup')
            .create(recursive: true);
        directory = await artifacts.createTemp('widget-');
        PathProviderPlatform.instance = _Paths(directory.absolute.path);
        MediaIndex.overrideShared(MediaIndex(
            databasePath: '${directory.absolute.path}/index.db',
            factory: databaseFactoryFfiNoIsolate));
        final raw = await databaseFactoryFfiNoIsolate
            .openDatabase(inMemoryDatabasePath);
        db = MatrixSdkDatabase('search-media-ui',
            database: raw, sqfliteFactory: databaseFactoryFfiNoIsolate);
        await db.open();
        client = _Client(db, MockClient((request) async {
          if (request.url.path.endsWith('/versions')) {
            return http.Response('{"versions":["v1.1","v1.2"]}', 200);
          }
          if (request.url.path.endsWith('/createRoom')) {
            return http.Response(
                '{"errcode":"M_FORBIDDEN","error":"synthetic fixture"}', 403);
          }
          if (!request.url.path.contains('/download/')) {
            return http.Response('{"chunk":[],"events":[]}', 200);
          }
          downloads.add(request.url.path);
          return http.Response.bytes(_png, 200,
              headers: {'content-type': 'image/png'});
        }), scenario.replaceAll(' ', '-'));
        await db.storeEventUpdate(
            EventUpdate(
                roomID: client.room.id,
                type: EventUpdateType.timeline,
                content: {
                  'event_id': '\$old-$kind',
                  'sender': '@peer:matrix.test',
                  'origin_server_ts': DateTime.now()
                      .subtract(Duration(days: current ? 0 : 5))
                      .millisecondsSinceEpoch,
                  'type': EventTypes.Message,
                  'content': {
                    'msgtype': 'm.$kind',
                    if (scenario == 'flash excluded') 'flash': 1,
                    'body': 'old.$kind',
                    'url': 'mxc://matrix.test/$kind-body',
                    'info': {
                      'mimetype': kind == 'video' ? 'video/mp4' : 'image/png',
                      'thumbnail_url': 'mxc://matrix.test/$kind-thumbnail',
                      'thumbnail_info': {
                        'mimetype': 'image/png',
                        'w': 1,
                        'h': 1
                      },
                      'w': 1,
                      'h': 1
                    }
                  }
                }),
            client);
        if (current) {
          client.room.live
              .add((await client.room.getEventById('\$old-$kind'))!);
          client.room.live.add(Event.fromJson({
            ...client.room.live.single.toJson(),
            'event_id': '\$current-neighbor'
          }, client.room));
          client.room.lookupIds.clear();
        }
        if (scenario == 'visible grid') {
          final event = (await client.room.getEventById('\$old-$kind'))!;
          for (var i = 0; i < 80; i++) {
            await db.storeEventUpdate(
                EventUpdate(
                    roomID: client.room.id,
                    type: EventUpdateType.timeline,
                    content: {...event.toJson(), 'event_id': '\$grid-$i'}),
                client);
          }
          client.room.lookupIds.clear();
        }
        if (late || scenario == 'visible grid') {
          client.room.lookupGate = Completer<void>();
        }
        if (scenario == 'retry image') client.room.lookupFailures = 1;
        client.room.foreignResult = scenario == 'foreign source';
      });
      final owner = MatrixSdkE2eeClient(client,
          homeserver: client.homeserver!,
          readContinuityMetadata: (_) async => MatrixClientContinuityMetadata(
              isLoggedIn: true,
              userId: client.userID,
              deviceId: client.deviceID,
              ed25519Fingerprint: 'synthetic',
              databaseGeneration: 'synthetic'));
      final lease = await owner.openRoomLease(client.room.id);
      Future<void>? cancellation;
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
                roomName: 'Search media fixture',
                onCreateGroup: () {})));
        await _settle(tester);
        final dynamic page = tester.state(find.byType(RoomPage));
        expect(page.controller, isNotNull);
        expect(page.errorMessage, isNull);
        final initialWindow = page.controller.messages
            .map((dynamic message) => message.id)
            .toList();
        await tester.tap(find.byKey(const Key('chat-details')));
        await _settle(tester);
        await tester.tap(find.text('查找聊天记录'));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('chat-search-filter-media')));
        await _settle(tester);
        final tile = find.byKey(Key('category-media-\$old-$kind'));
        if (scenario == 'flash excluded') {
          expect(tile, findsNothing);
          expect(downloads, isEmpty);
          continue;
        }
        if (scenario == 'visible grid') {
          final grid = find.byKey(const Key('chat-search-media-grid'));
          Finder tiles() => find.byWidgetPredicate((w) =>
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith('category-media-'));
          Set<String> tileIds() => tester
              .widgetList(tiles())
              .map((w) => (w.key as ValueKey<String>)
                  .value
                  .substring('category-media-'.length))
              .toSet();
          expect(client.room.lookupIds.length, 4);
          final held = client.room.lookupIds.toSet();
          final original = tileIds();
          expect(original.length, lessThan(40));
          // A tap is an independent consumer: its queued read must survive
          // the originating tile being disposed by this same-open scroll.
          final tapped = original.firstWhere((id) =>
              !held.contains(id) &&
              find
                  .byKey(Key('category-media-$id'))
                  .hitTestable()
                  .evaluate()
                  .isNotEmpty);
          await tester.tap(find.byKey(Key('category-media-$tapped')));
          await tester.pump();
          await tester.drag(grid, const Offset(0, -2200));
          await _settle(tester);
          final current = tileIds();
          final abandoned = original.difference(current).difference(held)
            ..remove(tapped);
          expect(abandoned, isNotEmpty);
          expect(current.contains(tapped), isFalse);
          expect(grid, findsOneWidget);
          expect(lease.canceled, isFalse);
          expect(client.room.lookupIds.length, 4);
          client.room.lookupGate!.complete();
          await _settle(tester);
          expect(client.room.lookupIds.toSet().intersection(abandoned), isEmpty,
              reason:
                  'Disposed queued tiles must not start SDK reads while the search remains open');
          expect(client.room.lookupIds.where((id) => id == tapped).length, 1,
              reason:
                  'The active tap retains exactly one shared metadata read');
          expect(
              client.room.lookupIds.toSet().intersection(current), isNotEmpty);
          expect(find.byType(RoomImageGalleryPage), findsOneWidget);
          expect(client.room.live, isEmpty);
          continue;
        }
        expect(tile, findsOneWidget, reason: scenario);
        if (late) {
          expect(client.room.lookupIds, contains('\$old-$kind'));
          await tester.tap(tile);
          await tester.pump();
          expect(client.room.lookupIds.length, 1,
              reason: 'Tap shares the pending thumbnail lookup');
          if (scenario == 'late revoked') {
            cancellation = lease.cancel();
            await tester.pump();
            expect(lease.canceled, isTrue);
          } else if (scenario == 'late hidden') {
            await page.hiddenEvents.hide(client.room.id, '\$old-$kind');
          } else {
            tester
                .state<NavigatorState>(find.byType(Navigator).first)
                .popUntil((route) => route.isFirst);
          }
          client.room.lookupGate!.complete();
          await _settle(tester);
          expect(downloads, isEmpty);
          expect(find.byType(RoomImageGalleryPage), findsNothing);
          continue;
        }
        if (scenario == 'foreign source') {
          await _settle(tester);
          expect(downloads, isEmpty);
          await tester.tap(tile);
          await _settle(tester);
          expect(find.byType(RoomImageGalleryPage), findsNothing);
          continue;
        }
        if (scenario == 'retry image') {
          expect(client.room.lookupIds.length, 1);
          expect(downloads, isEmpty);
          final retry =
              find.descendant(of: tile, matching: find.byType(CupertinoButton));
          expect(retry, findsOneWidget);
          await tester.tap(retry);
          await _settle(tester);
          expect(client.room.lookupIds.length, 2);
        }
        for (var attempt = 0;
            attempt < 100 &&
                !tester
                    .widgetList<RawImage>(find.descendant(
                        of: tile, matching: find.byType(RawImage)))
                    .any((raw) => raw.image != null);
            attempt++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)));
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(find.descendant(of: tile, matching: find.byType(RawImage)),
            findsOneWidget,
            reason:
                'The actual RoomPage media builder must load and decode the old thumbnail.');
        final decoded = tester
            .widget<RawImage>(
                find.descendant(of: tile, matching: find.byType(RawImage)))
            .image;
        expect(decoded, isNotNull,
            reason: 'PNG bytes must reach the engine decoder');
        expect(decoded!.width, 1);
        expect(decoded.height, 1);
        if (!current) expect(client.room.lookupIds, contains('\$old-$kind'));
        expect(
            page.controller.messages
                .map((dynamic message) => message.id)
                .toList(),
            initialWindow);
        expect(downloads.where((p) => p.endsWith('$kind-thumbnail')).length, 1);
        if (kind == 'video') {
          expect(downloads.any((p) => p.endsWith('video-body')), isFalse);
        }
        expect(client.room.live.length, current ? 2 : 0);
        await tester.tap(tile);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await _settle(tester);
        expect(
            find.byType(
                kind == 'image' ? RoomImageGalleryPage : VideoViewerPage),
            findsOneWidget);
        if (kind == 'image') {
          final gallery = tester
              .widget<RoomImageGalleryPage>(find.byType(RoomImageGalleryPage));
          expect(gallery.images.length, current ? 2 : 1);
          if (current) {
            expect(gallery.images.map((image) => image.id),
                contains('\$current-neighbor'));
          }
        }
        expect(client.room.live.length, current ? 2 : 0);
      } finally {
        if (client.room.lookupGate?.isCompleted == false) {
          client.room.lookupGate!.complete();
        }
        tester
            .state<NavigatorState>(find.byType(Navigator).first)
            .popUntil((route) => route.isFirst);
        await _settle(tester);
        await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
        await _settle(tester);
        await tester.runAsync(() => cancellation ?? lease.cancel());
        await tester.runAsync(() async {
          await MediaIndex.shared.close();
          MediaIndex.overrideShared(null);
          await db.close();
          await directory.delete(recursive: true);
        });
      }
    }
  });
}
