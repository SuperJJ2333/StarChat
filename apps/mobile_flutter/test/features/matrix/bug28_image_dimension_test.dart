import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/room.dart' as sdk_room;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 真实可解码的 3x2 PNG（红块）。
final Uint8List realPngBytes =
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAIAAAASFvFNAAAAEElEQVR4nGP4z8AAQQxwFgBB0gX7h/C5SAAAAABJRU5ErkJggg==');

class _UploadClient extends Client {
  _UploadClient() : super('bug28-test');
  late Room room;
  @override
  bool get fileEncryptionEnabled => true;
  @override
  String? get userID => '@sender:test';
  @override
  Room? getRoomById(String id) => room;
  @override
  Future<MediaConfig> getConfig() async => MediaConfig(mUploadSize: 1000000);
  @override
  Future<void> handleSync(SyncUpdate sync, {Direction? direction}) async {}
  @override
  Future<Uri> uploadContent(Uint8List file,
      {String? filename, String? contentType}) async {
    return Uri.parse('mxc://test/1');
  }
}

class _UploadRoom extends sdk_room.Room {
  _UploadRoom(Client client) : super(id: '!test:example', client: client);
  Map<String, dynamic>? sent;
  @override
  bool get encrypted => true;
  @override
  Membership get membership => Membership.join;
  @override
  bool get canSendDefaultMessages => true;
  @override
  Future<String?> sendEvent(Map<String, dynamic> content,
      {String type = EventTypes.Message,
      String? txid,
      Event? inReplyTo,
      String? editEventId,
      String? threadRootEventId,
      String? threadLastEventId}) async {
    sent = content;
    return 'event';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Paths extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      Directory.systemTemp.createTempSync('bug28-').path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _Paths();

  test('BUG-28：自带缩略图的编辑图片发送仍写入顶层 info.w/h（解码尺寸）', () async {
    final client = _UploadClient();
    final room = _UploadRoom(client);
    client.room = room;
    await MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'))
        .sendEncryptedMedia(room.id, realPngBytes, 'image/png',
            filename: 'edited.png',
            thumbnailBytes: Uint8List.fromList([1]),
            thumbnailWidth: 1,
            thumbnailHeight: 1);
    expect(room.sent?['info']?['w'], 3,
        reason: '附缩略图路径跳过了 SDK 缩略图预处理，发送聚合点必须自行补齐解码宽高');
    expect(room.sent?['info']?['h'], 2);
  });

  test('BUG-28：已携带宽高的图片不被改写', () async {
    final client = _UploadClient();
    final room = _UploadRoom(client);
    client.room = room;
    await MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'))
        .sendEncryptedMedia(room.id, realPngBytes, 'image/png',
            filename: 'already.png',
            extraContent: {
          'info': {'w': 30, 'h': 20}
        });
    expect(room.sent?['info']?['w'], 30, reason: '调用方声明的尺寸是权威，不得覆盖');
    expect(room.sent?['info']?['h'], 20);
  });
}
