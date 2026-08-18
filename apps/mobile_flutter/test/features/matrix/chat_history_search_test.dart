import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_history_search.dart';

void main() {
  final entries = [
    LocalChatSearchEntry(
      eventId: r'$1',
      senderId: '@alice:test',
      timestamp: DateTime.utc(2026, 8, 18),
      text: '查看 https://example.com 设计稿',
    ),
    LocalChatSearchEntry(
      eventId: r'$2',
      senderId: '@bob:test',
      timestamp: DateTime.utc(2026, 8, 17),
      kind: LocalChatSearchKind.image,
      text: '图片',
    ),
    LocalChatSearchEntry(
      eventId: r'$3',
      senderId: '@alice:test',
      timestamp: DateTime.utc(2026, 8, 16),
      kind: LocalChatSearchKind.file,
      text: '方案.pdf',
    ),
  ];

  test('local search filters keyword media file link date and sender', () {
    expect(searchLocalChat(entries, query: '设计稿').single.eventId, r'$1');
    expect(
        searchLocalChat(entries, category: ChatSearchCategory.media)
            .single
            .eventId,
        r'$2');
    expect(
        searchLocalChat(entries, category: ChatSearchCategory.files)
            .single
            .eventId,
        r'$3');
    expect(
        searchLocalChat(entries, category: ChatSearchCategory.links)
            .single
            .eventId,
        r'$1');
    expect(
        searchLocalChat(entries, senderId: '@bob:test').single.eventId, r'$2');
    expect(
        searchLocalChat(entries, date: DateTime.utc(2026, 8, 16))
            .single
            .eventId,
        r'$3');
  });

  test('group exposes member category while direct chat does not', () {
    expect(chatSearchCategories(isGroup: true),
        contains(ChatSearchCategory.members));
    expect(chatSearchCategories(isGroup: false),
        isNot(contains(ChatSearchCategory.members)));
  });
}
