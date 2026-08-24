final class ConversationIdentity {
  const ConversationIdentity({
    required this.matrixUserId,
    this.remark,
    this.nickname,
    this.username,
    this.matrixDisplayName,
  });

  final String matrixUserId;
  final String? remark;
  final String? nickname;
  final String? username;
  final String? matrixDisplayName;
}

String? _normalized(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String _matrixLocalpart(String matrixUserId) {
  final withoutSigil =
      matrixUserId.startsWith('@') ? matrixUserId.substring(1) : matrixUserId;
  return withoutSigil.split(':').first;
}

String directConversationTitle(ConversationIdentity identity) =>
    _normalized(identity.remark) ??
    _normalized(identity.nickname) ??
    _normalized(identity.username) ??
    _normalized(identity.matrixDisplayName) ??
    _matrixLocalpart(identity.matrixUserId);

String conversationSenderName(ConversationIdentity identity) =>
    _normalized(identity.remark) ??
    _normalized(identity.nickname) ??
    _normalized(identity.matrixDisplayName) ??
    _matrixLocalpart(identity.matrixUserId);

String groupConversationTitle(List<ConversationIdentity> members) => members
    .map(conversationSenderName)
    .where((name) => name.isNotEmpty)
    .join('、');

String groupConversationSubtitle({
  required int unreadCount,
  required String senderName,
  required String messageContent,
  bool redacted = false,
  String? systemSummary,
}) {
  final prefix = unreadCount > 0 ? '[$unreadCount条]' : '';
  final system = _normalized(systemSummary);
  if (system != null) return '$prefix$system';
  final sender = _normalized(senderName) ?? '好友';
  if (redacted) return '$prefix$sender撤回了一条消息';
  return '$prefix$sender：$messageContent';
}
