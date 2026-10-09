import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

// Diagnostic reproduction of MatrixHomePage's existing whole-row widget cache:
// GlobalKey on KeyedSubtree, unchanged widget returned again, and a separated
// lazy list without findChildIndexCallback. No framework internals are changed.
void main() {
  testWidgets('cached conversation rows survive visible reorder and deletion',
      (tester) async {
    final listKey = GlobalKey<_CachedConversationListState>();
    await tester.pumpWidget(_app(_CachedConversationList(key: listKey)));
    await tester.pump();
    expect(tester.takeException(), isNull);

    for (var cycle = 0; cycle < 24; cycle++) {
      final order = List<int>.generate(18, (index) => index);
      final shift = cycle % order.length;
      final rotated = [...order.skip(shift), ...order.take(shift)];
      if (cycle.isOdd) rotated.reverseRange(0, rotated.length);
      if (cycle % 3 == 0) rotated.remove(cycle % 18);
      listKey.currentState!.setOrder(rotated);
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'Unmodified separated-list cache, cycle $cycle');
      expect(listKey.currentState!.scroll.positions.length, 1);
      final position = listKey.currentState!.scroll.position;
      listKey.currentState!.scroll.jumpTo(cycle.isEven
          ? position.maxScrollExtent
          : position.minScrollExtent);
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached home rows survive reorder while another route covers home',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    final listKey = GlobalKey<_CachedConversationListState>();
    await tester.pumpWidget(_app(
        _CachedConversationList(key: listKey),
        navigatorKey: navigator));
    await tester.pump();
    navigator.currentState!.push(CupertinoPageRoute<void>(
        builder: (_) => const CupertinoPageScaffold(
            child: Center(child: Text('Synthetic room route')))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);

    for (var cycle = 0; cycle < 24; cycle++) {
      final order = List<int>.generate(18, (index) => (index + cycle) % 18);
      if (cycle.isOdd) order.reverseRange(0, order.length);
      listKey.currentState!.setOrder(order);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull,
          reason: 'Cached home below real Cupertino route, cycle $cycle');
      expect(listKey.currentState!.scroll.positions.length, 1);
    }
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull);
    expect(find.text('Synthetic room route'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('same cached global rows survive list and inherited scope rebuilds',
      (tester) async {
    final listKey = GlobalKey<_CachedConversationListState>();
    var dark = false;
    late StateSetter rebuild;
    await tester.pumpWidget(StatefulBuilder(builder: (_, setState) {
      rebuild = setState;
      return _app(_CachedConversationList(key: listKey), dark: dark);
    }));
    await tester.pump();
    for (var cycle = 0; cycle < 24; cycle++) {
      listKey.currentState!.setOrder(
          List<int>.generate(18, (index) => (17 - index + cycle) % 18));
      rebuild(() => dark = !dark);
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'Whole widget cache plus theme update, cycle $cycle');
      expect(listKey.currentState!.scroll.positions.length, 1);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

Widget _app(Widget home,
        {GlobalKey<NavigatorState>? navigatorKey, bool dark = false}) =>
    CupertinoApp(
        navigatorKey: navigatorKey,
        theme: CupertinoThemeData(
            brightness: dark ? Brightness.dark : Brightness.light),
        home: CupertinoPageScaffold(
            child: Center(
                child: SizedBox(width: 360, height: 480, child: home))));

class _CachedConversationList extends StatefulWidget {
  const _CachedConversationList({super.key});

  @override
  State<_CachedConversationList> createState() =>
      _CachedConversationListState();
}

class _CachedConversationListState extends State<_CachedConversationList> {
  final scroll = ScrollController();
  final _keys = <int, GlobalKey>{};
  final _rows = <int, Widget>{};
  List<int> _order = List<int>.generate(18, (index) => index);

  void setOrder(List<int> order) => setState(() => _order = order);

  Widget _row(int id) => _rows.putIfAbsent(
      id,
      () => KeyedSubtree(
          key: _keys.putIfAbsent(id, GlobalKey.new),
          child: _ScopeConsumerRow(
              key: ValueKey<String>('conversation-$id'), id: id)));

  @override
  Widget build(BuildContext context) => ListView.separated(
      controller: scroll,
      padding: EdgeInsets.zero,
      itemCount: _order.length,
      separatorBuilder: (_, __) => const SizedBox(height: 1),
      itemBuilder: (_, index) => _row(_order[index]));

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }
}

class _ScopeConsumerRow extends StatelessWidget {
  const _ScopeConsumerRow({super.key, required this.id});
  final int id;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final media = MediaQuery.of(context);
    final theme = CupertinoTheme.of(context);
    final scroll = Scrollable.of(context);
    return SizedBox(
        height: 70 + (id % 3) * 19,
        child: Text('Synthetic conversation $id',
            style: style.copyWith(color: theme.primaryColor),
            textScaler: media.textScaler,
            textDirection: scroll.axisDirection == AxisDirection.up
                ? TextDirection.rtl
                : TextDirection.ltr));
  }
}

extension _ReverseRange on List<int> {
  void reverseRange(int start, int end) {
    final reversed = sublist(start, end).reversed.toList();
    setRange(start, end, reversed);
  }
}