import 'dart:async';

import 'package:flutter/cupertino.dart' hide Visibility;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/core/notification/app_state_manager.dart';
import 'package:liuhetong_mobile/core/notification/badge_service.dart';
import 'package:liuhetong_mobile/core/notification/foreground_sound_service.dart';
import 'package:liuhetong_mobile/core/notification/haptic_service.dart';
import 'package:liuhetong_mobile/core/notification/in_app_banner_controller.dart';
import 'package:liuhetong_mobile/core/notification/notification_coordinator.dart';
import 'package:liuhetong_mobile/core/notification/notification_preferences.dart';
import 'package:liuhetong_mobile/core/notification/system_notification_presenter.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_read_state.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_notification_event_source.dart';
import 'package:liuhetong_mobile/features/matrix/room_page.dart';

class _Client extends Client {
  _Client() : super('synthetic-room-notification') {
    primary = _Room(this, '!A:local', '@peer:local', 7);
    alias = _Room(this, '!A-old:local', '@peer:local', 3);
    other = _Room(this, '!B:local', '@another:local', 2);
  }
  late final _Room primary, alias, other;
  @override
  String? get userID => '@account:local';
  @override
  List<Room> get rooms => [primary, alias, other];
  @override
  Map<String, dynamic> get directChats => {
        '@peer:local': [primary.id, alias.id],
        '@another:local': [other.id],
      };
  @override
  Room? getRoomById(String id) =>
      rooms.where((room) => room.id == id).firstOrNull;
  @override
  Future<String> createGroupChat({
    String? groupName,
    bool? enableEncryption,
    List<String>? invite,
    CreateRoomPreset preset = CreateRoomPreset.privateChat,
    List<StateEvent>? initialState,
    Visibility? visibility,
    HistoryVisibility? historyVisibility,
    bool waitForSync = true,
    bool groupCall = false,
    bool federated = true,
    Map<String, dynamic>? powerLevelContentOverride,
  }) async =>
      throw StateError('No optional emoji-vault network in fixture');
}

class _Room extends Room {
  _Room(Client client, String id, this.peer, this.unread)
      : super(id: id, client: client);
  final String peer;
  final int unread;
  @override
  bool get isDirectChat => true;
  @override
  String? get directChatMatrixID => peer;
  @override
  Membership get membership => Membership.join;
  @override
  bool get encrypted => true;
  @override
  int get notificationCount => unread;
  @override
  Future<Timeline> getTimeline({
    void Function(int)? onChange,
    void Function(int)? onRemove,
    void Function(int)? onInsert,
    void Function()? onNewEvent,
    void Function()? onUpdate,
    String? eventContextId,
  }) async =>
      _Timeline();
}

class _Timeline extends Fake implements Timeline {
  @override
  List<Event> get events => [];
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
}

class _SecureStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Presenter extends Fake
    implements
        SystemNotificationPresenter,
        DeliveredConversationNotificationPresenter {
  final cancellations = <int>[];
  final delivered = <String>[];
  @override
  Future<void> initialize() async {}
  @override
  Future<void> cancelConversation(int id) async => cancellations.add(id);
  @override
  Future<void> cancelDeliveredConversation(String id) async =>
      delivered.add(id);
}

class _Prefs extends Fake implements NotificationPreferenceStore {
  @override
  Future<NotificationPreferenceValues> load() async =>
      const NotificationPreferenceValues();
}

class _Source implements NotificationEventSource {
  final controller = StreamController<IncomingNotification>.broadcast();
  @override
  Stream<IncomingNotification> get events => controller.stream;
}

class _Sound extends Fake implements SoundEngine {}

class _Haptics extends Fake implements HapticDriver {}

class _Badge implements LauncherBadgeGateway {
  int? count;
  @override
  Future<void> updateCount(int value) async => count = value;
}

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
}

void main() {
  for (final stale in [false, true]) {
    testWidgets(
        stale
            ? 'old room lease cannot open notification scope for a new account'
            : 'actual RoomPage clears its primary and aliases while preserving B',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final reads = ConversationReadState.shared()..resetForTest();
      final client = _Client();
      final owner = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://matrix.invalid'),
          readContinuityMetadata: (c) async => MatrixClientContinuityMetadata(
              isLoggedIn: false,
              userId: c.userID,
              deviceId: c.deviceID,
              ed25519Fingerprint: null,
              databaseGeneration: 'synthetic'));
      final lease = await owner.openRoomLease(client.primary.id);
      reads.bindAccount(stale ? '@new-account:local' : client.userID);
      final presenter = _Presenter(), source = _Source(), badge = _Badge();
      final coordinator = NotificationCoordinator(
          preferenceStore: _Prefs(),
          systemNotifications: presenter,
          soundService: ForegroundSoundService(engine: _Sound()),
          hapticService: HapticService(driver: _Haptics()),
          badgeGateway: badge,
          appState: AppStateManager(),
          banners: InAppBannerController(),
          eventSource: source,
          unreadSource: MatrixUnreadSnapshotSource(client: client));
      await coordinator.start();
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://business.invalid'),
          sessionStore: SecureSessionStore(_SecureStore()),
          client: MockClient((_) async => http.Response('{}', 404)));
      await tester.pumpWidget(CupertinoApp(
          home: RoomPage(
              api: api,
              roomLease: lease,
              roomName: 'Synthetic',
              onCreateGroup: () {})));
      await tester.pump(const Duration(milliseconds: 200));
      await _drain(tester);
      if (stale) {
        expect(reads.openRoomIds, isEmpty);
        expect(presenter.delivered, isEmpty);
      } else {
        expect(reads.openRoomIds, {client.primary.id, client.alias.id});
        expect(
            presenter.delivered.toSet(), {client.primary.id, client.alias.id});
        expect(
            presenter.cancellations,
            containsAll([
              notificationIdForConversation(client.primary.id),
              notificationIdForConversation(client.alias.id)
            ]));
        expect(presenter.cancellations,
            isNot(contains(notificationIdForConversation(client.other.id))));
        expect(badge.count, 2);
      }
      await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
      await _drain(tester);
      final disposal = coordinator.dispose();
      await _drain(tester);
      await disposal;
      final closing = source.controller.close();
      await _drain(tester);
      await closing;
      await lease.cancel();
      await client.dispose();
      reads.resetForTest();
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
}
