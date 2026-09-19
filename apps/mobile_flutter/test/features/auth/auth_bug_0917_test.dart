import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/legal_document_page.dart';
import 'package:liuhetong_mobile/features/auth/legal_documents.dart';
import 'package:liuhetong_mobile/features/auth/login_page.dart';
import 'package:liuhetong_mobile/features/auth/registration_controller.dart';
import 'package:liuhetong_mobile/features/auth/registration_page.dart';

/// BUG-01：邀请码无效时只出现一次提示。
final class _InvalidInvitationGateway implements RegistrationGateway {
  @override
  Future<InvitationValidationResult> validateInvitation(String code) async =>
      const InvitationValidationResult(
          InvitationValidationState.invalid, '邀请码无效');

  @override
  Future<RegistrationReceipt> register({
    required String username,
    String? nickname,
    required String email,
    required String password,
    required String invitationCode,
  }) async =>
      throw StateError('register must not be called for an invalid invitation');

  @override
  Future<int> resendVerification(String registrationSession) async => 60;

  @override
  Future<int> changeRegistrationEmail({
    required String registrationSession,
    required String email,
  }) async =>
      60;

  @override
  Future<RegistrationStatusReceipt> registrationStatus(
          String registrationSession) async =>
      const RegistrationStatusReceipt(status: 'ACTIVE', resendAfterSeconds: 0);

  @override
  Future<void> verifyEmail(
      {required String registrationSession,
      String? code,
      String? token}) async {}
}

String _documentText(LegalDocument document) => [
      document.introduction,
      for (final section in document.sections) ...[
        section.title,
        ...section.paragraphs,
      ],
    ].join('\n');

Future<void> _fillValidForm(WidgetTester tester) async {
  final fields = find.byType(CupertinoTextField);
  await tester.enterText(fields.at(0), 'Alice');
  await tester.enterText(fields.at(1), 'alice');
  await tester.enterText(fields.at(2), 'correct horse battery staple');
  await tester.enterText(fields.at(3), 'correct horse battery staple');
  await tester.enterText(fields.at(4), 'BAD-CODE');
  await tester.enterText(fields.at(5), 'alice@example.test');
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
      'BUG-01 wrong invitation code shows exactly one error message',
      (tester) async {
    final controller =
        RegistrationController(gateway: _InvalidInvitationGateway());
    addTearDown(controller.dispose);
    await tester.pumpWidget(CupertinoApp(
      home: RegistrationPage(
          controller: controller, onVerification: (_) {}, onBack: () {}),
    ));

    await _fillValidForm(tester);
    // 防抖校验完成：内联状态行给出一条提示。
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('邀请码无效'), findsOneWidget);

    // 提交后 controller 也给出了 invitation_code 字段错误：
    // 内联状态行让位，仍然只有一条提示。
    final send = find.byKey(const Key('auth-registration-send-code'));
    tester.widget<CupertinoButton>(send).onPressed!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('邀请码无效'), findsOneWidget);
    expect(find.byKey(const Key('auth-invitation-status')), findsNothing);
    expect(find.byKey(const Key('auth-registration-error-invitation_code')),
        findsOneWidget);

    // 重新编辑邀请码：旧的字段错误失效，恢复由内联状态行展示。
    await tester.enterText(find.byType(CupertinoTextField).at(4), 'BAD-CODE2');
    await tester.pump();
    expect(
        controller.state.fieldErrors.containsKey('invitation_code'), isFalse);
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('邀请码无效'), findsOneWidget);
  });

  testWidgets('BUG-02 login page opens the user agreement and privacy policy',
      (tester) async {
    final api = BusinessApiClient(
      baseUri: Uri.parse('http://localhost'),
      sessionStore: SecureSessionStore(),
    );
    await tester.pumpWidget(CupertinoApp(
      home: LoginPage(api: api, onLogin: (_, __) async {}),
    ));

    await tester.tap(find.byKey(const Key('auth-user-agreement-link')));
    await tester.pumpAndSettle();
    expect(find.byType(LegalDocumentPage), findsOneWidget);
    expect(
        find.byKey(const Key('legal-document-user-agreement')), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('auth-privacy-policy-link')));
    await tester.pumpAndSettle();
    expect(find.byType(LegalDocumentPage), findsOneWidget);
    expect(
        find.byKey(const Key('legal-document-privacy-policy')), findsOneWidget);
  });

  test('BUG-02 both documents carry real, non-empty bodies', () {
    expect(_documentText(userAgreement), contains('端到端加密'));
    expect(_documentText(privacyPolicy), contains('端到端加密'));
    expect(_documentText(privacyPolicy), contains('个推'));
  });
}
