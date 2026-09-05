enum MuteNotificationDecision { normal, exception, suppressed }

final class MuteExceptionSettings {
  const MuteExceptionSettings({
    this.muted = false,
    this.notifyMentionMe = false,
    this.notifyMentionAll = false,
    this.notifyAnnouncement = false,
    this.followedMemberIds = const [],
  });
  final bool muted;
  final bool notifyMentionMe;
  final bool notifyMentionAll;
  final bool notifyAnnouncement;
  final List<String> followedMemberIds;
}

final class MuteEventFacts {
  const MuteEventFacts({
    required this.senderId,
    this.mentionsMe = false,
    this.mentionsAll = false,
    this.isAnnouncement = false,
  });
  final String senderId;
  final bool mentionsMe;
  final bool mentionsAll;
  final bool isAnnouncement;
}

MuteNotificationDecision evaluateMuteNotification(
  MuteExceptionSettings settings,
  MuteEventFacts facts,
) {
  if (!settings.muted) return MuteNotificationDecision.normal;
  if ((facts.mentionsMe && settings.notifyMentionMe) ||
      (facts.mentionsAll && settings.notifyMentionAll) ||
      (facts.isAnnouncement && settings.notifyAnnouncement) ||
      settings.followedMemberIds.contains(facts.senderId)) {
    return MuteNotificationDecision.exception;
  }
  return MuteNotificationDecision.suppressed;
}
