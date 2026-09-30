import 'dart:async';
import 'package:matrix/matrix.dart';
import '../../core/native_media_download.dart';
import 'content_addressed_media.dart';
import 'media_cache.dart';
import 'media_index.dart';
import 'incoming_media_prefetch.dart';

final class MatrixSdkIncomingMediaSource implements IncomingMediaSource {
  MatrixSdkIncomingMediaSource(
      {required this.client, required this.ensureActive});
  final Client client;
  final void Function() ensureActive;
  final _events = StreamController<IncomingMediaCandidate>.broadcast();
  StreamSubscription<EventUpdate>? _subscription;
  NativeMediaDownloadSession? _downloads;
  bool _closed = false;
  void _check() {
    if (_closed) throw StateError('Media source closed');
    ensureActive();
  }

  @override
  Stream<IncomingMediaCandidate> get candidates => _events.stream;
  @override
  Future<void> start() async {
    _check();
    if (_subscription != null) return;
    _subscription = client.onEvent.stream.listen((update) {
      if (update.type != EventUpdateType.timeline &&
          update.type != EventUpdateType.decryptedTimelineQueue) {
        return;
      }
      try {
        _check();
        final room = client.getRoomById(update.roomID);
        if (room != null) _accept(Event.fromJson(update.content, room));
      } catch (_) {
        /* Revoked or malformed events never become download authority. */
      }
    });
    // Bounded local catch-up; no timeline lease, /messages request or read receipt.
    final database = client.database;
    if (database == null) return;
    for (final room in client.rooms.take(30)) {
      _check();
      if (room.membership != Membership.join) continue;
      final events = await database.getEventList(room, limit: 20);
      _check();
      for (final event in events) {
        _accept(event);
      }
    }
  }

  void _accept(Event event) {
    _check();
    if (event.room.membership != Membership.join ||
        event.redacted ||
        event.unsigned?['redacted_because'] is Map ||
        event.status.isSending ||
        event.senderId == client.userID ||
        event.type != EventTypes.Message ||
        ![MessageTypes.Image, MessageTypes.Video].contains(event.messageType) ||
        event.content['flash']?.toString() == '1' ||
        event.originalSource?.type != EventTypes.Encrypted ||
        !event.isAttachmentEncrypted) {
      return;
    }
    final hashes = TrustedMediaHashes.fromEvent(event);
    final thumbnail = event.hasThumbnail && event.isThumbnailEncrypted;
    MediaCacheKey key(bool thumb) => MediaCacheKey(
        accountId: client.userID ?? '',
        roomId: event.room.id,
        eventId: thumb ? 'thumb:${event.eventId}' : event.eventId,
        contentSha256: thumb ? hashes?.thumbnailSha256 : hashes?.contentSha256,
        sourceIdentity:
            matrixMediaSourceIdentity(event.content, thumbnail: thumb),
        variant: thumb ? MediaVariantKind.thumbnail : MediaVariantKind.body,
        familyId: hashes?.contentSha256);
    final requests = <bool, NativeMediaRequest>{};
    final owner = Object();
    Future<NativeMediaRequest> request(bool thumb, [Uri? resolved]) async {
      _check();
      final existing = requests[thumb];
      final mxc = event.attachmentOrThumbnailMxcUrl(getThumbnail: thumb);
      final url =
          resolved ?? existing?.url ?? await mxc!.getDownloadUri(client);
      _check();
      return requests[thumb] = NativeMediaRequest(
          id: matrixMediaTransferIdentity(event, thumbnail: thumb),
          url: url.replace(queryParameters: {
            ...url.queryParameters,
            'allow_redirect': 'false'
          }),
          trustedOrigin: client.homeserver!.origin,
          kind: 'matrix',
          maxBytes: thumb ? 8 * 1024 * 1024 : 64 * 1024 * 1024,
          authorization: 'Bearer ${client.accessToken}');
    }

    NativeMediaDownloadSession transport() =>
        _downloads ??= NativeMediaDownloadSession(client.userID!);
    _events.add(IncomingMediaCandidate(
        originalKey: key(false),
        previewAccountId: '${client.homeserver}|${client.userID}',
        thumbnailKey: thumbnail ? key(true) : null,
        isVideo: event.messageType == MessageTypes.Video,
        isAnimated: event.infoMap['mimetype'] == 'image/gif',
        prepare: () async {
          for (final thumb in [if (thumbnail) true, false]) {
            _check();
            final cacheKey = key(thumb);
            var cached = await MediaCache.cached(
                cacheKey.roomId, cacheKey.eventId,
                accountId: cacheKey.accountId,
                contentSha256: cacheKey.contentSha256);
            if (cached == null && cacheKey.sourceIdentity != null) {
              cached = await MediaCache.cached(
                  'source', cacheKey.sourceIdentity!,
                  accountId: cacheKey.accountId,
                  contentSha256: cacheKey.contentSha256);
            }
            if (cached != null) {
              continue;
            }
            _check();
            await transport().prepare(await request(thumb), owner: owner);
          }
          _check();
        },
        release: () async {
          final downloads = _downloads;
          if (downloads == null) return;
          await Future.wait(requests.values
              .map((request) => downloads.release(request, owner: owner)));
        },
        download: (thumb) async {
          _check();
          final bytes = await downloadMediaContent(event,
              thumbnail: thumb,
              downloadCallback: (url) async =>
                  transport().download(await request(thumb, url)));
          _check();
          return bytes;
        }));
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    await _subscription?.cancel();
    await _downloads?.dispose();
    await _events.close();
  }
}
