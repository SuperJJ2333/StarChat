import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_bootstrap_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/cached_direct_room_directory.dart';
import 'package:liuhetong_mobile/features/matrix/direct_chat_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('registration does not wait for stale refresh or let it overwrite room',
      () async {
    final upstream = _Directory();
    final directory =
        CachedDirectRoomDirectory(accountId: '@a:server', upstream: upstream);
    expect(await directory.canonicalRoomId('peer'), '!old');
    final lookup = Completer<String?>();
    upstream.lookup = lookup;
    expect(await directory.canonicalRoomId('peer'), '!old');
    expect(
        await directory
            .registerRoom('peer', '!new')
            .timeout(const Duration(seconds: 1)),
        '!new');
    lookup.complete('!obsolete');
    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('canonical-room-v1:%40a%3Aserver:peer'), '!new');
  });

  test('verified cached session is authenticated before delayed Matrix sync',
      () async {
    final sync = Completer<void>();
    final matrix = _Matrix(() => sync.future);
    final controller =
        SessionBootstrapController(business: _Business(), matrix: matrix);
    final bootstrap = controller.bootstrap();
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.status, SessionBootstrapStatus.authenticated);
    sync.complete();
    await bootstrap;
  });

  test('late successful sync cannot restore session after logout', () async {
    final sync = Completer<void>();
    final matrix = _Matrix(() => sync.future);
    final controller =
        SessionBootstrapController(business: _Business(), matrix: matrix);
    final bootstrap = controller.bootstrap();
    await Future<void>.delayed(Duration.zero);
    await controller.logout();
    sync.complete();
    await bootstrap;
    expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
    expect(controller.canShowCachedMessages, isFalse);
    expect(matrix.resets, 0);
  });

  test('obsolete invalid-token cleanup cannot reset a newly restored session',
      () async {
    final oldLogout = Completer<void>();
    final cleanupStarted = Completer<void>();
    var logoutCalls = 0;
    var syncCalls = 0;
    final business = _Business(logoutCallback: () async {
      if (++logoutCalls == 1) {
        cleanupStarted.complete();
        await oldLogout.future;
      }
    });
    final matrix = _Matrix(() async {
      if (++syncCalls == 1) {
        throw MatrixException.fromJson(
            {'errcode': 'M_UNKNOWN_TOKEN', 'error': 'expired'});
      }
    });
    final controller =
        SessionBootstrapController(business: business, matrix: matrix);
    final oldBootstrap = controller.bootstrap();
    await cleanupStarted.future;
    await controller.logout();
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.authenticated);
    oldLogout.complete();
    await oldBootstrap;
    expect(matrix.resets, 0,
        reason: 'Older cleanup must not reset new session database');
    expect(controller.state.status, SessionBootstrapStatus.authenticated);
  });
}

final class _Directory implements CanonicalDirectRoomDirectory {
  Completer<String?>? lookup;
  @override
  Future<String?> canonicalRoomId(String peerUserId) async =>
      lookup == null ? '!old' : await lookup!.future;
  @override
  Future<String?> registerRoom(String peerUserId, String roomId) async =>
      roomId;
}

final class _Business implements BusinessSessionGateway {
  _Business({this.logoutCallback});
  final Future<void> Function()? logoutCallback;
  @override
  Future<String?> currentMatrixUserId() async => '@a:server';
  @override
  Future<BusinessSessionRestore> restoreSession() async =>
      BusinessSessionRestore.authenticated;
  @override
  Future<void> logout() async {
    await logoutCallback?.call();
  }
}

final class _Matrix implements MatrixSessionGateway {
  _Matrix(this.syncCallback);
  final Future<void> Function() syncCallback;
  int resets = 0;
  @override
  bool get isLoggedIn => true;
  @override
  String? get userId => '@a:server';
  @override
  String? get deviceId => 'DEVICE';
  @override
  Future<void> sync() => syncCallback();
  @override
  Future<void> suspend() async {}
  @override
  Future<void> resetLocalStore() async {
    resets++;
  }
}
