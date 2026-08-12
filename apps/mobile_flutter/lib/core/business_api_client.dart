import 'dart:convert';
import 'package:http/http.dart' as http;
import 'session_store.dart';

final class BusinessApiClient {
  BusinessApiClient({required this.baseUri, required this.sessionStore, http.Client? client}) : _client = client ?? http.Client();
  final Uri baseUri;
  final SecureSessionStore sessionStore;
  final http.Client _client;
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

