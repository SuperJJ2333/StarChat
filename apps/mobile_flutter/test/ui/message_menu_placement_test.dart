import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/message_menu_placement.dart';

void main() {
  const viewport = Rect.fromLTRB(8, 32, 352, 680);
  const size = Size(272, 116);
  test('top message opens below and clamps horizontally', () {
    final layout = MessageMenuPlacement.calculate(
        anchor: const Rect.fromLTRB(300, 40, 352, 90),
        viewport: viewport,
        menuSize: size,
        outgoing: true);
    expect(layout.rect.top, 98);
    expect(layout.rect.right, lessThanOrEqualTo(viewport.right));
    expect(layout.arrowAtTop, isTrue);
  });
  test('bottom message opens above', () {
    final layout = MessageMenuPlacement.calculate(
        anchor: const Rect.fromLTRB(8, 610, 100, 665),
        viewport: viewport,
        menuSize: size,
        outgoing: false);
    expect(layout.rect.bottom, 602);
    expect(layout.arrowAtTop, isFalse);
  });
  test('oversized anchor and tiny viewport keep menu reachable', () {
    final layout = MessageMenuPlacement.calculate(
        anchor: const Rect.fromLTRB(0, 0, 400, 700),
        viewport: const Rect.fromLTRB(8, 32, 220, 130),
        menuSize: size,
        outgoing: false);
    expect(layout.rect.left, greaterThanOrEqualTo(8));
    expect(layout.rect.top, greaterThanOrEqualTo(32));
    expect(layout.rect.right, lessThanOrEqualTo(220));
    expect(layout.rect.bottom, lessThanOrEqualTo(130));
  });
}
