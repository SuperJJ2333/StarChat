import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';
import 'package:liuhetong_mobile/core/business_phone_contracts.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart';
import 'login_controller_test.dart'
    show FakeDualDomainBusiness, FakeMatrixTokenLogin;
import 'retained_account_login_test.dart' show RetainedMatrix;

class PhoneBusiness implements DualDomainBusinessGateway, PhoneAuthGateway {
  final delegate = FakeDualDomainBusiness();
  int phoneLogins = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<Map<String, dynamic>> phoneLogin(
      {required String phone,
      required String code,
      required String deviceKey,
      required String deviceName}) async {
    phoneLogins++;
    return {};
  }

  @override
  Future<String?> currentMatrixUserId() => delegate.currentMatrixUserId();
  @override
  Future<MatrixLoginGrant> issueMatrixLoginToken() =>
      delegate.issueMatrixLoginToken();
  @override
  Future<void> bindMatrixUserId(String id) => delegate.bindMatrixUserId(id);
  @override
  Future<void> logoutBusiness() => delegate.logoutBusiness();
}

void main() {
  test('phone login shares retained Matrix selection and completion', () async {
    final business = PhoneBusiness();
    final matrix = RetainedMatrix();
    var completions = 0;
    final service = DualDomainLoginService(
        business: business,
        matrix: matrix,
        deviceKey: () => 'installation',
        retainedHomeserver: Uri.parse('https://matrix.example.test'),
        completeMatrixSession: () async {
          completions++;
        });
    await service.loginPhone('13800000001', '123456');
    expect(business.phoneLogins, 1);
    expect(business.delegate.loginPasswords, isEmpty);
    expect(matrix.deletes, 0);
    expect(completions, 1);
    expect(matrix.history['@bob:matrix.example.test'], ['old-bob']);
  });
  test('phone login keeps explicit switch requirement and cancellation',
      () async {
    final business = PhoneBusiness();
    final matrix = FakeMatrixTokenLogin(isLoggedIn: true)
      ..userId = '@bob:matrix.example.test';
    final service = DualDomainLoginService(
        business: business, matrix: matrix, deviceKey: () => 'installation');
    await expectLater(service.loginPhone('13800000001', '123456'),
        throwsA(isA<MatrixAccountSwitchRequired>()));
    await service.cancelAccountSwitch();
    expect(business.delegate.logouts, 1);
    expect(matrix.clears, 0);
  });
}
