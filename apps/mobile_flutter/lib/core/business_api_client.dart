import 'dart:convert';
import 'package:http/http.dart' as http;
import 'session_store.dart';
import 'package:uuid/uuid.dart';

final class BusinessApiClient {
  BusinessApiClient({required this.baseUri, required this.sessionStore, http.Client? client}) : _client = client ?? http.Client();
  final Uri baseUri;
  final SecureSessionStore sessionStore;
  final http.Client _client;
  final Uuid _uuid = const Uuid();
  String newIdempotencyKey() => _uuid.v4();
  Future<Map<String, dynamic>> caibiBalance() => getJson('/ledger/balances/me');
  Future<Map<String, dynamic>> transferCaibi(String receiverId, String amount) =>
      postJson('/ledger/transfers', {'receiver_id': receiverId, 'amount': amount}, idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> createRedPacket({required String mode, required String total, required int shareCount, String? roomId, String? recipientId}) =>
      postJson('/red-packets', {'mode': mode, 'total': total, 'share_count': shareCount, if (roomId != null) 'room_id': roomId, if (recipientId != null) 'recipient_id': recipientId}, idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> claimRedPacket(String id) => postJson('/red-packets/$id/claims', {}, idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> walletBalance() => getJson('/wallet/balances/me');
  Future<Map<String, dynamic>> requestWithdrawal({required String amount, required String address, required String clientOrderId, required String reasonCode}) =>
      postJson('/wallet/withdrawals', {'amount': amount, 'address': address, 'client_order_id': clientOrderId, 'reason_code': reasonCode}, idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> getJson(String path) async {
    final token = await sessionStore.accessToken();
    final response = await _client.get(baseUri.resolve(path), headers: {if (token != null) 'Authorization': 'Bearer $token'});
    return _decode(response);
  }
  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body, {required String idempotencyKey}) async {
    final token = await sessionStore.accessToken();
    final response = await _client.post(baseUri.resolve(path), headers: {'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey, if (token != null) 'Authorization': 'Bearer $token'}, body: jsonEncode(body));
    return _decode(response);
  }
  Map<String, dynamic> _decode(http.Response response) {
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 400) throw StateError(body['error']?['message']?.toString() ?? '业务请求失败');
    return body;
  }
}

