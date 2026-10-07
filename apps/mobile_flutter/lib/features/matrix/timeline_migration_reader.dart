import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';
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
          "SELECT * FROM matrix_timeline_fragment_state WHERE migration_state='ready' AND fragment_key>? ORDER BY fragment_key LIMIT 1",
          [afterKey ?? '']);
      if (states.isEmpty) break;
      final state = states.single, key = state['fragment_key'] as String;
      afterKey = key;
      final epoch = state['current_epoch'] as int;
      Iterable<List<String>> pages() sync* {
        var after = (state['head_seq'] as int) - 1;
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
      if (count != state['item_count']) {
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
            "UPDATE matrix_timeline_fragment_state SET current_epoch=current_epoch+1,head_seq=0,tail_seq=-1,item_count=0,migration_next=0,migration_state='copying',source_identity=? WHERE fragment_key=?",
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
