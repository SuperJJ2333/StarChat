import 'package:matrix/matrix.dart';

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
        String? deviceId}) =>
    Future.error(UnsupportedError('Native timeline page unavailable'));

/// Native SQLCipher readers are unavailable on the IndexedDB platform.
Stream<List<String>> readEncryptedTimelineIds(
        {required String path,
        required String cipher,
        required String fragment,
        String? userId,
        String? deviceId}) =>
    Stream.error(UnsupportedError('Native timeline migration unavailable'));

Stream<List<TimelineSearchEntry>> readEncryptedRetainedSearch(
        {required String path,
        required String cipher,
        required String roomId,
        String? afterEventId,
        String? userId,
        String? deviceId}) =>
    Stream.error(UnsupportedError('Native search migration unavailable'));
