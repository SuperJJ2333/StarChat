final class UsernameChangePolicy {
  const UsernameChangePolicy(
      {required this.username,
      required this.canChange,
      this.nextChangeAt,
      this.minLength = 6,
      this.maxLength = 20});
  final String username;
  final bool canChange;
  final DateTime? nextChangeAt;
  final int minLength, maxLength;
  factory UsernameChangePolicy.fromJson(Map<String, dynamic> value) =>
      UsernameChangePolicy(
          username: value['username'] as String,
          canChange: value['can_change'] == true,
          nextChangeAt: value['next_change_at'] == null
              ? null
              : DateTime.parse(value['next_change_at'] as String).toUtc(),
          minLength: value['min_length'] as int? ?? 6,
          maxLength: value['max_length'] as int? ?? 20);
}

final class UsernameChangeReceipt {
  const UsernameChangeReceipt(
      {required this.username, required this.changed, this.nextChangeAt});
  final String username;
  final bool changed;
  final DateTime? nextChangeAt;
  factory UsernameChangeReceipt.fromJson(Map<String, dynamic> value) =>
      UsernameChangeReceipt(
          username: value['username'] as String,
          changed: value['changed'] == true,
          nextChangeAt: value['next_change_at'] == null
              ? null
              : DateTime.parse(value['next_change_at'] as String).toUtc());
}

abstract interface class UsernameGateway {
  int get sessionEpoch;
  String newIdempotencyKey();
  Future<UsernameChangePolicy> loadUsernameChangePolicy();
  Future<bool> usernameAvailable(String username);
  Future<UsernameChangeReceipt> changeUsername(String username,
      {required String idempotencyKey});
}
