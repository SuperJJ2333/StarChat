import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/core/gallery_media_export.dart';
import 'package:liuhetong_mobile/features/matrix/content_addressed_media.dart';
import 'package:liuhetong_mobile/features/matrix/emoji_vault.dart';
import 'package:liuhetong_mobile/features/media/image_compression_policy.dart';
import 'package:liuhetong_mobile/features/media/media_asset_gateway.dart';
import 'package:liuhetong_mobile/features/moments/moment_image_preprocessor.dart';

import 'media_test_fixtures.dart';

final class _Collection implements EmojiVaultTransport {
  Uint8List? ciphertext;
  int uploads = 0;
  @override
  bool get isEncrypted => true;
  @override
  Future<Map<String, Object?>> uploadEncrypted(
      Uint8List bytes, String mimeType) async {
    uploads++;
    expect(mimeType, 'image/gif');
    ciphertext = (await MediaEnvelope.forBytes(bytes)).encrypted.data;
    return {'url': 'mxc://test/collection'};
  }

  @override
  Future<void> sendEncrypted(EmojiVaultEvent event) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('actual image uploaded as a generic file still obeys the image budget',
      () async {
    final input = largeMediaTestGif();
    final prepared = await prepareContentAddressedMedia(
        file: MatrixFile(
            bytes: input,
            name: 'attachment.bin',
            mimeType: 'application/octet-stream'));
    expect(prepared.file.bytes.length, lessThanOrEqualTo(maxUnifiedImageBytes));
    expect(prepared.file.mimeType, 'image/gif');
  });
  test(
      'initial compression survives collection, two groups, gallery and Moments',
      () async {
    final input = largeMediaTestGif();
    expect(input.length, greaterThan(maxUnifiedImageBytes));
    final source = await prepareContentAddressedMedia(
        file: MatrixImageFile(
            bytes: input, name: 'source.gif', mimeType: 'image/gif'));
    final canonical = source.file.bytes;
    expect(canonical.length, lessThanOrEqualTo(maxUnifiedImageBytes));
    final transport = _Collection();
    final vault = EmojiVault(transport: transport);
    final item = await vault.add(canonical, mimeType: 'image/gif');
    final groupA = await prepareContentAddressedMedia(
        file: MatrixImageFile(
            bytes: canonical, name: 'collected.gif', mimeType: item.mimeType));
    final groupB = await prepareContentAddressedMedia(file: groupA.file);
    expect(groupA.file.bytes, canonical);
    expect(groupB.file.bytes, canonical);
    final sourceCipher = (await source.file.encrypt()).data;
    expect(transport.ciphertext, sourceCipher);
    expect((await groupA.file.encrypt()).data, sourceCipher);
    expect((await groupB.file.encrypt()).data, sourceCipher);
    await vault.add(groupB.file.bytes, mimeType: 'image/gif');
    expect(transport.uploads, 1);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const gallery = MethodChannel('chatflow/gallery');
    const photos = MethodChannel('com.fluttercandies/photo_manager');
    Uint8List? saved;
    messenger.setMockMethodCallHandler(gallery, (_) async => 33);
    messenger.setMockMethodCallHandler(photos, (call) async {
      if (call.method != 'saveImage') return null;
      final args = call.arguments as Map;
      expect(args['filename'], 'saved.gif');
      saved = args['image'] as Uint8List;
      return {
        'id': 'saved',
        'type': 1,
        'width': 192,
        'height': 192,
        'duration': 0,
        'createDt': 0,
        'modifiedDt': 0
      };
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(gallery, null);
      messenger.setMockMethodCallHandler(photos, null);
      debugDefaultTargetPlatformOverride = null;
    });
    await GalleryMediaExport.saveImage(
        filename: 'saved.jpg',
        loadOriginal: () => MediaAssetGateway.readOriginal(
            () async => groupB.file.bytes,
            expectedSha256: item.sha256));
    expect(saved, canonical);
    final momentBytes = await MomentImagePreprocessor().process(saved!);
    expect(momentBytes, canonical);
    final asset = await MediaAssetGateway.inspect(momentBytes,
        mimeType: 'image/jpeg', filename: 'moment.jpg');
    expect(asset.mimeType, 'image/gif');
    expect(asset.filename, 'moment.gif');
    // Business transport receives the prepared bytes in its existing privacy
    // domain; no chat key or envelope is passed to this adapter.
    expect(asset.bytes, canonical);
  });
}
