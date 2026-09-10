import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart';
import 'login_controller_test.dart' show FakeDualDomainBusiness;

class RetainedMatrix
    implements MatrixTokenLoginGateway, MatrixAccountSelectionGateway {
  void Function()? onSelect;
  final history = <String, List<String>>{
    '@bob:matrix.example.test': ['old-bob']
  };
  final selected = <String>[];
  @override
  bool isLoggedIn = true;
  @override
  bool credentialsInvalid = false;
  @override
  String? userId = '@bob:matrix.example.test';
  @override
  String? deviceId = 'bob-device';
  int deletes = 0;
  @override
  Future<void> selectAccount(String id, Uri server) async {
    onSelect?.call();
    selected.add(id);
    userId = id;
    isLoggedIn = false;
    deviceId = null;
  }

  @override
  Future<void> clearLocalChatData() async {
    deletes++;
    history.clear();
  }

  @override
  Future<void> suspend() async {}
  @override
  Future<void> sync() async {
    history.putIfAbsent(userId!, () => []).add('offline-sync');
  }

  @override
  Future<void> loginWithToken(
      {required String loginToken,
      required Uri homeserver,
      String? deviceId}) async {
    isLoggedIn = true;
    userId = '@alice:matrix.example.test';
    this.deviceId = 'alice-device';
  }
}

void main() {
  test('new business login reauthenticates even a valid retained Matrix token',
      () async {
    final business = FakeDualDomainBusiness();
    final matrix = RetainedMatrix()..userId = '@alice:matrix.example.test';
    var completions = 0;
    final service = DualDomainLoginService(
        business: business,
        matrix: matrix,
        deviceKey: () => 'installation',
        retainedHomeserver: Uri.parse('https://matrix.example.test'),
        completeMatrixSession: () async {
          completions++;
          expect(business.tokenRequests, 1);
        });
    await service.login('alice', 'password');
    expect(completions, 1);
    expect(matrix.deletes, 0);
  });
  test('account reopen delay renews expired one-time grant', () async {
    var clock = DateTime.utc(2026, 9, 10);
    final business = FakeDualDomainBusiness()..currentIdentity = null;
    final matrix = RetainedMatrix()
      ..onSelect = () {
        clock = clock.add(const Duration(minutes: 2));
      };
    final service = DualDomainLoginService(
        business: business,
        matrix: matrix,
        deviceKey: () => 'installation',
        retainedHomeserver: Uri.parse('https://matrix.example.test'),
        now: () => clock);
    await service.login('alice', 'password');
    expect(business.tokenRequests, 2);
    expect(matrix.deletes, 0);
  });
  test('account switch logs in automatically without deleting old history',
      () async {
    final matrix = RetainedMatrix();
    final service = DualDomainLoginService(
        business: FakeDualDomainBusiness(),
        matrix: matrix,
        deviceKey: () => 'installation',
        retainedHomeserver: Uri.parse('https://matrix.example.test'));
    await service.login('alice', 'password');
    expect(matrix.deletes, 0);
    expect(matrix.history['@bob:matrix.example.test'], ['old-bob']);
    expect(matrix.userId, '@alice:matrix.example.test');
    expect(matrix.history['@alice:matrix.example.test'], ['offline-sync']);
  });
}
