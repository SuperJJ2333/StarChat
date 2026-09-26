/// Business authority for verified account bindings and password recovery.
/// Credentials and OTP proofs stay in memory and never enter Matrix or caches.
final class AccountSecurityData {
  const AccountSecurityData(
      {required this.maskedEmail,
      required this.maskedPhone,
      required this.emailBound,
      required this.phoneBound,
      required this.emailVerified,
      required this.phoneVerified});
  final String? maskedEmail, maskedPhone;
  final bool emailBound, phoneBound, emailVerified, phoneVerified;
  bool get canUseEmail => emailBound && emailVerified;
  bool get canUsePhone => phoneBound && phoneVerified;
  factory AccountSecurityData.fromJson(Map<String, dynamic> body) =>
      AccountSecurityData(
          maskedEmail: body['masked_email'] as String?,
          maskedPhone: body['masked_phone'] as String?,
          emailBound: body['email_bound'] == true,
          phoneBound: body['phone_bound'] == true,
          emailVerified: body['email_verified'] == true,
          phoneVerified: body['phone_verified'] == true);
}

abstract interface class AccountCredentialsGateway {
  /// Reads a masked display summary; binding mutations remain authoritative.
  Future<AccountSecurityData> loadAccountSecurity({bool forceRefresh = false});
  Future<int> requestPasswordCode(
      {required String channel,
      required String target,
      required bool authenticated});
  Future<String> verifyPasswordCode(
      {required String channel,
      required String target,
      required String code,
      required bool authenticated});
  Future<void> resetPassword(
      {required String token,
      required String newPassword,
      required bool authenticated});
  Future<Map<String, dynamic>> requestEmailRebindOldCode();
  Future<void> verifyEmailRebindOldCode(String code);
  Future<int> requestEmailRebindNewCode(String email);
  Future<void> confirmEmailRebind(
      {required String email, required String code});
}
