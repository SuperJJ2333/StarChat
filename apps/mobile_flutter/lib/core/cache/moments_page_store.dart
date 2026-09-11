import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Account-scoped feed metadata. Images remain in the shared media cache.
/// Each append writes only its own page and entities, never the entire history.
final class MomentsPageStore {
  MomentsPageStore(
      {String? databasePath,
      DatabaseFactory? factory,
      Future<String> Function()? supportDirectory})
      : _path = databasePath,
        _factory = factory ?? databaseFactoryFfi,
        _directory = supportDirectory ?? _defaultDirectory;

  static Future<String> _defaultDirectory() async =>
      (await getApplicationSupportDirectory()).path;
  final String? _path;
  final DatabaseFactory _factory;
  final Future<String> Function() _directory;
  Future<Database>? _opening;

  Future<Database> _open() =>
      _opening ??= _openDatabase().catchError((Object e) {
        _opening = null;
        throw e;
      });

  Future<Database> _openDatabase() async => _factory.openDatabase(
      _path ?? p.join(await _directory(), 'chatflow_moments_audience_v2.db'),
      options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute(
                'CREATE TABLE pages (account TEXT NOT NULL, cursor TEXT NOT NULL, metadata TEXT NOT NULL, revision INTEGER NOT NULL, PRIMARY KEY(account,cursor))');
            await db.execute(
                'CREATE TABLE items (account TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(account,id))');
            await db.execute(
                'CREATE TABLE page_items (account TEXT NOT NULL, cursor TEXT NOT NULL, id TEXT NOT NULL, position INTEGER NOT NULL, PRIMARY KEY(account,cursor,id))');
            await db.execute(
                'CREATE TABLE tombstones (account TEXT NOT NULL, id TEXT NOT NULL, comment_id TEXT NOT NULL, PRIMARY KEY(account,id,comment_id))');
          }));

  Future<Map<String, dynamic>?> readPage(String account, String? cursor) async {
    final db = await _open();
    return db.transaction((tx) async {
      final pages = await tx.query('pages',
          where: 'account=? AND cursor=?', whereArgs: [account, cursor ?? '']);
      if (pages.isEmpty) return null;
      final rows = await tx.rawQuery(
          'SELECT i.payload FROM page_items p JOIN items i ON i.account=p.account AND i.id=p.id WHERE p.account=? AND p.cursor=? ORDER BY p.position',
          [account, cursor ?? '']);
      return {
        ...jsonDecode(pages.single['metadata'] as String)
            as Map<String, dynamic>,
        'items': [for (final row in rows) jsonDecode(row['payload'] as String)]
      };
    });
  }

  Future<List<Map<String, Object?>>> readTombstones(String account) async =>
      (await _open())
          .query('tombstones', where: 'account=?', whereArgs: [account]);

  Future<Map<String, dynamic>> writePage(
      String account, String? cursor, Map<String, dynamic> page,
      {bool invalidateOlder = false}) async {
    final db = await _open();
    return db.transaction((tx) async {
      final previous = await tx.rawQuery(
          'SELECT MAX(revision) AS revision FROM pages WHERE account=?',
          [account]);
      final revision = (previous.single['revision'] as int? ?? 0) + 1;
      if (invalidateOlder) {
        await tx.delete('pages', where: 'account=?', whereArgs: [account]);
        await tx.delete('page_items', where: 'account=?', whereArgs: [account]);
        await tx.delete('items', where: 'account=?', whereArgs: [account]);
      }
      final key = cursor ?? '';
      await tx.delete('page_items',
          where: 'account=? AND cursor=?', whereArgs: [account, key]);
      final metadata = {...page}..remove('items');
      // A repeated cursor must never trigger an unbounded pagination loop.
      if (cursor != null && metadata['next_cursor'] == cursor) {
        metadata['next_cursor'] = null;
      }
      await tx.insert(
          'pages',
          {
            'account': account,
            'cursor': key,
            'metadata': jsonEncode(metadata),
            'revision': revision
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      final unique = <String, Map<String, dynamic>>{};
      for (final raw in page['items'] as List? ?? const []) {
        if (raw is! Map || raw['id'] == null) continue;
        final id = raw['id'].toString();
        final tombstones = await tx.query('tombstones',
            where: 'account=? AND id=?', whereArgs: [account, id]);
        if (tombstones.any((row) => row['comment_id'] == '')) continue;
        final removedComments =
            tombstones.map((row) => row['comment_id']).toSet();
        unique[id] = {
          ...Map<String, dynamic>.from(raw),
          if (raw['comments'] is List)
            'comments': [
              for (final comment in raw['comments'] as List)
                if (comment is! Map ||
                    !removedComments.contains(comment['id']?.toString()))
                  comment
            ]
        };
      }
      var position = 0;
      for (final entry in unique.entries) {
        if (cursor != null) {
          final head = await tx.rawQuery(
              'SELECT i.payload FROM items i JOIN page_items p ON i.account=p.account AND i.id=p.id WHERE i.account=? AND i.id=? AND p.cursor=?',
              [account, entry.key, '']);
          if (head.isNotEmpty) {
            unique[entry.key] = jsonDecode(head.single['payload'] as String)
                as Map<String, dynamic>;
          }
        }
        await tx.insert(
            'items',
            {
              'account': account,
              'id': entry.key,
              'payload': jsonEncode(unique[entry.key])
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        await tx.insert('page_items', {
          'account': account,
          'cursor': key,
          'id': entry.key,
          'position': position++
        });
      }
      return {...metadata, 'items': unique.values.toList()};
    });
  }

  /// Confirmed mutations apply to every page referencing an entity. Deletions
  /// leave permanent local tombstones until account cache/privacy clear.
  Future<void> mutate(String account, String id,
      {Map<String, dynamic>? fields,
      bool deleted = false,
      String? deletedComment}) async {
    final db = await _open();
    await db.transaction((tx) async {
      if (deleted || deletedComment != null) {
        await tx.insert(
            'tombstones',
            {
              'account': account,
              'id': id,
              'comment_id': deleted ? '' : deletedComment!
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      if (deleted) {
        await tx.delete('items',
            where: 'account=? AND id=?', whereArgs: [account, id]);
        await tx.delete('page_items',
            where: 'account=? AND id=?', whereArgs: [account, id]);
        return;
      }
      final rows = await tx.query('items',
          where: 'account=? AND id=?', whereArgs: [account, id]);
      if (rows.isEmpty) return;
      final item = {
        ...jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>,
        ...?fields
      };
      final tombstones = await tx.query('tombstones',
          where: 'account=? AND id=?', whereArgs: [account, id]);
      final removedComments =
          tombstones.map((row) => row['comment_id'].toString()).toSet();
      if (removedComments.isNotEmpty) {
        item['comments'] = [
          for (final comment in item['comments'] as List? ?? const [])
            if (comment is! Map ||
                !removedComments.contains(comment['id'].toString()))
              comment
        ];
      }
      await tx.update('items', {'payload': jsonEncode(item)},
          where: 'account=? AND id=?', whereArgs: [account, id]);
    });
  }

  Future<void> clear(String account) async {
    final db = await _open();
    await db.transaction((tx) async {
      for (final table in ['pages', 'page_items', 'items', 'tombstones']) {
        await tx.delete(table, where: 'account=?', whereArgs: [account]);
      }
    });
  }

  /// Recovery after an interrupted projection mutation discards page data while
  /// preserving already confirmed deletions.
  Future<void> invalidatePages(String account) async {
    final db = await _open();
    await db.transaction((tx) async {
      for (final table in ['pages', 'page_items', 'items']) {
        await tx.delete(table, where: 'account=?', whereArgs: [account]);
      }
    });
  }

  Future<void> close() async {
    final opening = _opening;
    if (opening != null) await (await opening).close();
    _opening = null;
  }
}
