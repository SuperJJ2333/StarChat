import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/incremental_timeline_merge.dart';

void main() {
  test(
      'append sorts only changes; unchanged rows keep identity and no comparisons',
      () {
    var comparisons = 0;
    final merger = IncrementalTimelineMerge<(String, int)>(
      idOf: (r) => r.$1,
      compare: (a, b) {
        comparisons++;
        return a.$2.compareTo(b.$2);
      },
    );
    final rows = List.generate(10000, (i) => ('$i', i));
    final first = merger.update(rows);
    comparisons = 0;
    expect(merger.update(rows), same(first));
    expect(comparisons, 0);
    final next = merger.update([...rows, ('new', 10000)]);
    expect(comparisons, lessThanOrEqualTo(10000));
    expect(next.last.$1, 'new');
    expect(identical(next[42], first[42]), isTrue);
  });

  test('edits reorder, removals disappear, first source owns duplicate IDs',
      () {
    final merger = IncrementalTimelineMerge<(String, int)>(
        idOf: (r) => r.$1, compare: (a, b) => a.$2.compareTo(b.$2));
    merger.update([('a', 1), ('b', 2), ('c', 3)]);
    expect(merger.update([('a', 4), ('c', 3), ('a', 0)]), [('c', 3), ('a', 4)]);
    expect(merger.update([]), isEmpty);
  });
}
