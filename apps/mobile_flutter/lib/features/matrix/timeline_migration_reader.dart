import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:matrix/matrix.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:sqlite3/open.dart' as loader;

/// A local-only worker reads the retained SQLCipher source directly. No source
/// row, cipher, identity or event contents is logged or returned as an error.
Stream<List<String>> readEncryptedTimelineIds(
    {required String path,
    required String cipher,
    required String fragment,
    String? userId,
    String? deviceId}) async* {
  final messages = ReceivePort();
  final worker = await Isolate.spawn(_readTimelineWorker,
      [messages.sendPort, path, cipher, fragment, userId, deviceId]);
  SendPort? commands;
  bool done = false;
  final iterator = StreamIterator<dynamic>(messages);
  try {
    while (await iterator.moveNext()) {
      final message = iterator.current;
      if (message is SendPort) {
        commands = message;
        commands.send(true);
        continue;
      }
      if (message == null) {
        done = true;
        break;
      }
      if (message is! List<String>) {
        throw StateError('Encrypted timeline migration failed');
      }
      yield message;
      commands!.send(true);
    }
  } finally {
    commands?.send(false);
    if (!done) {
      try {
        await (() async {
          while (await iterator.moveNext()) {
            if (iterator.current == null) break;
          }
        })()
            .timeout(const Duration(seconds: 2));
      } on TimeoutException {
        worker.kill(priority: Isolate.immediate);
      }
    }
    await iterator.cancel();
    messages.close();
  }
}

typedef _KeyNative = Int32 Function(Pointer<Void>, Pointer<Void>, Int32);
typedef _KeyDart = int Function(Pointer<Void>, Pointer<Void>, int);
typedef _BlobOpenNative = Int32 Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, Int64, Int32, Pointer<Pointer<Void>>);
typedef _BlobOpenDart = int Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, int, int, Pointer<Pointer<Void>>);
typedef _BlobReadNative = Int32 Function(
    Pointer<Void>, Pointer<Void>, Int32, Int32);
typedef _BlobReadDart = int Function(Pointer<Void>, Pointer<Void>, int, int);
typedef _BlobCloseNative = Int32 Function(Pointer<Void>);
typedef _BlobCloseDart = int Function(Pointer<Void>);
typedef _BlobBytesNative = Int32 Function(Pointer<Void>);
typedef _BlobBytesDart = int Function(Pointer<Void>);

Future<void> _readTimelineWorker(List<Object?> args) async {
  final output = args[0] as SendPort;
  final commands = ReceivePort();
  final ack = StreamIterator<dynamic>(commands);
  sqlite.Database? db;
  Pointer<Uint8>? buffer;
  Pointer<Pointer<Void>>? blob;
  Pointer<Utf8>? schema, table, column;
  try {
    SQfLiteEncryptionHelper.ffiInit();
    final library = loader.open.openSqlite();
    db = sqlite.sqlite3.open(args[1] as String, mode: sqlite.OpenMode.readOnly);
    if (db.select('PRAGMA cipher_version').isEmpty) {
      throw StateError('Cipher unavailable');
    }
    final cipher = (args[2] as String).toNativeUtf8();
    try {
      final key = library.lookupFunction<_KeyNative, _KeyDart>('sqlite3_key');
      if (key(db.handle.cast(), cipher.cast(),
              utf8.encode(args[2] as String).length) !=
          0) {
        throw StateError('Cipher unavailable');
      }
    } finally {
      calloc.free(cipher);
    }
    final identity = db.select(
        "SELECT k,v FROM box_client WHERE k IN ('user_id','device_id')");
    final values = {for (final row in identity) row['k']: row['v']};
    if (values['user_id'] != args[4] || values['device_id'] != args[5]) {
      throw StateError('Identity changed');
    }
    final fragment = args[3] as String;
    final source = db.select(
        'SELECT rowid FROM box_timeline_fragments WHERE k=?', [fragment]);
    if (source.isEmpty) return;
    final sourceRevision = db.select(
        'SELECT revision FROM matrix_timeline_legacy_revision WHERE fragment_key=?',
        [fragment]);
    final revision =
        sourceRevision.isEmpty ? 0 : sourceRevision.single['revision'];
    final rowid = source.single['rowid'] as int;
    final openBlob = library
        .lookupFunction<_BlobOpenNative, _BlobOpenDart>('sqlite3_blob_open');
    final readBlob = library
        .lookupFunction<_BlobReadNative, _BlobReadDart>('sqlite3_blob_read');
    final closeBlob = library
        .lookupFunction<_BlobCloseNative, _BlobCloseDart>('sqlite3_blob_close');
    final blobBytes = library
        .lookupFunction<_BlobBytesNative, _BlobBytesDart>('sqlite3_blob_bytes');
    schema = 'main'.toNativeUtf8();
    table = 'box_timeline_fragments'.toNativeUtf8();
    column = 'v'.toNativeUtf8();
    buffer = calloc<Uint8>(32768);
    blob = calloc<Pointer<Void>>();
    // Inspect byte length without materializing the legacy TEXT as a BLOB.
    if (openBlob(db.handle.cast(), schema, table, column, rowid, 0, blob) !=
        0) {
      throw StateError('Source unavailable');
    }
    late final int total;
    try {
      total = blobBytes(blob.value);
    } finally {
      closeBlob(blob.value);
    }
    final parser = TimelineStringArrayParser();
    output.send(commands.sendPort);
    if (!await ack.moveNext() || ack.current != true) return;
    var offset = 0;
    while (offset < total) {
      final current = db.select(
          'SELECT COALESCE(r.revision,0) AS revision,t.rowid AS source_row FROM box_timeline_fragments t LEFT JOIN matrix_timeline_legacy_revision r ON r.fragment_key=t.k WHERE t.k=?',
          [fragment]);
      if (current.isEmpty ||
          current.single['revision'] != revision ||
          current.single['source_row'] != rowid) {
        throw StateError('Source changed');
      }
      final size = min(32768, total - offset);
      if (openBlob(db.handle.cast(), schema, table, column, rowid, 0, blob) !=
          0) {
        throw StateError('Source unavailable');
      }
      try {
        if (readBlob(blob.value, buffer.cast(), size, offset) != 0) {
          throw StateError('Source changed');
        }
      } finally {
        closeBlob(blob.value);
      }
      // blob_close releases the read transaction before any ACK wait.
      offset += size;
      for (final page in parser.add(buffer.asTypedList(size))) {
        output.send(page);
        if (!await ack.moveNext() || ack.current != true) return;
      }
      await Future<void>.delayed(Duration.zero);
    }
    for (final page in parser.finish()) {
      output.send(page);
      if (!await ack.moveNext() || ack.current != true) return;
    }
  } catch (_) {
    output.send(false);
  } finally {
    if (buffer != null) calloc.free(buffer);
    if (blob != null) calloc.free(blob);
    if (schema != null) calloc.free(schema);
    if (table != null) calloc.free(table);
    if (column != null) calloc.free(column);
    db?.dispose();
    await ack.cancel();
    commands.close();
    output.send(null);
  }
}

/// Explicit maintenance after disposing the active client. Event bodies and
/// keys stay in the same SQLCipher database; only aggregate counts are returned.
Future<({int fragments, int events})> projectEncryptedTimelineForLegacyRollback(
    {required String path,
    required String cipher,
    required bool clientClosed,
    String? userId,
    String? deviceId}) async {
  if (!clientClosed) {
    throw StateError('Close the Matrix client before legacy projection');
  }
  final result =
      await Isolate.run(() => _projectLegacy([path, cipher, userId, deviceId]));
  if (result == null) throw StateError('Encrypted legacy projection failed');
  return (fragments: result[0], events: result[1]);
}

typedef _BlobWriteNative = Int32 Function(
    Pointer<Void>, Pointer<Void>, Int32, Int32);
typedef _BlobWriteDart = int Function(Pointer<Void>, Pointer<Void>, int, int);

const _legacyBloomBytes = 2 * 1024 * 1024;
Iterable<int> _bloomLocations(String id) sync* {
  var first = 2166136261, second = 5381;
  for (final byte in utf8.encode(id)) {
    first = ((first ^ byte) * 16777619) & 0xffffffff;
    second = ((second * 33) ^ byte) & 0xffffffff;
  }
  second |= 1;
  for (var i = 0; i < 7; i++) {
    yield (first + i * second) & (_legacyBloomBytes * 8 - 1);
  }
}

/// Byte-offset checkpoints make repeated old-page reads independent of total
/// history. One token is capped at64KiB; no room-sized JSON value is decoded.
Iterable<({String id, int byteOffset})> _legacyBlobItems(
    sqlite.Database db, DynamicLibrary library, String fragment,
    {int byteOffset = 0,
    void Function(void Function())? registerCleanup}) sync* {
  final rowid = db.select('SELECT rowid FROM box_timeline_fragments WHERE k=?',
      [fragment]).single['rowid'] as int;
  final open = library
      .lookupFunction<_BlobOpenNative, _BlobOpenDart>('sqlite3_blob_open');
  final read = library
      .lookupFunction<_BlobReadNative, _BlobReadDart>('sqlite3_blob_read');
  final close = library
      .lookupFunction<_BlobCloseNative, _BlobCloseDart>('sqlite3_blob_close');
  final bytes = library
      .lookupFunction<_BlobBytesNative, _BlobBytesDart>('sqlite3_blob_bytes');
  final schema = 'main'.toNativeUtf8(),
      table = 'box_timeline_fragments'.toNativeUtf8(),
      column = 'v'.toNativeUtf8();
  final buffer = calloc<Uint8>(32768), blob = calloc<Pointer<Void>>();
  var disposed = false;
  void cleanup() {
    if (disposed) return;
    disposed = true;
    calloc.free(schema);
    calloc.free(table);
    calloc.free(column);
    calloc.free(buffer);
    calloc.free(blob);
  }

  registerCleanup?.call(cleanup);
  try {
    if (open(db.handle.cast(), schema, table, column, rowid, 0, blob) != 0) {
      throw StateError('Source unavailable');
    }
    late final int total;
    try {
      total = bytes(blob.value);
    } finally {
      close(blob.value);
    }
    final token = <int>[];
    var inString = false, escaped = false, start = 0;
    var started = byteOffset > 0,
        ended = false,
        expectValue = true,
        hasValue = false;
    for (var offset = byteOffset; offset < total;) {
      final size = min(32768, total - offset);
      if (open(db.handle.cast(), schema, table, column, rowid, 0, blob) != 0) {
        throw StateError('Source unavailable');
      }
      try {
        if (read(blob.value, buffer.cast(), size, offset) != 0) {
          throw StateError('Source changed');
        }
      } finally {
        close(blob.value);
      }
      final chunk = buffer.asTypedList(size);
      for (var index = 0; index < chunk.length; index++) {
        final value = chunk[index];
        if (inString) {
          if (token.length >= 4096) {
            throw StateError('Timeline ID exceeds bounded token limit');
          }
          token.add(value);
          if (escaped) {
            escaped = false;
            continue;
          }
          if (value == 92) {
            escaped = true;
            continue;
          }
          if (value != 34) continue;
          inString = false;
          expectValue = false;
          hasValue = true;
          yield (
            id: jsonDecode(utf8.decode(token)) as String,
            byteOffset: start
          );
          token.clear();
          continue;
        }
        if (value == 32 || value == 9 || value == 10 || value == 13) continue;
        if (!started && value == 91) {
          started = true;
          continue;
        }
        if (!started || ended) throw StateError('Invalid timeline source');
        if (value == 93 && (!expectValue || !hasValue)) {
          ended = true;
          continue;
        }
        if (value == 44 && !expectValue) {
          expectValue = true;
          continue;
        }
        if (value == 34 && expectValue) {
          inString = true;
          start = offset + index;
          token.add(value);
          continue;
        }
        throw StateError('Invalid timeline source');
      }
      offset += size;
    }
    if (!ended || inString) throw StateError('Incomplete timeline source');
  } finally {
    cleanup();
  }
}

Future<TimelineLegacyPage> readEncryptedTimelinePage(
    {required String path,
    required String cipher,
    required String fragment,
    required String sourceIdentity,
    int start = 0,
    int limit = 256,
    List<String>? findEventIds,
    bool reverse = false,
    bool Function()? isCancelled,
    String? userId,
    String? deviceId}) async {
  if (limit < 1 || limit > 256 || (findEventIds?.length ?? 0) > 256) {
    throw RangeError('Maximum256 legacy IDs');
  }
  if (isCancelled?.call() == true) throw TimelineStorageClosed();
  final messages = ReceivePort(), result = Completer<TimelineLegacyPage?>();
  SendPort? commands;
  final subscription = messages.listen((message) {
    if (message is SendPort) {
      commands = message;
      if (isCancelled?.call() == true) commands!.send(false);
    } else if (!result.isCompleted) {
      result.complete(message is TimelineLegacyPage ? message : null);
    }
  });
  final timer = isCancelled == null
      ? null
      : Timer.periodic(const Duration(milliseconds: 25), (_) {
          if (isCancelled() == true) commands?.send(false);
        });
  try {
    await Isolate.spawn(
        _readLegacyWindowWorker,
        [
          messages.sendPort,
          path,
          cipher,
          fragment,
          sourceIdentity,
          start,
          limit,
          findEventIds,
          reverse,
          userId,
          deviceId
        ],
        onExit: messages.sendPort);
    final page = await result.future;
    if (isCancelled?.call() == true) throw TimelineStorageClosed();
    if (page == null) throw StateError('Encrypted timeline page unavailable');
    return page;
  } finally {
    commands?.send(false);
    timer?.cancel();
    await subscription.cancel();
    messages.close();
  }
}

Future<void> _readLegacyWindowWorker(List<Object?> args) async {
  final output = args.first as SendPort, commands = ReceivePort();
  var cancelled = false;
  final subscription = commands.listen((_) {
    cancelled = true;
  });
  output.send(commands.sendPort);
  try {
    for (var attempt = 0; attempt < 10 && !cancelled; attempt++) {
      try {
        final result =
            await _readLegacyWindow(args.sublist(1), () => cancelled);
        if (!cancelled) output.send(result);
        return;
      } on sqlite.SqliteException catch (error) {
        if (error.resultCode != 5 && error.resultCode != 6 || attempt == 9) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
    output.send(false);
  } catch (_) {
    output.send(false);
  } finally {
    await subscription.cancel();
    commands.close();
  }
}

Future<TimelineLegacyPage> _readLegacyWindow(
    List<Object?> args, bool Function() isCancelled) async {
  sqlite.Database? db, cache;
  void Function()? sourceCleanup;
  try {
    SQfLiteEncryptionHelper.ffiInit();
    final library = loader.open.openSqlite();
    db = sqlite.sqlite3.open(args[0] as String, mode: sqlite.OpenMode.readOnly);
    db.execute('PRAGMA busy_timeout=25');
    if (db.select('PRAGMA cipher_version').isEmpty) {
      throw StateError('Cipher unavailable');
    }
    final cipher = (args[1] as String).toNativeUtf8();
    try {
      final key = library.lookupFunction<_KeyNative, _KeyDart>('sqlite3_key');
      if (key(db.handle.cast(), cipher.cast(),
              utf8.encode(args[1] as String).length) !=
          0) {
        throw StateError('Cipher unavailable');
      }
    } finally {
      calloc.free(cipher);
    }
    final identityRows = db.select(
        "SELECT k,v FROM box_client WHERE k IN ('user_id','device_id')");
    final identity = {for (final row in identityRows) row['k']: row['v']};
    if (identity['user_id'] != args[8] || identity['device_id'] != args[9]) {
      throw StateError('Identity changed');
    }
    void checkSource() {
      final source = db!.select(
          'SELECT CAST(t.rowid AS TEXT)||\':\'||COALESCE(r.revision,0) AS identity '
          'FROM box_timeline_fragments t LEFT JOIN matrix_timeline_legacy_revision r ON r.fragment_key=t.k WHERE t.k=?',
          [args[2]]);
      if (source.isEmpty || source.single['identity'] != args[3]) {
        throw StateError('Source changed');
      }
    }

    checkSource();
    final fragment = args[2] as String, source = args[3] as String;
    final sourceFile = File(args[0] as String).openSync();
    late final String cacheSource;
    try {
      cacheSource = jsonEncode([
        sourceFile
            .readSync(16)
            .map((v) => v.toRadixString(16).padLeft(2, '0'))
            .join(),
        source,
        identity['user_id'],
        identity['device_id']
      ]);
    } finally {
      sourceFile.closeSync();
    }
    cache = sqlite.sqlite3.open('${args[0]}.timeline_pages.sqlite');
    final cacheKey = (args[1] as String).toNativeUtf8();
    try {
      final key = library.lookupFunction<_KeyNative, _KeyDart>('sqlite3_key');
      if (key(cache.handle.cast(), cacheKey.cast(),
              utf8.encode(args[1] as String).length) !=
          0) {
        throw StateError('Cipher unavailable');
      }
    } finally {
      calloc.free(cacheKey);
    }
    cache.execute('PRAGMA busy_timeout=25');
    cache.execute('PRAGMA cache_size=-1024');
    cache.execute('PRAGMA journal_mode=WAL');
    cache.execute('CREATE TABLE IF NOT EXISTS matrix_timeline_legacy_seek '
        '(fragment_key TEXT NOT NULL,source_identity TEXT NOT NULL,ordinal INTEGER NOT NULL,byte_offset INTEGER NOT NULL,PRIMARY KEY(fragment_key,source_identity,ordinal))');
    cache.execute(
        'CREATE TABLE IF NOT EXISTS matrix_timeline_legacy_bloom_state '
        '(fragment_key TEXT NOT NULL,source_identity TEXT NOT NULL,item_count INTEGER NOT NULL,PRIMARY KEY(fragment_key,source_identity))');
    cache.execute(
        'CREATE TABLE IF NOT EXISTS matrix_timeline_legacy_bloom_parts '
        '(fragment_key TEXT NOT NULL,source_identity TEXT NOT NULL,part INTEGER NOT NULL,v BLOB NOT NULL,PRIMARY KEY(fragment_key,source_identity,part))');
    final start = args[4] as int,
        limit = args[5] as int,
        reverse = args[7] as bool;
    var requested = (args[6] as List<String>?)?.toSet();
    // Cache generations are accelerators only. Never delete retained source or
    // canonical authority; obsolete cache rows are reclaimed in bounded chunks.
    for (final table in [
      'matrix_timeline_legacy_seek',
      'matrix_timeline_legacy_bloom_parts',
      'matrix_timeline_legacy_bloom_state'
    ]) {
      cache.execute(
          'DELETE FROM $table WHERE rowid IN '
          '(SELECT rowid FROM $table WHERE fragment_key=? AND source_identity<>? LIMIT 64)',
          [fragment, cacheSource]);
    }
    var filter = requested == null
        ? <sqlite.Row>[]
        : cache.select(
            'SELECT item_count FROM matrix_timeline_legacy_bloom_state WHERE fragment_key=? AND source_identity=?',
            [fragment, cacheSource]);
    if (filter.isNotEmpty) {
      final coverage = cache.select(
          'SELECT COUNT(*) AS n FROM matrix_timeline_legacy_bloom_parts '
          'WHERE fragment_key=? AND source_identity=? AND length(v)=32768',
          [fragment, cacheSource]).single['n'];
      if (coverage != _legacyBloomBytes ~/ 32768) {
        cache.execute(
            'DELETE FROM matrix_timeline_legacy_bloom_state '
            'WHERE fragment_key=? AND source_identity=?',
            [fragment, cacheSource]);
        filter = <sqlite.Row>[];
      }
    }
    if (requested != null && filter.isNotEmpty) {
      final parts = <int, Uint8List>{};
      requested = requested.where((id) {
        for (final location in _bloomLocations(id)) {
          final byte = location >> 3, part = byte ~/ 32768;
          final data = parts.putIfAbsent(part, () {
            final rows = cache!.select(
                'SELECT v FROM matrix_timeline_legacy_bloom_parts '
                'WHERE fragment_key=? AND source_identity=? AND part=?',
                [fragment, cacheSource, part]);
            if (rows.length != 1 ||
                (rows.single['v'] as Uint8List).length != 32768) {
              throw StateError('Incomplete legacy membership filter');
            }
            return rows.single['v'] as Uint8List;
          });
          if (data[byte % 32768] & (1 << (location & 7)) == 0) return false;
        }
        return true;
      }).toSet();
      if (requested.isEmpty) {
        checkSource();
        return TimelineLegacyPage([], start: 0, hasMore: false);
      }
    }
    final bitmap = requested != null && filter.isEmpty
        ? Uint8List(_legacyBloomBytes)
        : null;
    final seek = requested != null
        ? <sqlite.Row>[]
        : cache.select(
            'SELECT ordinal,byte_offset FROM matrix_timeline_legacy_seek '
            'WHERE fragment_key=? AND source_identity=? AND ordinal<=? ORDER BY ordinal DESC LIMIT 1',
            [
                fragment,
                cacheSource,
                reverse ? max(0, start - limit + 1) : start
              ]);
    var ordinal = seek.isEmpty ? 0 : seek.single['ordinal'] as int;
    final byteOffset = seek.isEmpty ? 0 : seek.single['byte_offset'] as int;
    final result = <String>[], found = <String, int>{};
    final checkpoints = <(int, int)>[];
    void flushCheckpoints() {
      if (checkpoints.isEmpty) return;
      cache!.execute('BEGIN IMMEDIATE');
      try {
        for (final point in checkpoints) {
          cache.execute(
              'INSERT OR IGNORE INTO matrix_timeline_legacy_seek '
              '(fragment_key,source_identity,ordinal,byte_offset) VALUES (?,?,?,?)',
              [fragment, cacheSource, point.$1, point.$2]);
        }
        cache.execute('COMMIT');
        checkpoints.clear();
      } catch (_) {
        cache.execute('ROLLBACK');
        rethrow;
      }
    }

    var more = false, exhausted = true;
    for (final item in _legacyBlobItems(db, library, fragment,
        byteOffset: byteOffset,
        registerCleanup: (cleanup) => sourceCleanup = cleanup)) {
      if (ordinal % 4096 == 0) {
        await Future<void>.delayed(Duration.zero);
        if (isCancelled()) throw TimelineStorageClosed();
      }
      if (ordinal % 256 == 0) {
        checkSource();
        checkpoints.add((ordinal, item.byteOffset));
        if (checkpoints.length == 64) flushCheckpoints();
      }
      if (bitmap != null) {
        for (final location in _bloomLocations(item.id)) {
          bitmap[location >> 3] |= 1 << (location & 7);
        }
      }
      if (requested != null) {
        if (requested.contains(item.id)) {
          found.putIfAbsent(item.id, () => ordinal);
        }
      } else if (reverse ? ordinal <= start : ordinal >= start) {
        if (reverse) {
          result.add(item.id);
          if (result.length > limit) result.removeAt(0);
        } else if (result.length < limit) {
          result.add(item.id);
        } else {
          more = true;
          exhausted = false;
          break;
        }
      }
      ordinal++;
      if (requested != null && found.length == requested.length ||
          requested == null && reverse && ordinal > start) {
        exhausted = false;
        break;
      }
    }
    checkSource();
    flushCheckpoints();
    if (bitmap != null && exhausted) {
      // Persist fixed-size accelerator chunks, then publish coverage. Interrupted
      // chunks never establish absence, so a partial filter cannot hide an ID.
      for (var part = 0; part < _legacyBloomBytes ~/ 32768; part++) {
        await Future<void>.delayed(Duration.zero);
        if (isCancelled()) throw TimelineStorageClosed();
        cache.execute(
            'INSERT OR REPLACE INTO matrix_timeline_legacy_bloom_parts '
            '(fragment_key,source_identity,part,v) VALUES (?,?,?,?)',
            [
              fragment,
              cacheSource,
              part,
              Uint8List.sublistView(bitmap, part * 32768, (part + 1) * 32768)
            ]);
      }
      checkSource();
      cache.execute(
          'INSERT OR REPLACE INTO matrix_timeline_legacy_bloom_state '
          '(fragment_key,source_identity,item_count) VALUES (?,?,?)',
          [fragment, cacheSource, ordinal]);
    }
    final first = reverse ? min(ordinal - 1, start) : start;
    return TimelineLegacyPage(reverse ? result.reversed.toList() : result,
        start: first,
        hasMore: reverse ? first - result.length >= 0 : more,
        positions: found);
  } finally {
    sourceCleanup?.call();
    cache?.dispose();
    db?.dispose();
  }
}

/// Offline export uses the same bounded BLOB access as live migration. Closing
/// each blob releases its read transaction before the caller stages a page.
Iterable<List<String>> _legacyBlobPages(
    sqlite.Database db, DynamicLibrary library, String fragment) sync* {
  final source = db
      .select('SELECT rowid FROM box_timeline_fragments WHERE k=?', [fragment]);
  if (source.isEmpty) return;
  final rowid = source.single['rowid'] as int;
  final openBlob = library
      .lookupFunction<_BlobOpenNative, _BlobOpenDart>('sqlite3_blob_open');
  final readBlob = library
      .lookupFunction<_BlobReadNative, _BlobReadDart>('sqlite3_blob_read');
  final closeBlob = library
      .lookupFunction<_BlobCloseNative, _BlobCloseDart>('sqlite3_blob_close');
  final blobBytes = library
      .lookupFunction<_BlobBytesNative, _BlobBytesDart>('sqlite3_blob_bytes');
  final schema = 'main'.toNativeUtf8(),
      table = 'box_timeline_fragments'.toNativeUtf8(),
      column = 'v'.toNativeUtf8();
  final buffer = calloc<Uint8>(32768), blob = calloc<Pointer<Void>>();
  try {
    if (openBlob(db.handle.cast(), schema, table, column, rowid, 0, blob) !=
        0) {
      throw StateError('Source unavailable');
    }
    late final int total;
    try {
      total = blobBytes(blob.value);
    } finally {
      closeBlob(blob.value);
    }
    final parser = TimelineStringArrayParser();
    for (var offset = 0; offset < total;) {
      final size = min(32768, total - offset);
      if (openBlob(db.handle.cast(), schema, table, column, rowid, 0, blob) !=
          0) {
        throw StateError('Source unavailable');
      }
      try {
        if (readBlob(blob.value, buffer.cast(), size, offset) != 0) {
          throw StateError('Source changed');
        }
      } finally {
        closeBlob(blob.value);
      }
      offset += size;
      yield* parser.add(buffer.asTypedList(size));
    }
    yield* parser.finish();
  } finally {
    calloc.free(schema);
    calloc.free(table);
    calloc.free(column);
    calloc.free(buffer);
    calloc.free(blob);
  }
}

List<int>? _projectLegacy(List<Object?> args) {
  sqlite.Database? db;
  try {
    SQfLiteEncryptionHelper.ffiInit();
    final library = loader.open.openSqlite();
    db =
        sqlite.sqlite3.open(args[0] as String, mode: sqlite.OpenMode.readWrite);
    if (db.select('PRAGMA cipher_version').isEmpty) {
      throw StateError('Cipher unavailable');
    }
    final cipher = (args[1] as String).toNativeUtf8();
    try {
      final key = library.lookupFunction<_KeyNative, _KeyDart>('sqlite3_key');
      if (key(db.handle.cast(), cipher.cast(),
              utf8.encode(args[1] as String).length) !=
          0) {
        throw StateError('Cipher unavailable');
      }
    } finally {
      calloc.free(cipher);
    }
    final identity = db.select(
        "SELECT k,v FROM box_client WHERE k IN ('user_id','device_id')");
    final values = {for (final row in identity) row['k']: row['v']};
    if (values['user_id'] != args[2] || values['device_id'] != args[3]) {
      throw StateError('Identity changed');
    }
    var fragments = 0, events = 0;
    String? afterKey;
    while (true) {
      final states = db.select(
          "SELECT * FROM matrix_timeline_fragment_state WHERE migration_state IN ('ready','copying') AND fragment_key>? ORDER BY fragment_key LIMIT 1",
          [afterKey ?? '']);
      if (states.isEmpty) break;
      final state = states.single, key = state['fragment_key'] as String;
      afterKey = key;
      final epoch = state['current_epoch'] as int;
      final transitional = state['migration_state'] == 'copying';
      final bases = transitional
          ? db.select(
              'SELECT * FROM matrix_timeline_legacy_bases WHERE fragment_key=? AND epoch=?',
              [key, epoch])
          : null;
      if (transitional && bases!.isEmpty) {
        // Old-version interrupted migration has no delta authority to export.
        // Its retained JSON remains directly usable by the old binary.
        continue;
      }
      if (transitional) {
        final source = db.select(
            'SELECT CAST(t.rowid AS TEXT)||\':\'||COALESCE(r.revision,0) AS identity '
            'FROM box_timeline_fragments t LEFT JOIN matrix_timeline_legacy_revision r ON r.fragment_key=t.k WHERE t.k=?',
            [key]);
        if (source.isEmpty ||
            source.single['identity'] != bases!.single['source_identity']) {
          throw StateError('Source changed');
        }
      }
      Iterable<List<String>> pages() sync* {
        var after = (state['head_seq'] as int) - 1;
        final baseCount = transitional ? 1 << 40 : 0;
        if (transitional) {
          while (true) {
            final rows = db!.select(
                'SELECT seq,event_id,valid_to FROM matrix_timeline_fragment_ids '
                'WHERE fragment_key=? AND epoch=? AND seq>? AND seq<0 ORDER BY seq LIMIT 256',
                [key, epoch, after]);
            if (rows.isEmpty) break;
            after = rows.last['seq'] as int;
            yield rows
                .where((r) => r['valid_to'] == null)
                .map((r) => r['event_id'] as String)
                .toList();
          }
          for (final page in _legacyBlobPages(db, library, key)) {
            final deleted = db
                .select(
                    'SELECT event_id FROM matrix_timeline_legacy_tombstones '
                    'WHERE fragment_key=? AND epoch=? AND event_id IN (${List.filled(page.length, '?').join(',')})',
                    [key, epoch, ...page])
                .map((r) => r['event_id'] as String)
                .toSet();
            yield page.where((id) => !deleted.contains(id)).toList();
          }
          after = baseCount - 1;
        }
        while (true) {
          // Bound raw ordering rows before filtering retired versions.
          final rows = db!.select(
              'SELECT seq,event_id,valid_to FROM matrix_timeline_fragment_ids '
              'WHERE fragment_key=? AND epoch=? AND seq>? AND seq<=? ORDER BY seq LIMIT 256',
              [key, epoch, after, state['tail_seq']]);
          if (rows.isEmpty) break;
          after = rows.last['seq'] as int;
          yield rows
              .where((r) => r['valid_to'] == null)
              .map((r) => r['event_id'] as String)
              .toList();
        }
      }

      var size = 2, count = 0;
      String? firstId, lastId;
      for (final page in pages()) {
        for (final id in page) {
          firstId ??= id;
          lastId = id;
          size += utf8.encode(jsonEncode(id)).length + (count++ == 0 ? 0 : 1);
        }
      }
      if (!transitional && count != state['item_count']) {
        throw StateError('Indexed count mismatch');
      }
      const stage = 'matrix_timeline_rollback_stage';
      db.execute('CREATE TABLE IF NOT EXISTS $stage '
          '(fragment_key TEXT PRIMARY KEY,v BLOB NOT NULL,items_written INTEGER NOT NULL)');
      db.execute(
          'INSERT OR REPLACE INTO $stage(fragment_key,v,items_written) VALUES (?,zeroblob(?),0)',
          [key, size]);
      final rowid = db.select('SELECT rowid FROM $stage WHERE fragment_key=?',
          [key]).single['rowid'] as int;
      final openBlob = library
          .lookupFunction<_BlobOpenNative, _BlobOpenDart>('sqlite3_blob_open');
      final writeBlob =
          library.lookupFunction<_BlobWriteNative, _BlobWriteDart>(
              'sqlite3_blob_write');
      final closeBlob =
          library.lookupFunction<_BlobCloseNative, _BlobCloseDart>(
              'sqlite3_blob_close');
      final schema = 'main'.toNativeUtf8(),
          table = stage.toNativeUtf8(),
          column = 'v'.toNativeUtf8();
      final blob = calloc<Pointer<Void>>();
      var offset = 0, written = 0;
      try {
        void writePage(List<int> bytes, int items) {
          db!.execute('BEGIN IMMEDIATE');
          try {
            if (openBlob(
                    db.handle.cast(), schema, table, column, rowid, 1, blob) !=
                0) {
              throw StateError('Projection unavailable');
            }
            try {
              final memory = calloc<Uint8>(bytes.length);
              try {
                memory.asTypedList(bytes.length).setAll(0, bytes);
                if (writeBlob(
                        blob.value, memory.cast(), bytes.length, offset) !=
                    0) {
                  throw StateError('Projection write failed');
                }
              } finally {
                calloc.free(memory);
              }
            } finally {
              closeBlob(blob.value);
            }
            db.execute('UPDATE $stage SET items_written=? WHERE fragment_key=?',
                [written + items, key]);
            db.execute('COMMIT');
            offset += bytes.length;
            written += items;
          } catch (_) {
            db.execute('ROLLBACK');
            rethrow;
          }
        }

        writePage([91], 0);
        for (final page in pages()) {
          if (page.isEmpty) continue;
          final buffer = StringBuffer();
          var ordinal = written;
          for (final id in page) {
            if (ordinal++ > 0) buffer.write(',');
            buffer.write(jsonEncode(id));
          }
          writePage(utf8.encode(buffer.toString()), page.length);
        }
        writePage([93], 0);
      } finally {
        calloc.free(schema);
        calloc.free(table);
        calloc.free(column);
        calloc.free(blob);
      }
      if (offset != size || written != count) {
        throw StateError('Projection size mismatch');
      }
      // Explicit offline exception: activating one complete legacy JSON value
      // necessarily performs O(N) native work. All preceding staging commits
      // contain at most256 IDs and leave legacy/index authority untouched.
      db.execute('BEGIN IMMEDIATE');
      try {
        final current = db.select(
            'SELECT * FROM matrix_timeline_fragment_state WHERE fragment_key=?',
            [key]).single;
        for (final field in [
          'current_epoch',
          'revision',
          'item_count',
          'head_seq',
          'tail_seq',
          'migration_state'
        ]) {
          if (current[field] != state[field]) {
            throw StateError('Indexed authority changed');
          }
        }
        final verified = db.select(
            "SELECT json_array_length(CAST(v AS TEXT)) AS n,"
            "json_extract(CAST(v AS TEXT),'\$[0]') AS first_id,"
            "json_extract(CAST(v AS TEXT),'\$[#-1]') AS last_id FROM $stage WHERE fragment_key=?",
            [key]).single;
        if (verified['n'] != count ||
            verified['first_id'] != firstId ||
            verified['last_id'] != lastId) {
          throw StateError('Projection content mismatch');
        }
        db.execute(
            'INSERT INTO box_timeline_fragments(k,v) SELECT fragment_key,CAST(v AS TEXT) '
            'FROM $stage WHERE fragment_key=? ON CONFLICT(k) DO UPDATE SET v=excluded.v',
            [key]);
        final sourceRow = db.select(
            'SELECT rowid FROM box_timeline_fragments WHERE k=?',
            [key]).single['rowid'];
        final revision = db.select(
            'SELECT revision FROM matrix_timeline_legacy_revision WHERE fragment_key=?',
            [key]).single['revision'];
        db.execute(
            "UPDATE matrix_timeline_fragment_state SET current_epoch=current_epoch+1,head_seq=0,tail_seq=-1,item_count=0,revision=0,migration_next=0,migration_state='copying',source_identity=? WHERE fragment_key=?",
            ['$sourceRow:$revision', key]);
        db.execute('DELETE FROM $stage WHERE fragment_key=?', [key]);
        db.execute('COMMIT');
        fragments++;
        events += count;
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
    return [fragments, events];
  } catch (_) {
    return null;
  } finally {
    db?.dispose();
  }
}

/// Backfill reads encrypted bodies only in the SQLCipher worker. Its messages
/// contain bounded ID/timestamp metadata, never event contents or credentials.
Stream<List<TimelineSearchEntry>> readEncryptedRetainedSearch(
    {required String path,
    required String cipher,
    required String roomId,
    String? afterEventId,
    String? userId,
    String? deviceId}) async* {
  final messages = ReceivePort();
  final worker = await Isolate.spawn(_readRetainedSearchWorker,
      [messages.sendPort, path, cipher, roomId, afterEventId, userId, deviceId],
      onExit: messages.sendPort);
  SendPort? commands;
  var done = false;
  final iterator = StreamIterator<dynamic>(messages);
  try {
    while (await iterator.moveNext()) {
      final message = iterator.current;
      if (message is SendPort) {
        commands = message;
        commands.send(true);
        continue;
      }
      if (message == 'complete') {
        done = true;
        break;
      }
      if (message is! List<TimelineSearchEntry>) {
        throw StateError('Encrypted search migration failed');
      }
      yield message;
      commands!.send(true);
    }
  } finally {
    commands?.send(false);
    if (!done) {
      try {
        await (() async {
          while (await iterator.moveNext()) {
            final message = iterator.current;
            if (message == null ||
                message == 'stopped' ||
                message == 'complete') {
              break;
            }
          }
        })()
            .timeout(const Duration(seconds: 2));
      } on TimeoutException {
        worker.kill(priority: Isolate.immediate);
      }
    }
    await iterator.cancel();
    messages.close();
  }
}

Future<void> _readRetainedSearchWorker(List<Object?> args) async {
  final output = args[0] as SendPort, commands = ReceivePort();
  final ack = StreamIterator<dynamic>(commands);
  sqlite.Database? db;
  var completed = false;
  try {
    SQfLiteEncryptionHelper.ffiInit();
    final library = loader.open.openSqlite();
    db = sqlite.sqlite3.open(args[1] as String, mode: sqlite.OpenMode.readOnly);
    if (db.select('PRAGMA cipher_version').isEmpty) {
      throw StateError('Cipher unavailable');
    }
    final cipher = (args[2] as String).toNativeUtf8();
    try {
      final key = library.lookupFunction<_KeyNative, _KeyDart>('sqlite3_key');
      if (key(db.handle.cast(), cipher.cast(),
              utf8.encode(args[2] as String).length) !=
          0) {
        throw StateError('Cipher unavailable');
      }
    } finally {
      calloc.free(cipher);
    }
    final identity = db.select(
        "SELECT k,v FROM box_client WHERE k IN ('user_id','device_id')");
    final values = {for (final row in identity) row['k']: row['v']};
    if (values['user_id'] != args[5] || values['device_id'] != args[6]) {
      throw StateError('Identity changed');
    }
    final room = args[3] as String, prefix = '$room|', end = '$room}';
    var cursor = args[4] == null ? prefix : '$prefix${args[4]}';
    final last = db.select(
        'SELECT k FROM box_events WHERE k>=? AND k<? ORDER BY k DESC LIMIT 1',
        [prefix, end]);
    output.send(commands.sendPort);
    if (!await ack.moveNext() || ack.current != true) return;
    if (last.isNotEmpty) {
      final fence = last.single['k'] as String;
      while (true) {
        // select materializes and finalizes this bounded statement before ACK.
        final rows = db.select(
            'SELECT k,v FROM box_events WHERE k>? AND k<=? ORDER BY k LIMIT 256',
            [cursor, fence]);
        if (rows.isEmpty) break;
        cursor = rows.last['k'] as String;
        final metadata = rows.map((row) {
          final body = jsonDecode(row['v'] as String) as Map;
          final stamp = body['origin_server_ts'];
          final status = body['status'] ??
              (body['unsigned'] as Map?)?[messageSendingStatusKey];
          return TimelineSearchEntry(
              (row['k'] as String).substring(prefix.length),
              stamp is int ? stamp : null,
              isSent: status is! int || status >= 0);
        }).toList();
        output.send(metadata);
        if (!await ack.moveNext() || ack.current != true) return;
        await Future<void>.delayed(Duration.zero);
      }
    }
    completed = true;
  } catch (_) {
    output.send(false);
  } finally {
    db?.dispose();
    await ack.cancel();
    commands.close();
    output.send(completed ? 'complete' : 'stopped');
  }
}
