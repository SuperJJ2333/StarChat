import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/media_activity.dart';

void main() {
  test('caps grants at two and transfers on cancellation', () {
    final budget = MediaAnimationBudget();
    final a = budget.register(priority: 1),
        b = budget.register(priority: 1),
        c = budget.register(priority: 1);
    expect([a.granted.value, b.granted.value, c.granted.value],
        [true, true, false]);
    a.update(eligible: false);
    expect(c.granted.value, true);
  });
  test('viewer priority wins and repeated release is safe', () {
    final budget = MediaAnimationBudget(maxActive: 1);
    final thumbnail = budget.register(priority: 1),
        viewer = budget.register(priority: 2);
    expect(viewer.granted.value, true);
    expect(thumbnail.granted.value, false);
    viewer.dispose();
    viewer.dispose();
    expect(thumbnail.granted.value, true);
  });

  test('notification transitions never exceed the animation cap', () {
    final budget = MediaAnimationBudget(maxActive: 1);
    final thumbnail = budget.register(priority: 1);
    final viewer = budget.register(priority: 0);
    final tokens = [thumbnail, viewer];
    final counts = <int>[];
    for (final token in tokens) {
      token.granted.addListener(() {
        counts.add(tokens.where((item) => item.granted.value).length);
      });
    }
    viewer.update(priority: 2);
    expect(viewer.granted.value, true);
    expect(counts, everyElement(lessThanOrEqualTo(1)));
  });

  test('equal priorities retain registration order through updates', () {
    final budget = MediaAnimationBudget(maxActive: 1);
    final first = budget.register(priority: 1);
    final second = budget.register(priority: 1);
    for (var index = 0; index < 5; index++) {
      second.update(priority: 1);
      first.update(priority: 1);
      expect(first.granted.value, true);
      expect(second.granted.value, false);
    }
  });

  test('listener disposal is reentrant and transfers the slot', () {
    final budget = MediaAnimationBudget(maxActive: 1);
    final first = budget.register(priority: 1);
    final second = budget.register(priority: 0);
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      first.granted.addListener(first.dispose);
      first.update(eligible: false);
    } finally {
      FlutterError.onError = previous;
    }
    expect(errors, isEmpty);
    expect(second.granted.value, true);
  });

  test('rejects a non-positive animation capacity', () {
    expect(() => MediaAnimationBudget(maxActive: 0), throwsArgumentError);
    expect(() => MediaAnimationBudget(maxActive: -1), throwsArgumentError);
  });
}
