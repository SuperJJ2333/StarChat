import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';
import 'package:liuhetong_mobile/core/session_bootstrap_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_security_logger.dart';

/// 可控心跳网关：按队列返回成功/失败，驱动离线胶囊恢复测试。
final class HeartbeatBusiness
    implements BusinessSessionGateway, BusinessSessionMonitor {
  HeartbeatBusiness({required this.restoreResults, required this.heartbeats});

  final List<Object?> restoreResults;
  final List<Object?> heartbeats;

  @override
  Future<String?> currentMatrixUserId() async => '@u:t';

  @override
  Future<BusinessSessionRevocation?> clearLocalSession() async => null;

  @override
  Future<BusinessSessionRestore> restoreSession() async {
    if (restoreResults.isEmpty) {
      return BusinessSessionRestore.authenticated;
    }
    final next = restoreResults.removeAt(0);
    if (next != null) throw next;
    return BusinessSessionRestore.authenticated;
  }

  @override
  Future<void> checkSessionValidity() async {
    if (heartbeats.isEmpty) return;
    final next = heartbeats.removeAt(0);
    if (next != null) throw next;
  }

  @override
  Stream<BusinessSessionInvalidation> get sessionInvalidations =>
      const Stream.empty();

  @override
  int get sessionEpoch => 0;
}

final class _StubMatrix implements MatrixSessionGateway {
  @override
  bool get isLoggedIn => true;
  @override
  String? get userId => '@u:t';
  @override
  String? get deviceId => 'D';
  @override
  Future<void> suspend() async {}
  @override
  Future<void> clearLocalChatData() async {}
  @override
  Future<void> sync() async {}
}

void main() {
  test('心跳成功后离线认证态恢复为正常认证态（顶部胶囊消失）', () async {
    final business = HeartbeatBusiness(
      restoreResults: [const SocketException('offline at boot')],
      heartbeats: [],
    );
    final controller = SessionBootstrapController(
      business: business,
      matrix: _StubMatrix(),
      securityLogger: MatrixSecurityLogger.create(sink: (_) {}),
    );
    await controller.bootstrap();
    expect(controller.state.status, SessionBootstrapStatus.offlineAuthenticated);

    // 网络恢复：下一次会话心跳成功 → 胶囊应立即消失。
    await controller.checkSessionValidity();
    expect(controller.state.status, SessionBootstrapStatus.authenticated);
    controller.dispose();
  });

  test('心跳仍失败时保持离线认证态（不闪断）', () async {
    final business = HeartbeatBusiness(
      restoreResults: [const SocketException('offline at boot')],
      heartbeats: [Exception('still down')],
    );
    final controller = SessionBootstrapController(
      business: business,
      matrix: _StubMatrix(),
      securityLogger: MatrixSecurityLogger.create(sink: (_) {}),
    );
    await controller.bootstrap();
    await controller.checkSessionValidity();
    expect(controller.state.status, SessionBootstrapStatus.offlineAuthenticated);
    controller.dispose();
  });
}
