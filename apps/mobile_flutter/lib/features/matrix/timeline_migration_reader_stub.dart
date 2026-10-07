import 'package:matrix/matrix.dart';

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
