import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_store.dart';
import 'package:liuhetong_mobile/core/outbox/media_outbox_recovery_service.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/content_addressed_media.dart';
import 'package:liuhetong_mobile/features/matrix/media_index.dart';
import 'package:liuhetong_mobile/features/matrix/media_transfer_budget.dart';
import 'video_forward_backend_test.dart'
    show
        ForwardClient,
        ForwardRoom,
        ForwardTimeline,
        ForwardPaths,
        forwardOwner;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'explicit memory budget failure stays actionable without automatic network retries',
      () async {
    sqfliteFfiInit();
    final root = await Directory.systemTemp.createTemp('media-limit-failure-');
    final store = SqliteMediaOutboxStore(
        owner: const MediaOutboxOwner(
            accountId: '@alice:test',
            homeserver: 'https://test',
            generation: 'fixture'),
        directory: () async => root,
        availableBytes: () async => 1 << 30,
        seal: (_, __) async {});
    var calls = 0;
    final service = MediaOutboxRecoveryService(
        store: store,
        isCurrentOwner: () => true,
        authorize: (_) async => true,
        failureReason: (error) => error is MediaTransferLimitException
            ? 'memory-limit:${error.maximumPayloadBytes}'
            : null,
        send: (_, __) async {
          calls++;
          throw const MediaTransferLimitException(1234);
        });
    final task = await service.persistBytes(
        txid: 'over',
        roomId: '!r:test',
        bytes: Uint8List.fromList([1]),
        mimeType: 'application/octet-stream',
        filename: 'f');
    await expectLater(
        service.dispatch(task), throwsA(isA<MediaTransferLimitException>()));
    for (var i = 0; i < 20; i++) {
      await service.recover();
    }
    final failed = (await store.byTxid(task.txid))!;
    expect(failed.stage, MediaOutboxStage.failed);
    expect(calls, 1);
    expect(MediaOutboxException(failed.failure!).userMessage, contains('1234'));
    expect(MediaOutboxException(failed.failure!).userMessage, contains('压缩'));
    service.dispose();
    await service.close();
    await root.delete(recursive: true);
  });
  test(
      'prepared coordinator holds only durable metadata before a pending sender',
      () async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    final root = await Directory.systemTemp.createTemp('media-coordinator-');
    final client = ForwardClient();
    final room = ForwardRoom(id: '!target:test', client: client);
    client.destinations[room.id] = room;
    final matrix = forwardOwner(client);
    final store = SqliteMediaOutboxStore(
        owner: const MediaOutboxOwner(
            accountId: '@alice:test',
            homeserver: 'https://test',
            generation: 'fixture'),
        directory: () async => root,
        availableBytes: () async => 1 << 30,
        seal: (_, __) async {});
    final ack = Completer<String>();
    final entered = Completer<void>();
    final service = MediaOutboxRecoveryService(
        store: store,
        isCurrentOwner: () => true,
        authorize: (_) async => true,
        send: (task, source) async {
          expect(
              (await store.byTxid(task.txid))!.stage, MediaOutboxStage.sending);
          expect(task.prepared, isTrue);
          expect(await source.readAsBytes(), [1, 2, 3]);
          entered.complete();
          return ack.future;
        });
    matrix.bindDurableMediaOutbox(service);
    final media = MatrixOutgoingPreparedMedia(
        id: 'source',
        bytes: [1, 2, 3],
        mimeType: 'video/mp4',
        filename: 'clip.mp4',
        body: '[视频]');
    final job = await matrix.enqueuePreparedMedia(
        jobId: 'durable', media: media, targetRoomIds: [room.id]);
    await entered.future.timeout(const Duration(seconds: 5));
    expect(media.retainedBytes, 0);
    expect(job.source!.retainedBytes, lessThan(4096));
    expect(job.items.single.txid, 'outgoing-durable-0-0');
    ack.complete(r'$sent');
    await matrix.outgoingWork.drain();
    expect(await store.pending(), isEmpty);
    service.dispose();
    await service.close();
    await client.dispose();
    await root.delete(recursive: true);
  });

  test(
      'edited image intent exists before export and admission holds no payload',
      () async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    final root = await Directory.systemTemp.createTemp('media-export-');
    final client = ForwardClient();
    final room = ForwardRoom(id: '!target:test', client: client);
    client.destinations[room.id] = room;
    final matrix = forwardOwner(client);
    final store = SqliteMediaOutboxStore(
        owner: const MediaOutboxOwner(
            accountId: '@alice:test',
            homeserver: 'https://test',
            generation: 'fixture'),
        directory: () async => root,
        availableBytes: () async => 1 << 30,
        seal: (_, __) async {});
    final service = MediaOutboxRecoveryService(
        store: store,
        isCurrentOwner: () => true,
        authorize: (_) async => true,
        send: (_, __) async => r'$edited');
    matrix.bindDurableMediaOutbox(service);
    final job = await matrix.enqueuePreparedMediaFrom(
        jobId: 'edit',
        sourceId: 'edit',
        load: () async {
          expect((await store.byTxid('outgoing-edit-0-0'))!.stage,
              MediaOutboxStage.preparing);
          return Uint8List.fromList([1, 2, 3]);
        },
        maximumBytes: 1024,
        mimeType: 'image/png',
        filename: 'edited.png',
        body: '[编辑图片]',
        targetRoomIds: [room.id]);
    await matrix.outgoingWork.drain();
    expect(job.source!.retainedBytes, lessThan(4096));
    expect(await store.pending(), isEmpty);
    service.dispose();
    await service.close();
    await client.dispose();
    await root.delete(recursive: true);
  });

  test(
      'gallery video intent precedes resolver and original loss cannot lose queued source',
      () async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    final root = await Directory.systemTemp.createTemp('media-video-intent-');
    final original =
        await File('${root.path}/picked.mp4').writeAsBytes([5, 6, 7]);
    final client = ForwardClient();
    final room = ForwardRoom(id: '!target:test', client: client);
    client.destinations[room.id] = room;
    final matrix = forwardOwner(client);
    final store = SqliteMediaOutboxStore(
        owner: const MediaOutboxOwner(
            accountId: '@alice:test',
            homeserver: 'https://test',
            generation: 'fixture'),
        directory: () async => root,
        availableBytes: () async => 1 << 30,
        seal: (_, __) async {});
    final ack = Completer<String>();
    final entered = Completer<void>();
    final service = MediaOutboxRecoveryService(
        store: store,
        isCurrentOwner: () => true,
        authorize: (_) async => true,
        send: (task, source) async {
          expect(task.prepared, isFalse);
          expect(source.path, isNot(original.path));
          expect(await source.readAsBytes(), [5, 6, 7]);
          entered.complete();
          return ack.future;
        });
    matrix.bindDurableMediaOutbox(service);
    await matrix.enqueueVideoFiles(requests: [
      MatrixOutgoingVideoFileRequest(
          jobId: 'gallery',
          targetRoomIds: [room.id],
          video: MatrixOutgoingVideoFile(
              id: 'video',
              filename: 'picked.mp4',
              body: '[视频]',
              deleteSourceWhenDone: false,
              resolveSource: () async {
                expect((await store.byTxid('outgoing-gallery-0-0'))!.stage,
                    MediaOutboxStage.preparing);
                return original;
              }))
    ]);
    await entered.future.timeout(const Duration(seconds: 5));
    await original.delete();
    ack.complete(r'$video');
    await matrix.outgoingWork.drain();
    expect(await store.pending(), isEmpty);
    service.dispose();
    await service.close();
    await client.dispose();
    await root.delete(recursive: true);
  });

  test(
      'encrypted legacy forward without size persists verified plaintext but no key descriptor',
      () async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    final root = await Directory.systemTemp.createTemp('media-forward-intent-');
    PathProviderPlatform.instance = ForwardPaths(root.path);
    final index = MediaIndex(databasePath: '${root.path}/synthetic-index.db');
    MediaIndex.overrideShared(index);
    final bytes = base64Decode(
        'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');
    final envelope = await MediaEnvelope.forBytes(bytes);
    var downloads = 0;
    final client = ForwardClient(httpClient: MockClient((_) async {
      downloads++;
      return http.Response.bytes(envelope.encrypted.data, 200);
    }));
    final source = ForwardRoom(id: '!source:test', client: client);
    final target = ForwardRoom(id: '!target:test', client: client);
    client.destinations.addAll({source.id: source, target.id: target});
    source.timeline = ForwardTimeline([
      Event(
          type: EventTypes.Message,
          room: source,
          eventId: r'$source',
          senderId: '@alice:test',
          originServerTs: DateTime.utc(2026),
          content: {
            'msgtype': 'm.file',
            'body': 'original.gif',
            'info': {'mimetype': 'image/gif'},
            'file': {
              'url': 'mxc://synthetic/cipher',
              'v': 'v2',
              'key': {
                'alg': 'A256CTR',
                'ext': true,
                'k': envelope.encrypted.k,
                'key_ops': ['encrypt', 'decrypt'],
                'kty': 'oct'
              },
              'iv': envelope.encrypted.iv,
              'hashes': {'sha256': envelope.encrypted.sha256}
            },
            'chatflow_media': {'v': 1, 'content_sha256': envelope.contentSha256}
          },
          originalSource: MatrixEvent(
              type: EventTypes.Encrypted,
              content: {},
              eventId: r'$source',
              senderId: '@alice:test',
              originServerTs: DateTime.utc(2026)))
    ]);
    final matrix = forwardOwner(client);
    final store = SqliteMediaOutboxStore(
        owner: const MediaOutboxOwner(
            accountId: '@alice:test',
            homeserver: 'https://test',
            generation: 'fixture'),
        directory: () async => root,
        availableBytes: () async => 1 << 30,
        seal: (_, __) async {});
    final service = MediaOutboxRecoveryService(
        store: store,
        isCurrentOwner: () => true,
        authorize: (_) async => true,
        send: (task, file) async {
          expect(task.prepared && task.asFile, isTrue);
          expect(await file.readAsBytes(), bytes);
          return r'$forward';
        });
    matrix.bindDurableMediaOutbox(service);
    final lease = await matrix.openRoomLease(source.id);
    await lease.openRoomTimeline(onUpdate: () {});
    await lease.enqueueForward(
        batchId: 'legacy',
        messages: [lease.snapshotForwardSource(r'$source')],
        targetRoomIds: [target.id]);
    await matrix.outgoingWork.drain();
    expect(downloads, 1);
    expect(await store.pending(), isEmpty);
    await lease.cancel();
    service.dispose();
    await service.close();
    final manifest =
        await File('${root.path}/${store.owner.scope}/manifest-v1.db')
            .readAsBytes();
    final decoded = latin1.decode(manifest);
    expect(decoded, isNot(contains(envelope.encrypted.k)));
    expect(decoded, isNot(contains('mxc://synthetic/cipher')));
    await index.close();
    MediaIndex.overrideShared(null);
    await client.dispose();
    await root.delete(recursive: true);
  });
}
