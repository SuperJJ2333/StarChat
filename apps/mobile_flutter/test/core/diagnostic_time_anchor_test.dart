import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/diagnostic_time_anchor.dart';

void main() {
  test('RFC1123 Date gives a bounded monotonic UTC window', () {
    final anchor = DiagnosticTimeAnchor();
    expect(
      anchor.observe(
        dateHeader: 'Mon, 28 Sep 2026 08:00:00 GMT',
        sentAtMs: 1000,
        receivedAtMs: 1200,
      ),
      isTrue,
    );
    final window = anchor.window(1200, 2200);
    expect(window, isNotNull);
    expect(window!.startedAtUtc, '2026-09-28T08:00:00.100Z');
    expect(window.endedAtUtc, '2026-09-28T08:00:01.100Z');
    expect(window.clockUncertaintyMs, 1100);
    expect(window.timeAnchorAgeMs, 1000);
    expect(anchor.window(301201, 301201), isNull);
  });

  test('invalid, slow and reversed responses do not anchor', () {
    final anchor = DiagnosticTimeAnchor();
    expect(anchor.observe(dateHeader: null, sentAtMs: 0, receivedAtMs: 1),
        isFalse);
    expect(anchor.observe(dateHeader: 'PRIVATE', sentAtMs: 0, receivedAtMs: 1),
        isFalse);
    expect(
        anchor.observe(
          dateHeader: 'Mon, 28 Sep 2026 08:00:00 GMT',
          sentAtMs: 0,
          receivedAtMs: 2001,
        ),
        isFalse);
    expect(
        anchor.observe(
          dateHeader: 'Mon, 28 Sep 2026 08:00:00 GMT',
          sentAtMs: 2,
          receivedAtMs: 1,
        ),
        isFalse);
    expect(anchor.window(0, 1), isNull);
  });

  test('plausible but impossible HTTP dates cannot escape diagnostics', () {
    final anchor = DiagnosticTimeAnchor();
    for (final date in [
      'Mon, 28 Foo 2026 08:00:00 GMT',
      'Mon, 32 Sep 2026 08:00:00 GMT',
    ]) {
      expect(
          anchor.observe(dateHeader: date, sentAtMs: 1000, receivedAtMs: 1200),
          isFalse);
    }
    expect(anchor.window(1200, 1300), isNull);
  });

  test('a long operation start before the fresh anchor is uncertain', () {
    final anchor = DiagnosticTimeAnchor();
    expect(
        anchor.observe(
          dateHeader: 'Mon, 28 Sep 2026 08:00:00 GMT',
          sentAtMs: 600000,
          receivedAtMs: 600100,
        ),
        isTrue);
    expect(anchor.window(0, 600200), isNull);
    expect(anchor.window(300100, 600200), isNotNull);
  });
}
