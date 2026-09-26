import 'business_api_client.dart';
import 'username_gateway.dart';

/// Username changes use the business API; Matrix credentials stay untouched.
final class BusinessUsernameGateway implements UsernameGateway {
  BusinessUsernameGateway(this.api);
  final BusinessApiClient api;
  @override
  int get sessionEpoch => api.sessionEpoch;
  @override
  String newIdempotencyKey() => api.newIdempotencyKey();
  @override
  Future<UsernameChangePolicy> loadUsernameChangePolicy() async =>
      UsernameChangePolicy.fromJson(
          await api.getJson('/profile/username-change'));
  @override
  Future<bool> usernameAvailable(String username) async =>
      (await api.getJson(
              '/profile/username-availability?username=${Uri.encodeQueryComponent(username)}'))[
          'available'] ==
      true;
  @override
  Future<UsernameChangeReceipt> changeUsername(String username,
          {required String idempotencyKey}) async =>
      UsernameChangeReceipt.fromJson(await api.patchJson(
          '/profile/username', {'username': username},
          idempotencyKey: idempotencyKey));
}
