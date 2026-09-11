import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/moments/moment_image_prefetcher.dart';

final class _Key {
  const _Key(this.index, this.scope);
  final int index;
  final Object scope;
  @override
  bool operator ==(Object other) =>
      other is _Key && other.index == index && other.scope == scope;
  @override
  int get hashCode => Object.hash(index, scope);
}

final class _ControlledProvider extends ImageProvider<_Key> {
  const _ControlledProvider(this.index, this.completers);
  final int index;
  final Map<int, _ControlledCompleter> completers;
  @override
  Future<_Key> obtainKey(ImageConfiguration configuration) async =>
      _Key(index, completers);
  @override
  ImageStreamCompleter loadImage(_Key key, ImageDecoderCallback decode) =>
      completers.putIfAbsent(index, _ControlledCompleter.new);
}

final class _ControlledCompleter extends ImageStreamCompleter {
  var added = 0;
  var removed = 0;
  @override
  void addListener(ImageStreamListener listener) {
    added++;
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    removed++;
    super.removeListener(listener);
  }

  void emit(ui.Image image) => setImage(ImageInfo(image: image));
}

void main() {
  testWidgets('bounded leases cancel old range and release after first frame',
      (tester) async {
    final completers = <int, _ControlledCompleter>{};
    final prefetcher = MomentImagePrefetcher(
        (index) => _ControlledProvider(index, completers));
    prefetcher.update(
        currentIndex: 1,
        itemCount: 4,
        identityAt: (index) => const ['a', 'b', 'c', 'd'][index]);
    await tester.pump();
    expect(completers.keys, unorderedEquals([0, 2]));
    expect(completers[0]!.added, greaterThan(0));
    expect(completers[2]!.added, greaterThan(0));

    prefetcher.update(
        currentIndex: 2,
        itemCount: 4,
        identityAt: (index) => const ['a', 'b', 'c', 'd'][index]);
    await tester.pump();
    expect(completers[0]!.removed, greaterThan(0));
    expect(completers[1]!.added, greaterThan(0));
    expect(completers[2]!.removed, greaterThan(0));
    expect(completers[3]!.added, greaterThan(0));
    final image =
        await tester.runAsync(() => createTestImage(width: 1, height: 1));
    completers[1]!.emit(image!);
    expect(completers[1]!.removed, greaterThan(0));
    prefetcher.dispose();
    expect(completers[3]!.removed, greaterThan(0));
  });

  test('large galleries inspect only immediate neighbors per update', () {
    var identityCalls = 0;
    final prefetcher = MomentImagePrefetcher(
        (index) => _ControlledProvider(index, <int, _ControlledCompleter>{}));
    prefetcher.update(
        currentIndex: 25000,
        itemCount: 50000,
        identityAt: (index) {
          identityCalls++;
          return index;
        });
    expect(identityCalls, lessThanOrEqualTo(2));
    prefetcher.dispose();
  });

  testWidgets('unrelated rebuild does not resolve completed neighbor again',
      (tester) async {
    final completers = <int, _ControlledCompleter>{};
    var providerCalls = 0;
    final prefetcher = MomentImagePrefetcher((index) {
      providerCalls++;
      return _ControlledProvider(index, completers);
    });
    prefetcher.update(
        currentIndex: 1, itemCount: 3, identityAt: (index) => index);
    await tester.pump();
    completers[0]!.emit(
        (await tester.runAsync(() => createTestImage(width: 1, height: 1)))!);
    prefetcher.update(
        currentIndex: 1, itemCount: 3, identityAt: (index) => index);
    expect(providerCalls, 2);
    prefetcher.dispose();
  });

  testWidgets('same-index source replacement cancels old pending leases',
      (tester) async {
    var scope = 'alice';
    var activeCompleters = <int, _ControlledCompleter>{};
    final aliceCompleters = activeCompleters;
    final prefetcher = MomentImagePrefetcher(
        (index) => _ControlledProvider(index, activeCompleters));
    Object identityAt(int index) => (scope, index);

    prefetcher.update(currentIndex: 1, itemCount: 3, identityAt: identityAt);
    await tester.pump();
    expect(aliceCompleters[0]!.added, greaterThan(0));
    expect(aliceCompleters[2]!.added, greaterThan(0));

    scope = 'bob';
    activeCompleters = <int, _ControlledCompleter>{};
    final bobCompleters = activeCompleters;
    prefetcher.update(currentIndex: 1, itemCount: 3, identityAt: identityAt);
    await tester.pump();
    expect(aliceCompleters[0]!.removed, greaterThan(0));
    expect(aliceCompleters[2]!.removed, greaterThan(0));
    expect(bobCompleters.keys, unorderedEquals([0, 2]));

    aliceCompleters[0]!.emit(
        (await tester.runAsync(() => createTestImage(width: 1, height: 1)))!);
    expect(bobCompleters[0]!.removed, equals(0));
    prefetcher.dispose();
  });
}
