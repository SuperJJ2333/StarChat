import 'package:flutter/cupertino.dart';

import '../../ui/components/user_avatar.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'matrix_user_avatar.dart';

/// A member from the current joined Matrix room snapshot plus an optional,
/// verified business identity. Matrix IDs are only display/routing identities;
/// financial requests must use [businessUserId].
final class GroupMemberIdentity {
  const GroupMemberIdentity({
    required this.matrixUserId,
    required this.displayName,
    this.matrixAvatarUri,
    this.businessUserId,
    this.businessAvatarUrl,
  });

  final String matrixUserId;
  final String displayName;
  final Uri? matrixAvatarUri;
  final String? businessUserId;
  final String? businessAvatarUrl;

  GroupMemberIdentity withBusinessIdentity({
    required String userId,
    String? avatarUrl,
  }) =>
      GroupMemberIdentity(
        matrixUserId: matrixUserId,
        displayName: displayName,
        matrixAvatarUri: matrixAvatarUri,
        businessUserId: userId,
        businessAvatarUrl: avatarUrl ?? businessAvatarUrl,
      );
}

/// Shared, joined-members-only presentation for group transfer and exclusive
/// red-packet recipients. It never owns or loads a full contacts directory.
final class GroupMemberPicker extends StatefulWidget {
  const GroupMemberPicker({
    super.key,
    required this.title,
    required this.members,
    this.selectedMatrixUserId,
    this.avatarMedia,
    this.itemKeyPrefix = 'group-member',
    this.onSelected,
  });

  final String title;
  final List<GroupMemberIdentity> members;
  final String? selectedMatrixUserId;
  final AvatarMediaCapability? avatarMedia;
  final String itemKeyPrefix;
  final ValueChanged<GroupMemberIdentity>? onSelected;

  static Future<GroupMemberIdentity?> show(
    BuildContext context, {
    required String title,
    required List<GroupMemberIdentity> members,
    String? selectedMatrixUserId,
    AvatarMediaCapability? avatarMedia,
    required String itemKeyPrefix,
  }) =>
      showCupertinoModalPopup<GroupMemberIdentity>(
        context: context,
        builder: (popupContext) => CupertinoPopupSurface(
          child: SafeArea(
            child: SizedBox(
              height: 400,
              child: GroupMemberPicker(
                title: title,
                members: members,
                selectedMatrixUserId: selectedMatrixUserId,
                avatarMedia: avatarMedia,
                itemKeyPrefix: itemKeyPrefix,
                onSelected: (member) => Navigator.pop(popupContext, member),
              ),
            ),
          ),
        ),
      );

  @override
  State<GroupMemberPicker> createState() => _GroupMemberPickerState();
}

final class _GroupMemberPickerState extends State<GroupMemberPicker> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.text.trim().toLowerCase();
    final members = query.isEmpty
        ? widget.members
        : widget.members
            .where((member) =>
                member.displayName.toLowerCase().contains(query) ||
                member.matrixUserId.toLowerCase().contains(query))
            .toList(growable: false);
    return Column(children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Text(widget.title,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: CupertinoSearchTextField(
              key: const Key('group-member-picker-search'),
              controller: _query,
              placeholder: '搜索成员',
              onChanged: (_) => setState(() {}))),
      if (members.isEmpty)
        Expanded(
            child: Center(
                child: Text(
                    widget.members.isEmpty ? '群成员尚未加载，请稍后再试' : '没有匹配的群成员',
                    style: const TextStyle(color: WeChatColors.textSecondary))))
      else
        Expanded(
            child: ListView.builder(
          key: Key('${widget.itemKeyPrefix}-list'),
          itemCount: members.length,
          itemBuilder: (context, index) {
            final member = members[index];
            return CupertinoButton(
              key: Key('${widget.itemKeyPrefix}-${member.matrixUserId}'),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              onPressed: () => widget.onSelected?.call(member),
              child: Row(children: [
                GroupMemberAvatar(
                    member: member, avatarMedia: widget.avatarMedia),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(member.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16))),
                if (widget.selectedMatrixUserId == member.matrixUserId)
                  const Icon(CupertinoIcons.check_mark,
                      size: 16, color: WeChatColors.brandPrimary),
              ]),
            );
          },
        )),
      CupertinoButton(
          onPressed: () => Navigator.maybePop(context),
          child: const Text('取消')),
    ]);
  }
}

/// Renders a selected member consistently in pickers and form headers.
final class GroupMemberAvatar extends StatelessWidget {
  const GroupMemberAvatar(
      {super.key,
      required this.member,
      required this.avatarMedia,
      this.size = 36});
  final GroupMemberIdentity member;
  final AvatarMediaCapability? avatarMedia;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (member.businessAvatarUrl != null &&
        member.businessAvatarUrl!.startsWith(RegExp(r'https?://'))) {
      return UserAvatar(
          nickname: member.displayName,
          fallbackSeed: member.businessUserId ?? member.matrixUserId,
          avatarUrl: member.businessAvatarUrl,
          size: size);
    }
    if (member.matrixAvatarUri != null && avatarMedia != null) {
      return MatrixUserAvatar(
          avatarMedia: avatarMedia!,
          nickname: member.displayName,
          fallbackSeed: member.matrixUserId,
          matrixAvatarUri: member.matrixAvatarUri,
          size: size,
          diagnosticSource: 'group-member-picker');
    }
    return UserAvatar(
        nickname: member.displayName,
        fallbackSeed: member.matrixUserId,
        size: size);
  }
}
