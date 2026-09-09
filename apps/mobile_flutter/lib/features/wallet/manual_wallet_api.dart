/// Typed manual-wallet transport. Sensitive values stay in caller memory only.
/// No retries, generated idempotency keys, persistence, or payload logging here.
library;

import '../../core/business_api_client.dart';

final _decimal = RegExp(r'^(0|[1-9][0-9]{0,23})\.[0-9]{6}$');
Never _invalid() =>
    throw const FormatException('Invalid manual wallet response');
Object? _required(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key)) _invalid();
  return json[key];
}

String _string(Map<String, dynamic> json, String key) {
  final value = _required(json, key);
  if (value is! String || value.isEmpty) _invalid();
  return value;
}

String? _optionalString(Map<String, dynamic> json, String key) =>
    _required(json, key) == null ? null : _string(json, key);
int _integer(Map<String, dynamic> json, String key, [int minimum = 0]) {
  final value = _required(json, key);
  if (value is! int || value < minimum) _invalid();
  return value;
}

bool _boolean(Map<String, dynamic> json, String key) {
  final value = _required(json, key);
  if (value is! bool) _invalid();
  return value;
}

int _fixedInteger(Map<String, dynamic> json, String key, int expected) {
  final value = _integer(json, key);
  if (value != expected) _invalid();
  return value;
}

String _digest(Map<String, dynamic> json, String key) {
  final value = _string(json, key);
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) _invalid();
  return value;
}

String _money(Map<String, dynamic> json, String key) {
  final value = _string(json, key);
  if (!_decimal.hasMatch(value)) _invalid();
  return value;
}

String _literal(Map<String, dynamic> json, String key, String expected) {
  final value = _string(json, key);
  if (value != expected) _invalid();
  return value;
}

DateTime _date(Map<String, dynamic> json, String key) {
  final value = _string(json, key);
  if (!RegExp(r'(Z|[+-][0-9]{2}:[0-9]{2})$').hasMatch(value)) _invalid();
  final parsed = DateTime.tryParse(value);
  if (parsed == null) _invalid();
  return parsed;
}

DateTime? _optionalDate(Map<String, dynamic> json, String key) =>
    _required(json, key) == null ? null : _date(json, key);
List<String> _strings(Map<String, dynamic> json, String key) {
  final value = _required(json, key);
  if (value is! List || value.any((item) => item is! String || item.isEmpty)) {
    _invalid();
  }
  return List<String>.unmodifiable(value.cast<String>());
}

Map<String, dynamic> _object(Map<String, dynamic> json, String key) {
  final value = _required(json, key);
  if (value is! Map<String, dynamic>) _invalid();
  return value;
}

T _state<T>(Map<String, dynamic> json, String key, Map<String, T> states) {
  final state = states[_string(json, key)];
  if (state == null) _invalid();
  return state;
}

enum ManualBindingState { active, pending, unbound }

enum ManualIntentState { open, expired, closedByRebind, fulfilled }

enum ManualPayoutState { requested, claimed, unknown, settled, cancelled }

final class _ScopedWalletTransport {
  _ScopedWalletTransport(this.client) : scope = client.walletIntentScope();
  final BusinessApiClient client;
  final Future<String> scope;
  Future<Map<String, dynamic>> getJson(String path) async =>
      client.getJson(path, expectedWalletScope: await scope);
  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body,
          {required String idempotencyKey}) async =>
      client.postJson(path, body,
          idempotencyKey: idempotencyKey, expectedWalletScope: await scope);
}

final class ManualWalletApi {
  ManualWalletApi(BusinessApiClient client)
      : _client = _ScopedWalletTransport(client);
  final _ScopedWalletTransport _client;

  String _key(String value) {
    if (value.isEmpty ||
        value.length > 128 ||
        value.contains('\r') ||
        value.contains('\n')) {
      throw ArgumentError('Invalid idempotency key');
    }
    return value;
  }

  String _id(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,36}$').hasMatch(value)) {
      throw ArgumentError('Invalid wallet identifier');
    }
    return value;
  }

  Map<String, dynamic> _amountBody(String amount, int version) {
    if (!_decimal.hasMatch(amount) || version < 1) {
      throw ArgumentError('Invalid wallet amount or binding version');
    }
    return {'amount': amount, 'expected_binding_version': version};
  }

  Future<ManualBindingStatus> bindingStatus() async =>
      ManualBindingStatus.fromJson(await _client.getJson('/wallet/binding'));
  Future<ManualBindingChallenge> createBindingChallenge(
      {required String address,
      required int expectedVersion,
      required String idempotencyKey}) async {
    if (address.isEmpty || address.length > 34 || expectedVersion < 0) {
      throw ArgumentError('Invalid binding request');
    }
    return ManualBindingChallenge.fromJson(await _client.postJson(
        '/wallet/binding/challenges',
        {'address': address, 'expected_version': expectedVersion},
        idempotencyKey: _key(idempotencyKey)));
  }

  Future<ManualBindingConfirmation> confirmBinding(
          {required String challengeId,
          required String signature,
          String? oldSignature,
          required String mfaProof,
          required String idempotencyKey}) async =>
      ManualBindingConfirmation.fromJson(await _client.postJson(
          '/wallet/binding/confirm',
          {
            'challenge_id': _id(challengeId),
            'signature': signature,
            if (oldSignature != null) 'old_signature': oldSignature,
            'mfa_proof': mfaProof
          },
          idempotencyKey: _key(idempotencyKey)));
  Future<ManualBindingConfirmation> registerAddress(
          {required String address,
          required int expectedVersion,
          required String idempotencyKey}) async =>
      ManualBindingConfirmation.fromJson(await _client.postJson(
          '/wallet/binding/address',
          {'address': address, 'expected_version': expectedVersion},
          idempotencyKey: _key(idempotencyKey)));
  Future<ManualDepositIntent> createDepositIntent(
          {required String amount,
          required int expectedBindingVersion,
          required String idempotencyKey}) async =>
      ManualDepositIntent.fromJson(await _client.postJson(
          '/wallet/manual/deposit-intents',
          _amountBody(amount, expectedBindingVersion),
          idempotencyKey: _key(idempotencyKey)));
  Future<ManualDepositIntent> depositIntent(String id) async =>
      ManualDepositIntent.fromJson(
          await _client.getJson('/wallet/manual/deposit-intents/${_id(id)}'));
  Future<ManualDepositIntent?> currentDepositIntent() async {
    final result =
        await _client.getJson('/wallet/manual/deposit-intents/current');
    if (!result.containsKey('intent')) throw const FormatException('充值恢复响应无效');
    return result['intent'] == null
        ? null
        : ManualDepositIntent.fromJson(
            Map<String, dynamic>.from(result['intent'] as Map));
  }

  Future<ManualPayoutQuote> createPayoutQuote(
          {required String amount,
          required int expectedBindingVersion,
          required String idempotencyKey}) async =>
      ManualPayoutQuote.fromJson(await _client.postJson(
          '/wallet/manual/payout-quotes',
          _amountBody(amount, expectedBindingVersion),
          idempotencyKey: _key(idempotencyKey)));
  Future<ManualPayout> createPayout(
          {required String quoteId,
          String? mfaProof,
          required String idempotencyKey}) async =>
      ManualPayout.fromJson(await _client.postJson(
          '/wallet/manual/payouts',
          {
            'quote_id': _id(quoteId),
            if (mfaProof != null) 'mfa_proof': mfaProof
          },
          idempotencyKey: _key(idempotencyKey)));
  Future<ManualPayout> payout(String id) async => ManualPayout.fromJson(
      await _client.getJson('/wallet/manual/payouts/${_id(id)}'));
  Future<ManualPayout> cancelPayout(String id,
          {required String idempotencyKey}) async =>
      ManualPayout.fromJson(await _client.postJson(
          '/wallet/manual/payouts/${_id(id)}/cancel', {},
          idempotencyKey: _key(idempotencyKey)));
  Future<ManualMfaStatus> mfaStatus() async =>
      ManualMfaStatus.fromJson(await _client.getJson('/security/mfa'));

  /// The MFA backend does not currently promise idempotent command replays.
  Future<ManualMfaEnrollment> enrollMfa(
          {required String password, required String idempotencyKey}) async =>
      ManualMfaEnrollment.fromJson(await _client.postJson(
          '/security/mfa/enroll', {'password': password},
          idempotencyKey: _key(idempotencyKey)));
  Future<ManualMfaEnabled> enableMfa(
          {required String credentialId,
          required String code,
          String? setupProof,
          required String idempotencyKey}) async =>
      ManualMfaEnabled.fromJson(await _client.postJson(
          '/security/mfa/enable',
          {
            'credential_id': _id(credentialId),
            'code': code,
            if (setupProof != null) 'setup_proof': setupProof
          },
          idempotencyKey: _key(idempotencyKey)));
  Future<String> reauthenticateMfa(
      {required String credentialId,
      required String password,
      required String idempotencyKey}) async {
    final result = await _client.postJson('/security/mfa/reauthenticate',
        {'credential_id': _id(credentialId), 'password': password},
        idempotencyKey: _key(idempotencyKey));
    return _string(result, 'setup_proof');
  }

  Future<ManualMfaEnabled> abortMfaEnrollment(
          {required String credentialId,
          required String password,
          required String idempotencyKey}) async =>
      ManualMfaEnabled.fromJson(await _client.postJson(
          '/security/mfa/abort-pending',
          {'credential_id': _id(credentialId), 'password': password},
          idempotencyKey: _key(idempotencyKey)));
}

final class ManualBindingStatus {
  const ManualBindingStatus._(
      this.status,
      this.id,
      this.version,
      this.maskedAddress,
      this.address,
      this.pendingId,
      this.nextRebindAt,
      this.bindingEnabled,
      this.unavailableDependencies,
      this.rebindIntervalDays);
  final ManualBindingState status;
  final String? id;
  final int version;
  final String? maskedAddress;
  final String? address;
  final String? pendingId;
  final DateTime? nextRebindAt;
  final bool bindingEnabled;
  final List<String> unavailableDependencies;
  final int rebindIntervalDays;
  factory ManualBindingStatus.fromJson(Map<String, dynamic> json) =>
      ManualBindingStatus._(
          _state(json, 'status', {
            'ACTIVE': ManualBindingState.active,
            'PENDING': ManualBindingState.pending,
            'UNBOUND': ManualBindingState.unbound
          }),
          _optionalString(json, 'id'),
          _integer(json, 'version', 0),
          _optionalString(json, 'masked_address'),
          _optionalString({'address': null, ...json}, 'address'),
          _optionalString(json, 'pending_id'),
          _optionalDate(json, 'next_rebind_at'),
          _boolean(json, 'binding_enabled'),
          _strings(json, 'unavailable_dependencies'),
          _fixedInteger(json, 'rebind_interval_days', 30));
}

final class ManualBindingChallenge {
  const ManualBindingChallenge._(
      this.id, this.message, this.expiresAt, this.protocol);
  final String id;
  final String message;
  final DateTime expiresAt;
  final String protocol;
  factory ManualBindingChallenge.fromJson(Map<String, dynamic> json) =>
      ManualBindingChallenge._(
          _string(json, 'id'),
          _string(json, 'message'),
          _date(json, 'expires_at'),
          _literal(json, 'protocol', 'signMessageV2'));
}

final class ManualBindingConfirmation {
  const ManualBindingConfirmation._(
      this.id, this.status, this.version, this.blockedReason);
  final String id;
  final String status;
  final int version;
  final String blockedReason;
  factory ManualBindingConfirmation.fromJson(Map<String, dynamic> json) =>
      ManualBindingConfirmation._(
          _string(json, 'id'),
          _literal(json, 'status', 'PENDING'),
          _integer(json, 'version', 1),
          _string(json, 'blocked_reason'));
}

final class ManualDepositRules {
  const ManualDepositRules._(this.version, this.minimumAmount, this.asset,
      this.precision, this.finalityPolicy, this.expiryMicroseconds);
  final String version;
  final String minimumAmount;
  final String asset;
  final int precision;
  final String finalityPolicy;
  final int expiryMicroseconds;
  factory ManualDepositRules.fromJson(Map<String, dynamic> json) =>
      ManualDepositRules._(
          _string(json, 'version'),
          _money(json, 'minimum_amount'),
          _literal(json, 'asset', 'USDT'),
          _fixedInteger(json, 'precision', 6),
          _literal(json, 'finality_policy', 'TRONGRID_SINGLE_SOURCE_V1'),
          _integer(json, 'expiry_microseconds', 1));
}

final class ManualDepositIntent {
  const ManualDepositIntent._(
      this.id,
      this.bindingId,
      this.bindingVersion,
      this.bindingEffectiveFromBlock,
      this.sourceAddress,
      this.officialAddress,
      this.officialConfigVersion,
      this.network,
      this.rules,
      this.status,
      this.expectedAmount,
      this.createdAt,
      this.expiresAt,
      this.closedAt);
  final String id;
  final String bindingId;
  final int bindingVersion;
  final int bindingEffectiveFromBlock;
  final String sourceAddress;
  final String officialAddress;
  final String officialConfigVersion;
  final String network;
  final ManualDepositRules rules;
  final ManualIntentState status;
  final String expectedAmount;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? closedAt;
  factory ManualDepositIntent.fromJson(Map<String, dynamic> json) =>
      ManualDepositIntent._(
          _string(json, 'id'),
          _string(json, 'binding_id'),
          _integer(json, 'binding_version', 1),
          _integer(json, 'binding_effective_from_block', 0),
          _string(json, 'source_address'),
          _string(json, 'official_address'),
          _string(json, 'official_config_version'),
          _literal(json, 'network', 'tron-mainnet'),
          ManualDepositRules.fromJson(_object(json, 'rules_snapshot')),
          _state(json, 'status', {
            'OPEN': ManualIntentState.open,
            'EXPIRED': ManualIntentState.expired,
            'CLOSED_BY_REBIND': ManualIntentState.closedByRebind,
            'FULFILLED': ManualIntentState.fulfilled
          }),
          _money(json, 'expected_amount'),
          _date(json, 'created_at'),
          _date(json, 'expires_at'),
          _optionalDate(json, 'closed_at'));
}

final class ManualPayoutQuote {
  const ManualPayoutQuote._(
      this.id,
      this.digest,
      this.bindingId,
      this.bindingVersion,
      this.targetAddress,
      this.officialAddress,
      this.officialConfigVersion,
      this.ownerAdminId,
      this.policyVersion,
      this.approvalPolicy,
      this.finalityPolicy,
      this.network,
      this.contract,
      this.amount,
      this.fee,
      this.hold,
      this.receive,
      this.minimum,
      this.maxPer,
      this.user24h,
      this.global24h,
      this.safetyEpoch,
      this.createdAt,
      this.expiresAt);
  final String id;
  final String digest;
  final String bindingId;
  final int bindingVersion;
  final String targetAddress;
  final String officialAddress;
  final String officialConfigVersion;
  final String ownerAdminId;
  final String policyVersion;
  final String approvalPolicy;
  final String finalityPolicy;
  final String network;
  final String contract;
  final String amount;
  final String fee;
  final String hold;
  final String receive;
  final String minimum;
  final String maxPer;
  final String user24h;
  final String global24h;
  final int safetyEpoch;
  final DateTime createdAt;
  final DateTime expiresAt;
  factory ManualPayoutQuote.fromJson(Map<String, dynamic> json) =>
      ManualPayoutQuote._(
          _string(json, 'id'),
          _digest(json, 'digest'),
          _string(json, 'binding_id'),
          _integer(json, 'binding_version', 1),
          _string(json, 'target_address'),
          _string(json, 'official_address'),
          _string(json, 'official_config_version'),
          _string(json, 'owner_admin_id'),
          _string(json, 'policy_version'),
          _literal(json, 'approval_policy', 'OWNER_MANUAL_V1'),
          _literal(json, 'finality_policy', 'TRONGRID_SINGLE_SOURCE_V1'),
          _literal(json, 'network', 'tron-mainnet'),
          _string(json, 'contract'),
          _money(json, 'amount'),
          _money(json, 'fee'),
          _money(json, 'hold'),
          _money(json, 'receive'),
          _money(json, 'minimum'),
          _money(json, 'max_per'),
          _money(json, 'user_24h'),
          _money(json, 'global_24h'),
          _integer(json, 'safety_epoch', 0),
          _date(json, 'created_at'),
          _date(json, 'expires_at'));
}

final class ManualPayout {
  const ManualPayout._(
      this.id,
      this.userId,
      this.quoteId,
      this.amount,
      this.status,
      this.digest,
      this.candidateTxid,
      this.settlementTxid,
      this.reviewReason);
  final String id;
  final String userId;
  final String quoteId;
  final String amount;
  final ManualPayoutState status;
  final String digest;
  final String? candidateTxid;
  final String? settlementTxid;
  final String? reviewReason;
  factory ManualPayout.fromJson(Map<String, dynamic> json) => ManualPayout._(
      _string(json, 'id'),
      _string(json, 'user_id'),
      _string(json, 'quote_id'),
      _money(json, 'amount'),
      _state(json, 'status', {
        'REQUESTED': ManualPayoutState.requested,
        'CLAIMED': ManualPayoutState.claimed,
        'UNKNOWN': ManualPayoutState.unknown,
        'SETTLED': ManualPayoutState.settled,
        'CANCELLED': ManualPayoutState.cancelled
      }),
      _digest(json, 'digest'),
      _optionalString(json, 'candidate_txid'),
      _optionalString(json, 'settlement_txid'),
      _optionalString(json, 'review_reason'));
}

final class ManualMfaStatus {
  const ManualMfaStatus._(
      this.configured, this.enabled, this.enrolledAt, this.pendingCredentialId);
  final bool configured;
  final bool enabled;
  final DateTime? enrolledAt;
  final String? pendingCredentialId;
  factory ManualMfaStatus.fromJson(Map<String, dynamic> json) =>
      ManualMfaStatus._(
          _boolean(json, 'configured'),
          _boolean(json, 'enabled'),
          _optionalDate(json, 'enrolled_at'),
          _optionalString({'pending_credential_id': null, ...json},
              'pending_credential_id'));
}

final class ManualMfaEnrollment {
  const ManualMfaEnrollment._(
      this.credentialId, this.secret, this.provisioningUri, this.setupProof);
  final String credentialId;
  final String secret;
  final String provisioningUri;
  final String? setupProof;
  factory ManualMfaEnrollment.fromJson(Map<String, dynamic> json) =>
      ManualMfaEnrollment._(
          _string(json, 'credential_id'),
          _string(json, 'secret'),
          _string(json, 'provisioning_uri'),
          json['setup_proof'] as String?);
}

final class ManualMfaEnabled {
  const ManualMfaEnabled._(this.enabled);
  final bool enabled;
  factory ManualMfaEnabled.fromJson(Map<String, dynamic> json) =>
      ManualMfaEnabled._(_boolean(json, 'enabled'));
}
