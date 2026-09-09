import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/wallet/manual_operation_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'manual_wallet_flow_test.dart' as flow;

void main() {
  test('USDT normalization preserves six decimals and minimum without doubles',
      () {
    expect(manualAmount('10'), '10.000000');
    expect(manualAmount('10.000001'), '10.000001');
    expect(manualAmount('999999999999999999999999.999999'),
        '999999999999999999999999.999999');
    for (final value in ['9.999999', '1e3', '10.0000001', '-10', 'NaN']) {
      expect(() => manualAmount(value), throwsFormatException);
    }
  });
  test(
      'stored intent prevents changed payload and rejects session account switch',
      () async {
    SharedPreferences.setMockInitialValues({});
    final api = await flow.client((request) async => flow.json({}));
    final store = ManualOperationStore(api);
    await store.initialize();
    final original =
        await store.begin('deposit', {'amount': '10.000001', 'version': 1});
    expect(await store.begin('deposit', {'amount': '20.000000', 'version': 2}),
        original);
    await api.sessionStore.saveSession(
        accessToken: 'e30.eyJzdWIiOiJib2IifQ.test', refreshToken: 'refresh');
    await expectLater(
        store.begin('deposit', {'amount': '20.000000', 'version': 2}),
        throwsStateError);
  });
}
