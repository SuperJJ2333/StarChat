import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/maintenance_activity.dart';
import 'package:liuhetong_mobile/features/emoji/emoji_resource_manifest.dart';
import 'package:liuhetong_mobile/features/emoji/emoji_resource_store.dart';

void main() {
  const current = 'https://d29qsnrzc2iag0.cloudfront.net/resources/emoji/';
  const legacy = 'https://d12fjr06o6tga5.cloudfront.net/resources/emoji/';

  test('new account emoji origin is approved exactly', () {
    expect(EmojiResourceStore.validateBaseUri(Uri.parse(current)),
        Uri.parse(current));
  });

  test('default emoji requests use new account without changing resource cache',
      () {
    final gate = MaintenanceActivity();
    final manifest = EmojiResourceManifest.parse(emojiManifestJson,
        expectedDigest: emojiManifestDigest);
    final store = EmojiResourceStore(
        directory: Directory(
            '../../docs/verification/artifacts/2026-11-04/aws-cdn-client-compat/test-cache'),
        manifest: manifest,
        maintenance: gate);
    try {
      expect(store.baseUri, Uri.parse(current));
      expect(identical(store.manifest, manifest), isTrue);
    } finally {
      store.dispose();
      gate.dispose();
    }
  });

  test('legacy explicit origin remains usable during client upgrade', () {
    expect(EmojiResourceStore.validateBaseUri(Uri.parse(legacy)),
        Uri.parse(legacy));
  });

  test('migration keeps protocol host path and URL credential boundaries', () {
    for (final origin in [current, legacy]) {
      final uri = Uri.parse(origin);
      for (final invalid in [
        uri.replace(scheme: 'http'),
        uri.replace(host: '${uri.host}.invalid'),
        uri.replace(host: 'prefix-${uri.host}'),
        uri.replace(userInfo: 'user'),
        uri.replace(port: 8443),
        uri.replace(path: '/resources/'),
        uri.replace(query: 'redirect=1'),
        uri.replace(fragment: 'bypass'),
      ]) {
        expect(() => EmojiResourceStore.validateBaseUri(invalid),
            throwsFormatException,
            reason: invalid.toString());
      }
    }
  });
}
