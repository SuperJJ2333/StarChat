import '../../core/business_api_client.dart';
import '../finance/wallet_entry_store.dart';

/// Display-only resources share the wallet's account/epoch lifecycle and disk
/// snapshots. No cached result authorizes a payment or substitutes a quote.
WalletEntryStore walletReadCache(BusinessApiClient client, String scope,
        String resource, Future<Map<String, dynamic>> Function() load) =>
    WalletEntryStores.of(
        scope: '$scope/read/$resource',
        gateway: _ReadGateway(client, scope, resource, load));

final class _ReadGateway implements WalletEntryGateway {
  _ReadGateway(this.client, this.scope, this.resource, this.read);
  final BusinessApiClient client;
  final String scope;
  final String resource;
  final Future<Map<String, dynamic>> Function() read;
  @override
  int get sessionEpoch => client.sessionEpoch;
  @override
  Future<Map<String, dynamic>> load() async {
    if (await client.walletIntentScope() != scope) {
      throw StateError('账户已切换，请重新打开钱包');
    }
    final result = await read();
    if (await client.walletIntentScope() != scope) {
      throw StateError('账户已切换，请重新打开钱包');
    }
    return walletReadProjection(resource, result);
  }
}

/// Explicit display-field allowlist; credentials and unknown future API fields
/// must never become persistent data by accident.
Map<String, dynamic> walletReadProjection(
    String resource, Map<String, dynamic> data) {
  Map<String, dynamic> pick(Map row, Set<String> keys) => {
        for (final key in keys)
          if (row.containsKey(key)) key: row[key],
      };
  if (resource == 'fx') {
    return pick(data, {'rate', 'updated_at', 'source', 'as_of', 'stale'});
  }
  final keys = resource == 'history'
      ? {'id', 'kind', 'amount', 'status', 'created_at'}
      : {
          'id',
          'amount_usdt',
          'status',
          'created_at',
          'expires_at',
          'processing_stage',
          'payment_verified',
          'claimed_by',
          'evidence_txid',
          'actual_received_usdt',
          'final_caibi_amount',
          'final_rate'
        };
  return {
    'items': [
      for (final row in (data['items'] as List? ?? []).whereType<Map>())
        {
          ...pick(row, keys),
          if (resource == 'recharges' && row['official_payment'] is Map)
            'official_payment':
                pick(row['official_payment'] as Map, {'network', 'address'}),
        },
    ]
  };
}
