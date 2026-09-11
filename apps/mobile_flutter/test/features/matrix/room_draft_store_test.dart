import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/room_draft_store.dart';
import 'package:liuhetong_mobile/features/matrix/mention_composer_model.dart';

class MemoryStore implements SecureKeyValueStore {
  final data = <String, String>{};
  Completer<String?>? blockedRead;
  Completer<void>? blockedWrite;
  @override
  Future<String?> read(String key) async =>
      blockedRead == null ? data[key] : blockedRead!.future;
  @override
  Future<void> write(String key, String value) async {
    if (blockedWrite != null) await blockedWrite!.future;
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

void main() {
  test('saved mention snapshots cannot be changed by producers or readers',
      () async {
    final disk = MemoryStore();
    final store = RoomDraftStore(disk);
    final recipients = ['@a:s'];
    final tokens = [
      MentionToken(
          start: 0,
          end: 4,
          display: '所有人',
          userId: '@all',
          mentionAllUserIds: recipients)
    ];
    store.save('k', RoomDraft('@所有人 ', tokens: tokens));
    recipients.add('@b:s');
    tokens.clear();
    final snapshot = (await store.read('k'))!;
    expect(snapshot.tokens.single.mentionAllUserIds, ['@a:s']);
    expect(() => snapshot.tokens.single.mentionAllUserIds!.add('@c:s'),
        throwsUnsupportedError);
    await store.flush('k');
    final restored = (await RoomDraftStore(disk).read('k'))!;
    expect(restored.tokens.single.mentionAllUserIds, ['@a:s']);
    expect(() => restored.tokens.single.mentionAllUserIds!.clear(),
        throwsUnsupportedError);
  });

  test('in flight old write finishes before send clear and new draft',
      () async {
    final disk = MemoryStore()..blockedWrite = Completer<void>();
    final store = RoomDraftStore(disk);
    store.save('k', const RoomDraft('第一条'));
    final oldWrite = store.flush('k');
    await Future<void>.delayed(Duration.zero);
    store.save('k', const RoomDraft(''));
    final cleared = store.flush('k');
    store.save('k', const RoomDraft('第二条未发送'));
    final latest = store.flush('k');
    disk.blockedWrite!.complete();
    await Future.wait([oldWrite, cleared, latest]);
    expect((await RoomDraftStore(disk).read('k'))?.text, '第二条未发送');
  });

  test('malformed draft and invalid mention ranges do not create recipients',
      () async {
    final disk = MemoryStore();
    disk.data['bad'] = '{broken';
    expect(await RoomDraftStore(disk).read('bad'), isNull);
    final draft = RoomDraft.decode(
        '{"text":"原文","tokens":[{"start":0,"end":90,"display":"名字","userId":"@u:s"}]}');
    expect(draft.text, '原文');
    expect(draft.tokens, isEmpty);
  });
  test('rooms accounts and servers have separate persistent drafts', () async {
    final disk = MemoryStore();
    final store = RoomDraftStore(disk);
    final keys = [
      RoomDraftStore.key('s', 'a', '1'),
      RoomDraftStore.key('s', 'a', '2'),
      RoomDraftStore.key('s', 'b', '1'),
      RoomDraftStore.key('t', 'a', '1')
    ];
    for (var i = 0; i < keys.length; i++) {
      store.save(keys[i], RoomDraft('草稿$i'));
      await store.flush(keys[i]);
    }
    final restored = RoomDraftStore(disk);
    for (var i = 0; i < keys.length; i++) {
      expect((await restored.read(keys[i]))?.text, '草稿$i');
    }
    expect(RoomDraftStore.key('ab', 'c', 'd'),
        isNot(RoomDraftStore.key('a', 'bc', 'd')));
  });
  test('send clear survives reopening and pending old read cannot resurrect',
      () async {
    final disk = MemoryStore();
    final store = RoomDraftStore(disk);
    store.save('key', const RoomDraft('原文'));
    await store.flush('key');
    disk.blockedRead = Completer<String?>();
    final next = RoomDraftStore(disk);
    final reading = next.read('key');
    next.save('key', const RoomDraft(''));
    await next.flush('key');
    disk.blockedRead!.complete('{"text":"原文"}');
    expect(await reading, isNull);
    disk.blockedRead = null;
    expect(await RoomDraftStore(disk).read('key'), isNull);
  });
  test('valid structured mentions persist; plain at text stays plain',
      () async {
    final disk = MemoryStore();
    final store = RoomDraftStore(disk);
    final model = MentionComposerModel(text: '@');
    model.triggerAt(0);
    model.replaceTrigger(displayName: '兄弟', userId: '@u:s');
    store.save('k', RoomDraft(model.text, tokens: model.tokens));
    await store.flush('k');
    final restored = await RoomDraftStore(disk).read('k');
    expect(restored?.tokens.single.userId, '@u:s');
    store.save('k', const RoomDraft('@@兄弟'));
    await store.flush('k');
    expect((await RoomDraftStore(disk).read('k'))?.tokens, isEmpty);
  });
}
