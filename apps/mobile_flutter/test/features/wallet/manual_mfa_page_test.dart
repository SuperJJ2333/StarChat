import 'package:flutter/cupertino.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/wallet/manual_mfa_page.dart';
import 'package:liuhetong_mobile/features/wallet/manual_operation_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

void main() {
  testWidgets(
      'pending setup reauthenticates in place and never persists the proof',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    Map<String, dynamic>? submitted;
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/reauthenticate')) {
        return flow
            .json({'setup_proof': 'memory-only-proof', 'expires_in': 300});
      }
      if (request.url.path.endsWith('/enable')) {
        submitted = jsonDecode(request.body) as Map<String, dynamic>;
        return flow.json({'enabled': true});
      }
      return flow.json({...fixtures.mfa, 'pending_credential_id': 'pending'});
    });
    await tester.pumpWidget(CupertinoApp(home: ManualMfaPage(client: api)));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('manual-mfa-reauth-password')), 'test-password');
    await flow.tap(tester, find.byKey(const Key('manual-mfa-reauth')));
    await tester.enterText(find.byKey(const Key('manual-mfa-code')), '123456');
    await flow.tap(tester, find.text('验证并启用'));
    expect(submitted?['setup_proof'], 'memory-only-proof');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().map(prefs.getString).join(),
        isNot(contains('memory-only-proof')));
  });
  testWidgets(
      'lost enrollment response recovers current user pending identifier from server',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = await flow.client((request) async => flow
        .json({...fixtures.mfa, 'pending_credential_id': 'server-pending'}));
    await tester.pumpWidget(CupertinoApp(home: ManualMfaPage(client: api)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manual-mfa-code')), findsOneWidget);
    expect(find.text('设置身份验证器'), findsNothing);
  });
  testWidgets('MFA enrollment resumes with identifier only after restart',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = await flow.client((request) async => flow.json(fixtures.mfa));
    final store = ManualOperationStore(api);
    await store.initialize();
    await store.begin('mfa', {'id': 'credential'});
    await tester.pumpWidget(CupertinoApp(home: ManualMfaPage(client: api)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manual-mfa-code')), findsOneWidget);
    expect(find.text('取消本次设置'), findsOneWidget);
    expect(find.text('设置身份验证器'), findsNothing);
  });
}
