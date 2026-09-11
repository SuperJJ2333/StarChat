import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/business_api_client.dart';

/// Only non-secret operation metadata is durable. Authentication and signatures
/// must be supplied again; an uncertain operation is never silently discarded.
final class ManualOperationStore {
  ManualOperationStore(this.client);
  final BusinessApiClient client;
  String? _scope;
  SharedPreferences? _prefs;

  Future<void> initialize() async {
    _scope = await client.walletIntentScope();
    _prefs = await SharedPreferences.getInstance();
  }

  Future<String> _key(String slot) async {
    if (_scope == null || await client.walletIntentScope() != _scope) {
      throw StateError('账户已切换，请重新打开钱包');
    }
    return 'wallet.manual.v1:$_scope:$slot';
  }

  Future<Map<String, dynamic>?> read(String slot) async {
    final raw = _prefs!.getString(await _key(slot));
    return raw == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<Map<String, dynamic>> begin(
      String slot, Map<String, dynamic> body) async {
    final existing = await read(slot);
    if (existing != null) return existing;
    final record = {'key': client.newIdempotencyKey(), ...body};
    await save(slot, record);
    return record;
  }

  Future<void> save(String slot, Map<String, dynamic> record) async {
    const allowed = {
      'key',
      'amount',
      'version',
      'id',
      'quote_id',
      'address',
      'method',
      'confirm_key',
      'funding_asset'
    };
    if (record.keys.any((key) => !allowed.contains(key))) {
      throw ArgumentError('Secret or unsupported operation metadata');
    }
    if (record.containsKey('method') && record['method'] != 'address_only') {
      throw ArgumentError('Unsupported operation method');
    }
    if (record.containsKey('funding_asset') &&
        !const {'CAIBI', 'USDT'}.contains(record['funding_asset'])) {
      throw ArgumentError('Unsupported funding asset');
    }
    if (!await _prefs!.setString(await _key(slot), jsonEncode(record))) {
      throw StateError('无法保存操作记录，尚未发送请求');
    }
  }

  Future<void> clear(String slot) async {
    if (!await _prefs!.remove(await _key(slot))) {
      throw StateError('无法更新操作记录');
    }
  }
}

String manualAmount(String input) {
  final value = input.trim();
  if (!RegExp(r'^(0|[1-9][0-9]{0,23})(\.[0-9]{1,6})?$').hasMatch(value)) {
    throw const FormatException('请输入有效金额，最多六位小数');
  }
  final parts = value.split('.');
  final normalized =
      '${parts[0]}.${(parts.length == 2 ? parts[1] : '').padRight(6, '0')}';
  if (BigInt.parse(normalized.replaceAll('.', '')) < BigInt.from(10000000)) {
    throw const FormatException('最低金额为 10.000000 USDT');
  }
  return normalized;
}
