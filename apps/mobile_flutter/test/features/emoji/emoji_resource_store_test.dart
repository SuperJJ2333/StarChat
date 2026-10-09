import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/maintenance_activity.dart';
import 'package:liuhetong_mobile/features/emoji/emoji_resource_store.dart';
import 'package:liuhetong_mobile/features/emoji/emoji_resource_manifest.dart';

Future<Directory> _temporaryCache() async {
  final parent = Directory(
      '../../docs/verification/artifacts/2026-10-09/mobile-responsive-maintenance/resources/test-cache');
  await parent.create(recursive: true);
  return parent.createTemp('emoji-');
}

void main() {
  test(
      'warm fingerprint fast path invalidates same-length corruption before async SHA',
      () async {
    final dir = await _temporaryCache();
    final gate = MaintenanceActivity();
    final manifest = EmojiResourceManifest.parse(emojiManifestJson,
        expectedDigest: emojiManifestDigest);
    final store = EmojiResourceStore(
        directory: dir, manifest: manifest, maintenance: gate);
    try {
      final source = File('assets/emoji/joy.webp');
      final file = (await store.accept('joy', source.openRead()))!;
      final hashes = store.diagnostics['hashChecks'];
      for (var i = 0; i < 140; i++) {
        expect(store.verifiedFile('joy')?.path, file.path);
      }
      expect(store.diagnostics['hashChecks'], hashes);
      final coalesced = await Future.wait(
          List.generate(20, (_) => store.resolve('joy', fetch: false)));
      expect(coalesced.every((f) => f?.path == file.path), isTrue);
      expect(store.diagnostics['hashChecks'], hashes! + 1);
      final bytes = await file.readAsBytes();
      bytes[bytes.length - 1] ^= 1;
      await file.writeAsBytes(bytes, flush: true);
      await file
          .setLastModified(DateTime.now().add(const Duration(seconds: 1)));
      expect(store.verifiedFile('joy'), isNull);
      expect(await store.resolve('joy', fetch: false), isNull);
      await store.accept('joy', source.openRead());
      expect(store.verifiedFile('joy'), isNotNull);
      store.dispose();
      expect(store.verifiedFile('joy'), isNull);
    } finally {
      store.dispose();
      gate.dispose();
      await dir.delete(recursive: true);
    }
  });
  test('pinned manifest rejects tampering, path escape and unapproved origin',
      () {
    expect(
        () => EmojiResourceManifest.parse(emojiManifestJson,
            expectedDigest: '0' * 64),
        throwsFormatException);
    final bad = jsonDecode(emojiManifestJson) as Map<String, dynamic>;
    (bad['entries'] as List).first['path'] = '../outside.webp';
    final data = jsonEncode(bad);
    expect(
        () => EmojiResourceManifest.parse(data,
            expectedDigest: sha256.convert(utf8.encode(data)).toString()),
        throwsFormatException);
    expect(
        () => EmojiResourceStore.validateBaseUri(
            Uri.parse('http://d12fjr06o6tga5.cloudfront.net/resources/emoji/')),
        throwsFormatException);
    expect(
        () => EmojiResourceStore.validateBaseUri(
            Uri.parse('https://evil.test/resources/emoji/')),
        throwsFormatException);
  });
  test('corrupt, oversized and interrupted files never enter verified cache',
      () async {
    final dir = await _temporaryCache();
    final gate = MaintenanceActivity(clock: () => DateTime(2026));
    final manifest = EmojiResourceManifest.parse(emojiManifestJson,
        expectedDigest: emojiManifestDigest);
    final store = EmojiResourceStore(
        directory: dir, manifest: manifest, maintenance: gate);
    try {
      final entry = manifest.entries.values.first;
      expect(await store.accept(entry.id, Stream.value([1, 2, 3])), isNull);
      expect(
          await store.accept(
              entry.id, Stream.value(List.filled(entry.bytes + 1, 1))),
          isNull);
      expect(
          await store.accept(
              entry.id, Stream.error(const SocketException('interrupted'))),
          isNull);
      expect(await dir.list().toList(), isEmpty);
    } finally {
      store.dispose();
      gate.dispose();
      await dir.delete(recursive: true);
    }
  });
  test(
      'verified offline file resolves without network and pins survive eviction',
      () async {
    final dir = await _temporaryCache();
    final gate = MaintenanceActivity();
    final manifest = EmojiResourceManifest.parse(emojiManifestJson,
        expectedDigest: emojiManifestDigest);
    final store = EmojiResourceStore(
        directory: dir,
        manifest: manifest,
        maintenance: gate,
        maxCacheBytes: 1);
    final entry = manifest.entries['joy']!;
    try {
      store.pin(entry.id);
      final file = await store.accept(
          entry.id, File('assets/emoji/joy.webp').openRead());
      expect(file, isNotNull);
      expect(await store.resolve(entry.id, fetch: false), isNotNull);
      await store.trim();
      expect(await file!.exists(), true);
      store.unpin(entry.id);
      await store.trim();
      expect(await file.exists(), false);
    } finally {
      store.dispose();
      gate.dispose();
      await dir.delete(recursive: true);
    }
  });
  test(
      'disposing queued resource work releases its foreground waiter immediately',
      () async {
    final dir = await _temporaryCache();
    final gate = MaintenanceActivity();
    gate.setInteractive('foreground', true);
    final manifest = EmojiResourceManifest.parse(emojiManifestJson,
        expectedDigest: emojiManifestDigest);
    final store = EmojiResourceStore(
        directory: dir, manifest: manifest, maintenance: gate);
    try {
      final work = store.resolve('joy');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(gate.pendingWaiters, 1);
      store.dispose();
      expect(await work.timeout(const Duration(seconds: 1)), isNull);
      expect(gate.pendingWaiters, 0);
      expect(gate.interactive, true);
    } finally {
      store.dispose();
      gate.dispose();
      await dir.delete(recursive: true);
    }
  });
}
