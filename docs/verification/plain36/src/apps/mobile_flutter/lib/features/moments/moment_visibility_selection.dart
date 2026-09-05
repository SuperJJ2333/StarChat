final class MomentVisibilitySelection {
  const MomentVisibilitySelection({
    required this.visibility,
    this.userIds = const {},
    this.tagIds = const {},
  });

  const MomentVisibilitySelection.public()
      : visibility = 'PUBLIC',
        userIds = const {},
        tagIds = const {};

  const MomentVisibilitySelection.private()
      : visibility = 'SELF',
        userIds = const {},
        tagIds = const {};

  const MomentVisibilitySelection.include({
    this.userIds = const {},
    this.tagIds = const {},
  }) : visibility = 'INCLUDE';

  const MomentVisibilitySelection.exclude({
    this.userIds = const {},
    this.tagIds = const {},
  }) : visibility = 'EXCLUDE';

  final String visibility;
  final Set<String> userIds;
  final Set<String> tagIds;

  int get selectedCount => userIds.length + tagIds.length;

  String get summary => switch (visibility) {
        'SELF' => '私密',
        'INCLUDE' => selectedCount == 0 ? '只给谁看' : '只给谁看（$selectedCount）',
        'EXCLUDE' => selectedCount == 0 ? '不给谁看' : '不给谁看（$selectedCount）',
        _ => '公开',
      };
}
