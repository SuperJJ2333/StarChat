import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:liuhetong_mobile/features/matrix/media_cache.dart';
import 'package:liuhetong_mobile/features/matrix/media_disk_quota_index.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

final class _RealIo extends IOOverrides {}

class _DirectoryCounter implements Directory {
  _DirectoryCounter(this.directory, this.onList, {this.afterList});
  final Directory directory;
  final void Function() onList;
  final Future<void> Function()? afterList;
  @override
  String get path => directory.path;
  @override
  Directory get parent => directory.parent;
  @override
  Future<bool> exists() => directory.exists();
  @override
  Future<Directory> create({bool recursive = false}) =>
      directory.create(recursive: recursive);
  @override
  Stream<FileSystemEntity> list(
      {bool recursive = false, bool followLinks = true}) async* {
    onList();
    yield* directory.list(recursive: recursive, followLinks: followLinks);
    await afterList?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final realZone = Zone.current;
  Future<FileSystemEntityType> realType(String path, bool followLinks) =>
      realZone.run(() => FileSystemEntity.type(path, followLinks: followLinks));
  late Directory root;
  late PathProviderPlatform oldPaths;
  String digest(String value) => sha256.convert(utf8.encode(value)).toString();
  MediaDiskQuotaIndex index() =>
      MediaDiskQuotaIndex(Directory('${root.path}/chat-media'),
          factory: databaseFactoryFfiNoIsolate);
  Future<MediaDiskObject> object(String account, String name, int bytes) async {
    final entry =
        MediaDiskObject(digest(account), digest(name), bytes, DateTime.now());
    final file = File(index().pathFor(entry));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(bytes, 7), flush: true);
    return MediaDiskObject(
        entry.namespace, entry.name, bytes, (await file.stat()).modified);
  }

  setUp(() async {
    final artifacts = await Directory(
      '../../docs/verification/artifacts/2026-10-11/im-media-cache-index',
    ).absolute.create(recursive: true);
    root = await artifacts.createTemp('quota-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
  });
  tearDown(() async {
    PathProviderPlatform.instance = oldPaths;
    MediaCache.resetQuotaPolicy();
    clearMediaMemoryCaches();
    await MediaCache.closeQuotaIndexes();
    await root.delete(recursive: true);
  });

  test('warm stores do not enumerate cache directories per object or reference',
      () async {
    // Observe real Directory.list calls rather than production test counters.
    var enumerations = 0;
    await IOOverrides.runZoned(
        () async {
          await MediaCache.store('r', 'warm', Uint8List.fromList([0]),
              accountId: 'a');
          enumerations = 0;
          for (var i = 1; i <= 12; i++) {
            await MediaCache.store('r', '$i', Uint8List.fromList([i]),
                accountId: 'a');
          }
          await MediaCache.store('r', 'same-object', Uint8List.fromList([12]),
              accountId: 'a');
          expect(enumerations, 0,
              reason: 'incremental writes must not rescan objects');
        },
        fseGetType: realType,
        createDirectory: (path) {
          final real = _RealIo().createDirectory(path);
          return _DirectoryCounter(real, () => enumerations++);
        });
  });

  test(
      'one physical object is counted once across refs and survives restart without a walk',
      () async {
    final payload = Uint8List.fromList([1, 2, 3]);
    for (var i = 0; i < 8; i++) {
      await MediaCache.store('r', '$i', payload, accountId: 'a');
    }
    expect(await MediaCache.totalCachedBytes(), 3);
    await MediaCache.closeQuotaIndexes();
    var walks = 0;
    await IOOverrides.runZoned(() async {
      expect(await MediaCache.totalCachedBytes(), 3);
      expect(walks, 0);
    },
        fseGetType: realType,
        createDirectory: (path) =>
            _DirectoryCounter(_RealIo().createDirectory(path), () => walks++));
  });

  test(
      'corrupt database and interrupted mutation rebuild only owned cache objects',
      () async {
    final a = await object('a', 'a', 17);
    final b = await object('b', 'b', 23);
    final pending = File('${root.path}/chat-media/pending-media/source.bin');
    await pending.parent.create(recursive: true);
    await pending.writeAsString('unique pending original');
    final source = File('${root.path}/chat-media/source.bin');
    await source.writeAsString('source outside managed cache');
    var quota = index();
    await quota.ready();
    expect(quota.totalBytes, 40);
    await quota.close();
    await File(quota.databasePath).writeAsString('corrupt sqlite', flush: true);
    quota = index();
    await quota.ready();
    expect(quota.accountBytes(a.namespace), 17);
    expect(quota.accountBytes(b.namespace), 23);
    await expectLater(quota.mutate(() async {
      await object('a', 'new-before-index-commit', 9);
      throw StateError('synthetic process boundary');
    }), throwsStateError);
    // A later success cannot clear the durable evidence of the interrupted write.
    await quota.mutate(() => quota.upsert(b));
    await quota.close();
    quota = index();
    await quota.ready();
    expect(quota.totalBytes, 49);
    expect(await pending.readAsString(), 'unique pending original');
    expect(await source.readAsString(), 'source outside managed cache');
    await quota.close();
  });

  test(
      'background calibration merges a simultaneous clear and write without resurrection',
      () async {
    final old = await object('a', 'old', 11);
    await object('b', 'old-b', 7);
    final quota = index();
    await quota.ready();
    final started = Completer<void>();
    final resume = Completer<void>();
    final calibration = IOOverrides.runZoned(() => quota.reconcile(),
        fseGetType: realType,
        createDirectory: (path) => _DirectoryCounter(
                _RealIo().createDirectory(path), () {}, afterList: () async {
              if (!started.isCompleted &&
                  path.contains(old.namespace) &&
                  path.endsWith('objects')) {
                started.complete();
                await resume.future;
              }
            }));
    await started.future.timeout(const Duration(seconds: 3));
    // Mutation can finish while directory work is suspended: no quota-lock scan.
    await quota.mutate(() async {
      await Directory('${root.path}/chat-media/v2/${old.namespace}')
          .delete(recursive: true);
      await quota.clearAccount(old.namespace);
      await quota.upsert(await object('b', 'new-b', 5));
    }).timeout(const Duration(seconds: 3));
    resume.complete();
    await calibration;
    expect(quota.accountBytes(old.namespace), 0);
    expect(quota.totalBytes, 12);
    await quota.close();
  });

  test(
      'calibration repairs a rename and external length drift without double counting',
      () async {
    final entry = await object('a', 'video', 16);
    final quota = index();
    await quota.ready();
    final renamed =
        await File(quota.pathFor(entry)).rename('${quota.pathFor(entry)}.mp4');
    await renamed.writeAsBytes(List.filled(20, 8));
    await quota.reconcile();
    expect(quota.totalBytes, 20);
    expect(quota.objects.single.name, '${entry.name}.mp4');
    expect(await renamed.length(), 20);
    await quota.close();
  });

  test(
      'calibration never follows an objects directory link into pending originals',
      () async {
    final entry = await object('a', 'offline', 19);
    final quota = index();
    await quota.ready();
    final objects = Directory(File(quota.pathFor(entry)).parent.path);
    final pending = Directory('${root.path}/pending-media');
    await pending.create(recursive: true);
    final original = File('${pending.path}/${entry.name}');
    await original.writeAsString('unique pending original');
    await objects.delete(recursive: true);
    final link = Link(objects.path);
    await link.create(pending.absolute.path);
    try {
      expect(await quota.hasManagedParents(entry), isFalse);
      await quota.reconcile();
      expect(quota.totalBytes, 0);
      expect(await original.readAsString(), 'unique pending original');
    } finally {
      await link.delete();
      await quota.close();
    }
  });

  test(
      'failed recalibration revokes existing eviction eligibility until recovery',
      () async {
    final entry = await object('a', 'already-indexed', 19);
    final quota = index();
    await quota.ready();
    expect(quota.canEvict, isTrue);
    await IOOverrides.runZoned(() async {
      await expectLater(quota.reconcile(), throwsA(isA<FileSystemException>()));
    },
        fseGetType: realType,
        createDirectory: (path) =>
            _DirectoryCounter(_RealIo().createDirectory(path), () {
              if (path.endsWith('v2')) {
                throw const FileSystemException(
                    'synthetic initialized scan failure');
              }
            }));
    expect(quota.canEvict, isFalse,
        reason:
            'an old complete snapshot is unsafe after a failed calibration');
    expect(await File(quota.pathFor(entry)).length(), 19);
    expect(quota.totalBytes, 19,
        reason: 'failure does not commit an empty snapshot');
    await quota.reconcile();
    expect(quota.canEvict, isTrue);
    expect(quota.totalBytes, 19);
    await quota.close();
  });

  test('an unreadable calibration preserves files and can recover later',
      () async {
    final entry = await object('a', 'offline', 19);
    final quota = index();
    await IOOverrides.runZoned(() => quota.ready(),
        fseGetType: realType,
        createDirectory: (path) =>
            _DirectoryCounter(_RealIo().createDirectory(path), () {
              if (path.endsWith('v2')) {
                throw const FileSystemException(
                    'synthetic unreadable directory');
              }
            }));
    expect(await File(quota.pathFor(entry)).length(), 19);
    await quota.reconcile();
    expect(quota.totalBytes, 19);
    await quota.close();
  });

  test(
      'concurrent stores respect account and device totals and keep pinned/off-domain files',
      () async {
    MediaCache.useQuotaForTest(accountSoft: 30, deviceHard: 50);
    final pinned = await MediaCache.store(
        'r', 'pinned', Uint8List.fromList(List.filled(10, 99)),
        accountId: 'a');
    final pin = MediaCache.pinPath(pinned.path);
    final pending = File('${root.path}/chat-media/pending-media/source');
    await pending.parent.create(recursive: true);
    await pending.writeAsString('pending');
    await Future.wait(List.generate(
        24,
        (i) => MediaCache.store(
            'r', '$i', Uint8List.fromList(List.filled(10, i)),
            accountId: i.isEven ? 'a' : 'b')));
    expect(await MediaCache.totalCachedBytes(), lessThanOrEqualTo(50));
    final quota = index();
    await quota.ready();
    expect(quota.accountBytes(digest('a')), lessThanOrEqualTo(30));
    expect(quota.accountBytes(digest('b')), lessThanOrEqualTo(30));
    expect(await pinned.exists(), isTrue);
    expect(await pending.readAsString(), 'pending');
    pin.release();
    await quota.close();
    await MediaCache.clearAccount('a');
    final remaining = await MediaCache.totalCachedBytes();
    expect(remaining, lessThanOrEqualTo(30));
    expect(await pending.exists(), isTrue);
  });
}
