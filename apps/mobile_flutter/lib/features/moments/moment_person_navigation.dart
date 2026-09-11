import '../contacts/contact_actions.dart';
import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../contacts/contacts_page.dart';
import '../contacts/add_friend_profile_page.dart';
import '../matrix/profile_repository.dart';
import 'moment_models.dart';

Future<void> openMomentPerson(
  BuildContext context, {
  required BusinessApiClient api,
  required ProfileRepository? identityCache,
  required MomentAuthor person,
  ContactActions? contactActions,
}) async {
  final viewerId = await api.currentUserId();
  final own = (person.userId.isNotEmpty && person.userId == viewerId) ||
      (person.username.isNotEmpty &&
          person.username == identityCache?.profile?.username);
  var contact = identityCache?.contacts
      .where((c) =>
          c.userId == person.userId ||
          (person.username.isNotEmpty && c.username == person.username))
      .firstOrNull;
  if (contact == null && !own) {
    final contacts = await api.listContacts();
    contact = contacts
        .where((c) =>
            c.userId == person.userId ||
            (person.username.isNotEmpty && c.username == person.username))
        .firstOrNull;
  }
  if (!context.mounted) return;
  await Navigator.push(
      context,
      CupertinoPageRoute(
          builder: (_) => contact != null
              ? ContactProfilePage(
              onMessage: contactActions?.onMessage,
              onVoice: contactActions?.onVoice,
              onVideo: contactActions?.onVideo,
              api: api,
                  identityCache: identityCache,
                  initialContact: contact.toDetails(),
                  onContactUpdated: (updated) async {
                    await identityCache
                        ?.applyUpdatedContact(updated.toSummary());
                  },
                  onContactDeleted: (id) async {
                    await identityCache?.removeContact(id);
                  })
              : AddFriendProfilePage(
              contactActions: contactActions,
              api: api,
                  identityCache: identityCache,
                  userId: own ? viewerId ?? person.userId : person.userId,
                  username: person.username,
                  nickname: person.displayName,
                  avatarUrl: person.avatarUrl,
                  relationshipState: own ? 'SELF' : 'NONE')));
}
