import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/emoji/fluent_vector_emoji_catalog.dart';
import 'package:liuhetong_mobile/features/emoji/static_emoji_recent_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('rapid selections keep latest 16 unique across new store instances',
      () async {
    final store = StaticEmojiRecentStore(accountId: '@alice:example.test');
    final values = vectorEmojis.take(18).map((e) => e.char).toList();
    await Future.wait(values.map(store.record));
    await StaticEmojiRecentStore(accountId: store.accountId).record(values[4]);
    final expected = [
      values[4],
      ...values.reversed.where((v) => v != values[4])
    ].take(16).toList();
    expect(await StaticEmojiRecentStore(accountId: store.accountId).load(),
        expected);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {store.storageKey});
    expect(prefs.getStringList(store.storageKey), expected);
    // Simulate a new process with only the persisted preference payload.
    SharedPreferences.setMockInitialValues(
        {store.storageKey: prefs.getStringList(store.storageKey)!});
    expect(await StaticEmojiRecentStore(accountId: store.accountId).load(),
        expected);
  });

  test('account isolation and empty identity never writes a shared list',
      () async {
    final a = StaticEmojiRecentStore(accountId: 'alice');
    final b = StaticEmojiRecentStore(accountId: 'bob');
    await a.record(vectorEmojis[0].char);
    await b.record(vectorEmojis[1].char);
    await StaticEmojiRecentStore(accountId: '').record(vectorEmojis[2].char);
    expect(await a.load(), [vectorEmojis[0].char]);
    expect(await b.load(), [vectorEmojis[1].char]);
    expect(await StaticEmojiRecentStore(accountId: '').load(), isEmpty);
    expect((await SharedPreferences.getInstance()).getKeys(),
        {a.storageKey, b.storageKey});
  });

  test('reload accepts only catalog emoji and bounds deduplicated saved values',
      () async {
    final store = StaticEmojiRecentStore(accountId: 'alice');
    SharedPreferences.setMockInitialValues({
      store.storageKey: [
        'draft text',
        'unknown-id',
        vectorEmojis.first.char,
        ...vectorEmojis.take(30).map((e) => e.char),
      ]
    });
    expect(
        await store.load(), vectorEmojis.take(16).map((e) => e.char).toList());
    await store.record('draft text');
    expect(await store.load(), hasLength(16));
  });
}
