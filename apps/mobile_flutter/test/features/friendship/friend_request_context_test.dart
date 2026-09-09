import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_timeline_adapter.dart';

void main() {
  test('acceptance body is accurate on requester and accepter devices', () {
    expect(friendAcceptedSystemMessage('Bob'), '你们已成为好友，现在可以开始聊天了。');
  });
  test('request context is labeled and retains source identity without m.text',
      () {
    final content = friendAcceptedEventContent(
      requesterMatrixUserId: '@bob:test',
      requesterDisplayName: 'Bob',
      requestId: 'request-1',
      requestMessage: '你好，我是Bob',
    );
    expect(content['request_id'], 'request-1');
    expect(content['requester_matrix_user_id'], '@bob:test');
    expect(content['request_message'], '你好，我是Bob');
    expect(content['msgtype'], isNull);
    expect(content['body'], '你们已成为好友，现在可以开始聊天了。\n好友申请说明（申请人：Bob）：你好，我是Bob');
  });
  test('acceptance retries are stable but re-add requests have distinct IDs',
      () {
    String transaction(String request) => friendAcceptedTransactionId(
        roomId: '!room:test',
        acceptingUserId: '@alice:test',
        requestId: request);
    expect(transaction('r1'), transaction('r1'));
    expect(transaction('r1'), isNot(transaction('r2')));
  });
}
