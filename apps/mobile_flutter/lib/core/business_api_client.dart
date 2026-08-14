import 'dart:convert';
import 'package:http/http.dart' as http;
import 'session_store.dart';
import 'package:uuid/uuid.dart';

final class BusinessApiException implements Exception {
  const BusinessApiException({required this.statusCode, required this.code, required this.message});
  final int statusCode;
  final String code;
  final String message;
  @override String toString() => message;
}

final class BusinessApiClient {
  BusinessApiClient({required this.baseUri, required this.sessionStore, http.Client? client}) : _client = client ?? http.Client();
  final Uri baseUri;
  final SecureSessionStore sessionStore;
  final http.Client _client;
  final Uuid _uuid = const Uuid();
  String newIdempotencyKey() => _uuid.v4();
  Uri _uri(String path) => baseUri.resolve(path.startsWith('/api/v1/') ? path : '/api/v1$path');
  Future<Map<String, dynamic>> login({required String username, required String password, required String deviceKey, required String deviceName}) async {
    final response = await _client.post(_uri('/auth/login'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'username': username, 'password': password, 'device_key': deviceKey, 'device_name': deviceName}));
    final body = _decode(response);
    await sessionStore.saveSession(accessToken: body['access_token'] as String, refreshToken: body['refresh_token'] as String);
    return body;
  }
  Future<Map<String, dynamic>> caibiBalance() => getJson('/ledger/balances/me');
  Future<Map<String, dynamic>> transferCaibi(String receiverId, String amount) =>
      postJson('/ledger/transfers', {'receiver_id': receiverId, 'amount': amount}, idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> createRedPacket({required String mode, required String total, required int shareCount, String? roomId, String? recipientId}) =>
      postJson('/red-packets', {'mode': mode, 'total': total, 'share_count': shareCount, if (roomId != null) 'room_id': roomId, if (recipientId != null) 'recipient_id': recipientId}, idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> claimRedPacket(String id) => postJson('/red-packets/$id/claims', {}, idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> redPacketDetail(String id) => getJson('/red-packets/$id');
  Future<Map<String, dynamic>> listRedPackets({String? roomId}) => getJson('/red-packets${roomId == null ? '' : '?room_id=${Uri.encodeQueryComponent(roomId)}'}');
  Future<Map<String, dynamic>> walletBalance() => getJson('/wallet/balances/me');
  Future<Map<String, dynamic>> walletDepositAddress() => getJson('/wallet/deposit-address');
  Future<Map<String,dynamic>> walletHistory({String? kind})=>getJson('/wallet/transactions${kind==null?'':'?kind=$kind'}');
  Future<Map<String, dynamic>> withdrawalStatus(String id) => getJson('/wallet/withdrawals/$id');
  Future<Map<String,dynamic>> friends()=>getJson('/friends');
  Future<Map<String,dynamic>> friendRequests()=>getJson('/friends/requests');
  Future<Map<String,dynamic>> contactTags()=>getJson('/contact-tags');
  Future<Map<String,dynamic>> createContactTag(String name)=>postJson('/contact-tags',{'name':name},idempotencyKey:newIdempotencyKey());
  Future<Map<String,dynamic>> blocks()=>getJson('/blocks');
  Future<Map<String,dynamic>> updateContact(String id,{String? remark,List<String> tags=const[],String momentsPermission='DEFAULT'})=>patchJson('/friends/$id',{'remark':remark,'tags':tags,'moments_permission':momentsPermission},idempotencyKey:newIdempotencyKey());
  Future<Map<String,dynamic>> blockUser(String id)=>postJson('/blocks',{'user_id':id},idempotencyKey:newIdempotencyKey());
  Future<Map<String,dynamic>> searchUsers(String query)=>getJson('/users/search?q=${Uri.encodeQueryComponent(query)}');
  Future<Map<String,dynamic>> requestFriend(String userId,{String message=''})=>postJson('/friends/requests',{'target_user_id':userId,'message':message},idempotencyKey:newIdempotencyKey());
  Future<Map<String,dynamic>> acceptFriendRequest(String id)=>postJson('/friends/requests/$id/accept',{},idempotencyKey:newIdempotencyKey());
  Future<Map<String,dynamic>> rejectFriendRequest(String id)=>postJson('/friends/requests/$id/reject',{},idempotencyKey:newIdempotencyKey());
  Future<Map<String,dynamic>> momentsFeed({String mode='recommended'})=>getJson('/moments/feed?mode=$mode');
  Future<Map<String,dynamic>> searchMoments(String query)=>getJson('/moments/search?q=${Uri.encodeQueryComponent(query)}');
  Future<Map<String,dynamic>> publishMoment({required String text,required String visibility,List<String> imageUrls=const [],List<String> includeUserIds=const [],List<String> excludeUserIds=const []})=>postJson('/moments',{'text':text,'visibility':visibility,'image_urls':imageUrls,'include_user_ids':includeUserIds,'exclude_user_ids':excludeUserIds},idempotencyKey:newIdempotencyKey());
  Future<Map<String,dynamic>> likeMoment(String id)=>postJson('/moments/$id/likes',{},idempotencyKey:newIdempotencyKey());
  Future<Map<String,dynamic>> commentMoment(String id,String text)=>postJson('/moments/$id/comments',{'text':text},idempotencyKey:newIdempotencyKey());
  Future<Map<String,dynamic>> momentsPreferences()=>getJson('/moments/preferences');
  Future<Map<String,dynamic>> updateMomentsPreferences({required String historyRange,required bool personalized})=>putJson('/moments/preferences',{'history_range':historyRange,'personalized_recommendations':personalized});
  Future<Map<String, dynamic>> requestWithdrawal({required String amount, required String address, required String clientOrderId, required String reasonCode}) =>
      postJson('/wallet/withdrawals', {'amount': amount, 'address': address, 'client_order_id': clientOrderId, 'reason_code': reasonCode}, idempotencyKey: newIdempotencyKey());
  Future<Map<String, dynamic>> getJson(String path) async {
    final token = await sessionStore.accessToken();
    final response = await _client.get(_uri(path), headers: {if (token != null) 'Authorization': 'Bearer $token'});
    return _decode(response);
  }
  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body, {required String idempotencyKey}) async {
    final token = await sessionStore.accessToken();
    final response = await _client.post(_uri(path), headers: {'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey, if (token != null) 'Authorization': 'Bearer $token'}, body: jsonEncode(body));
    return _decode(response);
  }
  Future<Map<String,dynamic>> patchJson(String path,Map<String,dynamic> body,{required String idempotencyKey})async{final token=await sessionStore.accessToken();final response=await _client.patch(_uri(path),headers:{'Content-Type':'application/json','Idempotency-Key':idempotencyKey,if(token!=null)'Authorization':'Bearer $token'},body:jsonEncode(body));return _decode(response);}
  Future<Map<String,dynamic>> putJson(String path,Map<String,dynamic> body)async{final token=await sessionStore.accessToken();final response=await _client.put(_uri(path),headers:{'Content-Type':'application/json',if(token!=null)'Authorization':'Bearer $token'},body:jsonEncode(body));return _decode(response);}
  Map<String, dynamic> _decode(http.Response response) {
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      throw BusinessApiException(
        statusCode: response.statusCode,
        code: body['error']?['code']?.toString() ?? 'BUSINESS_REQUEST_FAILED',
        message: body['error']?['message']?.toString() ?? '业务请求失败',
      );
    }
    return body;
  }
}

