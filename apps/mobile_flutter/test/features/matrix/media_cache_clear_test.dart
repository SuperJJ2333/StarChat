import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  int calls = 0;
  int? blockAt;
  final blocked = Completer<void>();
  final release = Completer<void>();
  @override
  Future<String?> getApplicationDocumentsPath() async {
    if (++calls == blockAt) {
      blocked.complete();
      await release.future;
    }
    return root;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform oldPaths;
  setUp(() async {
    final artifacts = await Directory(
            '../../docs/verification/artifacts/2026-09-10/conversation-state-main')
        .absolute
        .create(recursive: true);
    root = await artifacts.createTemp('media-clear-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
  });
  tearDown(() async {
    PathProviderPlatform.instance = oldPaths;
    await root.delete(recursive: true);
  });
  test('clear removes only selected account objects and all its refs',
      () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final a =
        await MediaCache.store('room', 'one', bytes, accountId: 'account-a');
    await MediaCache.store('room', 'two', bytes, accountId: 'account-a');
    final b =
        await MediaCache.store('room', 'one', bytes, accountId: 'account-b');
    await MediaCache.clearAccount('account-a');
    expect(await a.exists(), isFalse);
    expect(
        await MediaCache.cached('room', 'two', accountId: 'account-a'), isNull);
    expect(await b.readAsBytes(), bytes);
  });
  test('pending decrypt cannot recreate deleted account cache', () async {
    final started = Completer<void>();
    final pending = Completer<Uint8List>();
    final loading = loadMediaWithCache(
        const MediaCacheKey(
            accountId: 'account-a', roomId: 'room', eventId: 'event'), () {
      started.complete();
      return pending.future;
    });
    final assertion = expectLater(loading, throwsStateError);
    await started.future;
    await MediaCache.clearAccount('account-a');
    pending.complete(Uint8List.fromList([4, 5, 6]));
    await assertion;
    expect(await MediaCache.cached('room', 'event', accountId: 'account-a'),
        isNull);
  });
  test('late hot-media reference cannot recreate cache after clear', () async {
    final bytes = Uint8List.fromList([7, 8, 9]);
    final file =
        await MediaCache.store('room', 'event', bytes, accountId: 'account-a');
    final paths = _Paths(root.path)..blockAt = 4;
    PathProviderPlatform.instance = paths;
    final loading = loadMediaWithCache(
        MediaCacheKey(
            accountId: 'account-a',
            roomId: 'room',
            eventId: 'event',
            sourceIdentity: 'source',
            contentSha256: sha256.convert(bytes).toString()),
        () async => bytes);
    final assertion = expectLater(loading, throwsStateError);
    await paths.blocked.future;
    await MediaCache.clearAccount('account-a');
    paths.release.complete();
    await assertion;
    expect(await file.exists(), isFalse);
    expect(
        await Directory('${file.parent.parent.path}/refs').exists(), isFalse);
  });
}
