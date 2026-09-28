import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'account_settings_hot_cache_test.dart' show securityJson, signedInStore;

const changedSecurityJson = '{"masked_email":"b***@example.test",'
    '"masked_phone":"139****0002","email_bound":true,"phone_bound":true,'
    '"email_verified":true,"phone_verified":true}';

void main() {
  for (final step in ['old-request', 'old-confirm', 'new-request', 'confirm']) {
    test('phone $step pins Bearer and sends only once after explicit 401', () async {
      var posts = 0, refreshes = 0;
      final bearers = <String?>[];
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://api.test'),
          sessionStore: await signedInStore(),
          client: MockClient((request) async {
            if (request.url.path.endsWith('/auth/refresh')) {
              refreshes++;
              return http.Response('{"access_token":"refreshed","refresh_token":"r2"}', 200);
            }
            posts++;
            bearers.add(request.headers['authorization']);
            return http.Response('{"error":{"code":"TOKEN_INVALID","message":"expired"}}', 401);
          }));
      final request = switch (step) {
        'old-request' => api.rebindOldRequest(),
        'old-confirm' => api.rebindOldConfirm(code: '123456'),
        'new-request' => api.rebindNewRequest(phone: '13900000002'),
        _ => api.rebindNewConfirm(phone: '13900000002', code: '123456'),
      };
      await expectLater(request, throwsA(isA<BusinessApiException>()));
      expect(posts, 1);
      expect(refreshes, 0);
      expect(bearers, ['Bearer old']);
      expect(api.hasPendingAccountBindingConfirmation, isFalse);
    });
  }
  for (final channel in ['email', 'phone']) {
    for (final successful in [true, false]) {
      testWidgets(
          '$channel uncertain confirmation blocks stale summary until late ${successful ? 'success' : 'failure'}',
          (tester) async {
        var reads = 0, confirms = 0;
        var committed = false;
        final sent = Completer<void>();
        final rawResponse = Completer<http.Response>();
        final api = BusinessApiClient(
            baseUri: Uri.parse('https://api.test'),
            sessionStore: await signedInStore(),
            client: MockClient((request) async {
              if (request.method == 'POST') {
                confirms++;
                sent.complete();
                return rawResponse.future;
              }
              reads++;
              return http.Response(
                  committed ? changedSecurityJson : securityJson, 200);
            }));
        await api.loadAccountSecurity();
        final confirmation = channel == 'email'
            ? api.confirmEmailRebind(email: 'b@example.test', code: '123456')
            : api.rebindNewConfirm(phone: '13900000002', code: '123456');
        final timedOut = expectLater(
            confirmation.timeout(const Duration(seconds: 8)),
            throwsA(isA<TimeoutException>()));
        await sent.future;
        await tester.pump(const Duration(seconds: 9));
        await timedOut;
        expect(api.hasPendingAccountBindingConfirmation, isTrue);
        expect(api.cachedAccountSecurityData, isNull);
        expect(api.accountSecurityCacheIsFresh, isFalse);
        final duplicate = channel == 'email'
            ? api.confirmEmailRebind(email: 'b@example.test', code: '123456')
            : api.rebindNewConfirm(phone: '13900000002', code: '123456');
        await expectLater(
            duplicate,
            throwsA(isA<BusinessApiException>().having((error) => error.code,
                'code', 'ACCOUNT_BINDING_CONFIRM_PENDING')));
        // Returning from the timed-out page requests authority, while the
        // original HTTP transport can still complete later on the server.
        final summary = api.loadAccountSecurity(forceRefresh: true);
        await tester.pump();
        final readsBeforeSettlement = reads;
        committed = successful;
        rawResponse.complete(http.Response(
            successful && channel == 'email' ? '' : '{}',
            successful ? (channel == 'email' ? 204 : 200) : 503));
        await tester.pump();
        final result = await summary;
        expect(api.hasPendingAccountBindingConfirmation, isFalse);
        expect(readsBeforeSettlement, 1,
            reason: 'summary GET cannot race the pending binding confirmation');
        expect(reads, 2);
        expect(result.maskedEmail,
            successful ? 'b***@example.test' : 'a***@example.test');
        expect(api.cachedAccountSecurityData!.maskedEmail, result.maskedEmail);
        expect(confirms, 1,
            reason: 'unknown results must never resend the OTP');
      });
    }

    testWidgets(
        '$channel old settlement cannot unlock a new-session confirmation',
        (tester) async {
      var confirms = 0, reads = 0;
      final oldSent = Completer<void>(), newSent = Completer<void>();
      final oldResponse = Completer<http.Response>();
      final newResponse = Completer<http.Response>();
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://api.test'),
          sessionStore: await signedInStore(),
          client: MockClient((request) async {
            if (request.url.path.endsWith('/auth/login')) {
              return http.Response(
                  '{"access_token":"new","refresh_token":"new-r",'
                  '"matrix_user_id":"@new:test"}',
                  200);
            }
            if (request.method == 'POST') {
              confirms++;
              if (request.headers['authorization'] == 'Bearer old') {
                oldSent.complete();
                return oldResponse.future;
              }
              newSent.complete();
              return newResponse.future;
            }
            reads++;
            return http.Response(
                request.headers['authorization'] == 'Bearer new'
                    ? changedSecurityJson
                    : securityJson,
                200);
          }));
      await api.loadAccountSecurity();
      Future<void> confirm() => channel == 'email'
          ? api.confirmEmailRebind(email: 'b@example.test', code: '123456')
          : api.rebindNewConfirm(phone: '13900000002', code: '123456');
      final oldConfirmation = confirm();
      final timedOut = expectLater(
          oldConfirmation.timeout(const Duration(seconds: 8)),
          throwsA(isA<TimeoutException>()));
      await oldSent.future;
      await tester.pump(const Duration(seconds: 9));
      await timedOut;
      final oldRead = api.loadAccountSecurity(forceRefresh: true);
      final oldReadRejected =
          expectLater(oldRead, throwsA(isA<BusinessApiException>()));
      await api.login(
          username: 'new',
          password: 'new-password-123',
          deviceKey: 'new-device',
          deviceName: 'test');
      expect(api.hasPendingAccountBindingConfirmation, isFalse);
      final newConfirmation = confirm();
      await newSent.future;
      final newRead = api.loadAccountSecurity(forceRefresh: true);
      oldResponse.complete(http.Response(
          channel == 'email' ? '' : '{}', channel == 'email' ? 204 : 200));
      await tester.pump();
      await oldReadRejected;
      expect(api.hasPendingAccountBindingConfirmation, isTrue);
      expect(api.cachedAccountSecurityData, isNull);
      expect(reads, 1);
      newResponse.complete(http.Response(
          channel == 'email' ? '' : '{}', channel == 'email' ? 204 : 200));
      await tester.pump();
      await newConfirmation;
      expect((await newRead).maskedEmail, 'b***@example.test');
      expect(api.cachedAccountSecurityData!.maskedPhone, '139****0002');
      expect(api.accountSecurityCacheIsFresh, isTrue);
      expect(api.hasPendingAccountBindingConfirmation, isFalse);
      expect(confirms, 2);
      expect(reads, 2);
      await api.loadAccountSecurity();
      expect(reads, 2);
    });
  }
}
