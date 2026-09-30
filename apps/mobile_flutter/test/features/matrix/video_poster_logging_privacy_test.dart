import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/video_poster_extractor.dart';

void main() {
  test('poster failure logs a fixed category without native paths or text',
      () async {
    final previous = debugPrint;
    final lines = <String>[];
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    try {
      final poster = await extractVideoPoster(
        '/private/secret-media.mp4',
        fetch: (_, __) async =>
            throw StateError('secret-token /private/secret-media.mp4'),
      );
      expect(poster, isNull);
      expect(lines, isNotEmpty);
      expect(lines.join(), isNot(contains('secret-token')));
      expect(lines.join(), isNot(contains('/private/')));
      expect(
          lines.every((line) => line.startsWith('[chatflow/media]')), isTrue);
    } finally {
      debugPrint = previous;
    }
  });
}
