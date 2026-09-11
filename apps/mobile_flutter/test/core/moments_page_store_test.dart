import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/cache/cache_repository.dart';
import 'package:liuhetong_mobile/core/cache/moments_page_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, dynamic> page(List<String> ids, {String? next}) => {
      'items': [
        for (final id in ids)
          {
            'id': id,
            'text': 'fixture $id',
            'image_urls': ['https://fixture.invalid/$id'],
            'image_cache_keys': ['digest-$id'],
            'comments': [
              {'id': 'comment', 'text': 'fixture'}
            ]
          }
      ],
      'next_cursor': next
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late String path;
  late MomentsPageStore store;
  late CacheRepository repository;
  setUp(() async {
    path =
        '${Directory.current.path}/../../docs/verification/artifacts/2026-09-11/performance/moments-${DateTime.now().microsecondsSinceEpoch}.db';
    store = MomentsPageStore(databasePath: path);
    SharedPreferences.setMockInitialValues({});
    await CacheRepository.resetForTest(pageStore: store);
    repository = await CacheRepository.instance();
  });
  tearDown(() async {
    await store.close();
    await databaseFactoryFfi.deleteDatabase(path);
  });

  test(
      'SQLite reopen preserves browsed pages cursor images and account isolation',
      () async {
    final a = repository.momentsFor('a');
    await a.saveHead(page(['head'], next: 'cursor'));
    await a.savePage('cursor', page(['older', 'older'], next: 'tail'),
        ticket: a.currentRevision, expectedGeneration: 0);
    await store.close();
    store = MomentsPageStore(databasePath: path);
    await CacheRepository.resetForTest(pageStore: store);
    repository = await CacheRepository.instance();
    final disk = await repository.momentsFor('a').loadPage('cursor');
    expect(disk!['next_cursor'], 'tail');
    expect((disk['items'] as List).length, 1);
    expect(disk['items'][0]['image_cache_keys'], ['digest-older']);
    expect(await repository.momentsFor('b').loadPage('cursor'), isNull);
  });

  test('clear rejects queued page writes and late old generation across reopen',
      () async {
    final a = repository.momentsFor('a');
    await a.saveHead(page(['head'], next: 'cursor'));
    final ticket = a.currentRevision;
    final writing = a.savePage('cursor', page(['older']),
        ticket: ticket, expectedGeneration: 0);
    final clearing = a.clear();
    await Future.wait([writing, clearing]);
    await a.savePage('cursor', page(['late']),
        ticket: ticket, expectedGeneration: 0);
    expect(
        await store.readPage(CacheRepository.momentsFeedKeyFor('a'), 'cursor'),
        isNull);
    expect(a.snapshot, isNull);
  });

  test(
      'confirmed older deletion and comment tombstones survive restart and stale refresh',
      () async {
    final a = repository.momentsFor('a');
    await a.saveHead(page(['head'], next: 'cursor'));
    await a.savePage('cursor', page(['deleted', 'retained']),
        ticket: a.currentRevision, expectedGeneration: 0);
    await a.mutateItem('deleted', deleted: true);
    await a.mutateItem('retained', deletedComment: 'comment');
    await store.close();
    store = MomentsPageStore(databasePath: path);
    await CacheRepository.resetForTest(pageStore: store);
    final reopened = (await CacheRepository.instance()).momentsFor('a');
    await reopened.restoreInvalidations();
    await reopened.savePage('cursor', page(['deleted', 'retained']),
        ticket: reopened.currentRevision, expectedGeneration: 0);
    final disk = await reopened.loadPage('cursor');
    expect((disk!['items'] as List).map((item) => item['id']), ['retained']);
    expect(disk['items'][0]['comments'], isEmpty);
    expect(reopened.project(page(['deleted', 'retained']))['items'],
        disk['items']);
  });

  test(
      'legacy mutation invalidates all older page projections and request tickets',
      () async {
    final a = repository.momentsFor('a');
    await a.saveHead(page(['head'], next: 'cursor'));
    final ticket = a.currentRevision;
    await a.savePage('cursor', page(['older']),
        ticket: ticket, expectedGeneration: 0);
    await a.save(page(['head'], next: 'cursor'));
    await a.savePage('cursor', page(['late']),
        ticket: ticket, expectedGeneration: 0);
    expect(await a.loadPage('cursor'), isNull);
  });

  test('later entity mutation cannot revive a deleted comment on reopen',
      () async {
    final a = repository.momentsFor('a');
    await a.savePage('cursor', page(['older']),
        ticket: a.currentRevision, expectedGeneration: 0);
    await a.mutateItem('older', deletedComment: 'comment');
    await a.mutateItem('older', fields: {
      'comments': [
        {'id': 'comment', 'text': 'stale'},
        {'id': 'retained', 'text': 'valid'}
      ]
    });
    await store.close();
    store = MomentsPageStore(databasePath: path);
    await CacheRepository.resetForTest(pageStore: store);
    final reopened = (await CacheRepository.instance()).momentsFor('a');
    final disk = await reopened.loadPage('cursor');
    expect((disk!['items'][0]['comments'] as List).map((c) => c['id']),
        ['retained']);
  });

  test('restart suppresses stale head after interrupted privacy mutation',
      () async {
    final a = repository.momentsFor('a');
    await a.saveHead(page(['head']));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
        '${CacheRepository.momentsFeedKeyFor('a')}.pages-invalid', true);
    await CacheRepository.resetForTest(pageStore: store);
    final reopened = (await CacheRepository.instance()).momentsFor('a');
    expect(reopened.snapshot, isNull);
    await reopened.mutateItem('another', fields: {'like_count': 2});
    await CacheRepository.resetForTest(pageStore: store);
    expect((await CacheRepository.instance()).momentsFor('a').snapshot, isNull);
  });

  test('mutation after restart hydrates tombstones before updating head',
      () async {
    final a = repository.momentsFor('a');
    await a.saveHead(page(['head']));
    await a.mutateItem('head', deletedComment: 'comment');
    await CacheRepository.resetForTest(pageStore: store);
    final reopened = (await CacheRepository.instance()).momentsFor('a');
    await reopened.mutateItem('head', fields: {
      'comments': [
        {'id': 'comment', 'text': 'stale'},
        {'id': 'retained', 'text': 'valid'}
      ]
    });
    expect(
        (reopened.snapshot!['items'][0]['comments'] as List)
            .map((c) => c['id']),
        ['retained']);
    await CacheRepository.resetForTest(pageStore: store);
    final head = (await CacheRepository.instance()).momentsFor('a').snapshot!;
    expect((head['items'][0]['comments'] as List).map((c) => c['id']),
        ['retained']);
    final disk =
        await store.readPage(CacheRepository.momentsFeedKeyFor('a'), null);
    expect((disk!['items'][0]['comments'] as List).map((c) => c['id']),
        ['retained']);
  });

  test('head refresh after restart cannot restore durable deleted comments',
      () async {
    final a = repository.momentsFor('a');
    await a.saveHead(page(['head']));
    await a.mutateItem('head', deletedComment: 'comment');
    await CacheRepository.resetForTest(pageStore: store);
    final reopened = (await CacheRepository.instance()).momentsFor('a');
    await reopened.saveHead(page(['head']));
    expect(reopened.snapshot!['items'][0]['comments'], isEmpty);
    await CacheRepository.resetForTest(pageStore: store);
    expect(
        (await CacheRepository.instance()).momentsFor('a').snapshot!['items'][0]
            ['comments'],
        isEmpty);
  });

  test('head hydration cannot overwrite a newer confirmed mutation', () async {
    final a = repository.momentsFor('a');
    await a.saveHead(page(['head']));
    await store.close();
    final opened = Completer<void>();
    final resume = Completer<Database>();
    final factory = _DelayedFactory(() {
      opened.complete();
      return resume.future;
    });
    store = MomentsPageStore(databasePath: path, factory: factory);
    await CacheRepository.resetForTest(pageStore: store);
    final cache = (await CacheRepository.instance()).momentsFor('a');
    final refresh = cache.saveHead(page(['head']));
    await opened.future;
    final mutation = cache.mutateItem('head', fields: {'like_count': 7});
    resume.complete(await databaseFactoryFfi.openDatabase(path));
    await Future.wait([refresh, mutation]);
    expect(cache.snapshot!['items'][0]['like_count'], 7);
    await CacheRepository.resetForTest(pageStore: store);
    expect(
        (await CacheRepository.instance()).momentsFor('a').snapshot!['items'][0]
            ['like_count'],
        7);
  });

  test('transient invalidation read failure cannot persist an unfiltered head',
      () async {
    final a = repository.momentsFor('a');
    await a.saveHead(page(['head']));
    await a.mutateItem('head', deletedComment: 'comment');
    await store.close();
    final db = _ReadFailDatabase(await databaseFactoryFfi.openDatabase(path));
    store = MomentsPageStore(
        databasePath: path, factory: _DelayedFactory(() async => db));
    await CacheRepository.resetForTest(pageStore: store);
    final reopened = (await CacheRepository.instance()).momentsFor('a');
    await reopened.saveHead(page(['head']));
    expect(db.failedReads, 1);
    expect(reopened.snapshot!['items'][0]['comments'], isEmpty);
    await CacheRepository.resetForTest(pageStore: store);
    expect(
        (await CacheRepository.instance()).momentsFor('a').snapshot!['items'][0]
            ['comments'],
        isEmpty);
  });

  for (final scenario in ['other post', 'other field', 'same field']) {
    test('pending comment hydration preserves $scenario mutation ordering',
        () async {
      final a = repository.momentsFor('a');
      await a.saveHead(page(['first', 'second']));
      await store.close();
      final started = Completer<void>();
      final resume = Completer<Database>();
      store = MomentsPageStore(
          databasePath: path,
          factory: _DelayedFactory(() {
            if (!started.isCompleted) started.complete();
            return resume.future;
          }));
      await CacheRepository.resetForTest(pageStore: store);
      final cache = (await CacheRepository.instance()).momentsFor('a');
      final first = cache.mutateItem('first', fields: {
        'comments': [
          {'id': 'new-comment'}
        ]
      });
      await started.future;
      final second =
          cache.mutateItem(scenario == 'other post' ? 'second' : 'first',
              fields: scenario == 'same field'
                  ? {
                      'comments': [
                        {'id': 'latest-comment'}
                      ]
                    }
                  : {'like_count': 7});
      resume.complete(await databaseFactoryFfi.openDatabase(path));
      await Future.wait([first, second]);
      final items = cache.snapshot!['items'] as List;
      expect(items[0]['comments'][0]['id'],
          scenario == 'same field' ? 'latest-comment' : 'new-comment');
      if (scenario != 'same field') {
        expect(items[scenario == 'other post' ? 1 : 0]['like_count'], 7);
      }
      await CacheRepository.resetForTest(pageStore: store);
      expect(
          (await CacheRepository.instance()).momentsFor('a').snapshot!['items'],
          items);
    });
  }

  test('page writes preserve existing head and repeated cursor cannot loop',
      () async {
    final a = repository.momentsFor('a');
    await a.saveHead(page(['head'], next: 'cursor'));
    await a.savePage('cursor', page(['older'], next: 'cursor'),
        ticket: a.currentRevision, expectedGeneration: 0);
    expect(a.snapshot!['items'][0]['id'], 'head');
    expect((await a.loadPage('cursor'))!['next_cursor'], isNull);
    expect(a.persistenceError, isNull);
  });

  test(
      'clear during an in-flight SQLite open cannot leave a page after restart',
      () async {
    final opened = Completer<void>();
    final resume = Completer<String>();
    final delayed = MomentsPageStore(supportDirectory: () {
      opened.complete();
      return resume.future;
    });
    final prefs = await SharedPreferences.getInstance();
    final a = CacheRepository.inject(prefs, pageStore: delayed).momentsFor('a');
    final writing = a.savePage('cursor', page(['older']),
        ticket: a.currentRevision, expectedGeneration: 0);
    await opened.future;
    final clearing = a.clear();
    resume.complete(File(path).parent.path);
    await Future.wait([writing, clearing]);
    expect(
        await delayed.readPage(
            CacheRepository.momentsFeedKeyFor('a'), 'cursor'),
        isNull);
    expect(await a.loadPage('cursor'), isNull);
    await delayed.close();
    await databaseFactoryFfi.deleteDatabase(
        '${File(path).parent.path}/chatflow_moments_audience_v2.db');
  });

  test('legacy confirmed comment removal records a durable tombstone',
      () async {
    final a = repository.momentsFor('a');
    await a.saveHead(page(['head'], next: 'cursor'));
    await a.save({
      'items': [
        {'id': 'head', 'comments': []}
      ],
      'next_cursor': 'cursor'
    });
    await a.savePage('cursor', page(['head']),
        ticket: a.currentRevision, expectedGeneration: 0);
    expect(
        (await store.readPage(
                CacheRepository.momentsFeedKeyFor('a'), 'cursor'))!['items'][0]
            ['comments'],
        isEmpty);
    expect(
        (await store.readTombstones(CacheRepository.momentsFeedKeyFor('a')))
            .single['comment_id'],
        'comment');
  });

  test(
      'interrupted invalidation recovery preserves durable deletion tombstones',
      () async {
    final a = repository.momentsFor('a');
    await a.saveHead(page(['head'], next: 'cursor'));
    await a.savePage('cursor', page(['deleted']),
        ticket: a.currentRevision, expectedGeneration: 0);
    await a.mutateItem('deleted', deleted: true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(
        '${CacheRepository.momentsFeedKeyFor('a')}.pages-invalid', true);
    final reopened =
        CacheRepository.inject(prefs, pageStore: store).momentsFor('a');
    await reopened.savePage('cursor', page(['deleted', 'new']),
        ticket: reopened.currentRevision, expectedGeneration: 0);
    expect(
        (await reopened.loadPage('cursor'))!['items'].map((item) => item['id']),
        ['new']);
    expect(
        (await store.readTombstones(CacheRepository.momentsFeedKeyFor('a')))
            .single['id'],
        'deleted');
  });

  test('overlapping older pages cannot overwrite the fresher head entity',
      () async {
    final account = CacheRepository.momentsFeedKeyFor('a');
    await store.writePage(account, null, {
      'items': [
        {'id': 'same', 'text': 'new'}
      ],
      'next_cursor': 'older'
    });
    await store.writePage(account, 'older', {
      'items': [
        {'id': 'same', 'text': 'stale'}
      ]
    });
    expect((await store.readPage(account, null))!['items'][0]['text'], 'new');
  });

  test(
      'storage failure is observable and retains memory pages while clear fails closed',
      () async {
    final broken = MomentsPageStore(
        supportDirectory: () async =>
            throw FileSystemException('fixture unavailable'));
    final prefs = await SharedPreferences.getInstance();
    final a = CacheRepository.inject(prefs, pageStore: broken).momentsFor('a');
    await a.saveHead(page(['head'], next: 'cursor'));
    await a.savePage('cursor', page(['older']),
        ticket: a.currentRevision, expectedGeneration: 0);
    expect(a.persistenceError, isA<FileSystemException>());
    expect((await a.loadPage('cursor'))!['items'], isNotEmpty);
    await a.clear();
    expect(await a.loadPage('cursor'), isNull);
    // Existing disk pages cannot reappear after a failed privacy clear.
    await store.writePage(
        CacheRepository.momentsFeedKeyFor('a'), 'cursor', page(['stale']));
    final reopened =
        CacheRepository.inject(prefs, pageStore: store).momentsFor('a');
    expect(await reopened.loadPage('cursor'), isNull);
  });
}

final class _DelayedFactory implements DatabaseFactory {
  _DelayedFactory(this.open);
  final Future<Database> Function() open;
  @override
  Future<Database> openDatabase(String path, {OpenDatabaseOptions? options}) =>
      open();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ReadFailDatabase implements Database {
  _ReadFailDatabase(this.inner);
  final Database inner;
  int failedReads = 0;
  @override
  Future<List<Map<String, Object?>>> query(String table,
      {bool? distinct,
      List<String>? columns,
      String? where,
      List<Object?>? whereArgs,
      String? groupBy,
      String? having,
      String? orderBy,
      int? limit,
      int? offset}) async {
    if (table == 'tombstones' && failedReads++ == 0) {
      throw StateError('fixture transient read failure');
    }
    return inner.query(table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset);
  }

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
          {bool? exclusive}) =>
      inner.transaction(action, exclusive: exclusive);
  @override
  Future<void> close() => inner.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
