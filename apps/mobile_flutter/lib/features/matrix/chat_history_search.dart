enum LocalChatSearchKind { text, image, video, file }

enum ChatSearchCategory { date, media, files, links, members }

final class LocalChatSearchEntry {
  const LocalChatSearchEntry({
    required this.eventId,
    required this.senderId,
    required this.timestamp,
    required this.text,
    this.kind = LocalChatSearchKind.text,
  });
  final String eventId;
  final String senderId;
  final DateTime timestamp;
  final String text;
  final LocalChatSearchKind kind;

  bool get containsLink => RegExp(r'https?://[^\s]+').hasMatch(text);
}

List<ChatSearchCategory> chatSearchCategories({required bool isGroup}) => [
      ChatSearchCategory.date,
      ChatSearchCategory.media,
      ChatSearchCategory.files,
      ChatSearchCategory.links,
      if (isGroup) ChatSearchCategory.members,
    ];

List<LocalChatSearchEntry> searchLocalChat(
  Iterable<LocalChatSearchEntry> entries, {
  String query = '',
  ChatSearchCategory? category,
  String? senderId,
  DateTime? date,
}) {
  final normalized = query.trim().toLowerCase();
  return entries.where((entry) {
    if (normalized.isNotEmpty &&
        !entry.text.toLowerCase().contains(normalized)) {
      return false;
    }
    if (senderId != null && entry.senderId != senderId) return false;
    if (date != null &&
        (entry.timestamp.year != date.year ||
            entry.timestamp.month != date.month ||
            entry.timestamp.day != date.day)) {
      return false;
    }
    return switch (category) {
      ChatSearchCategory.media => entry.kind == LocalChatSearchKind.image ||
          entry.kind == LocalChatSearchKind.video,
      ChatSearchCategory.files => entry.kind == LocalChatSearchKind.file,
      ChatSearchCategory.links => entry.containsLink,
      _ => true,
    };
  }).toList(growable: false);
}
