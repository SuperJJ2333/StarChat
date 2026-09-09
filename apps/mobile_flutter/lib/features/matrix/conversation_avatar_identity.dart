import '../contacts/contact_models.dart';
import '../profile/profile_controller.dart';

typedef ConversationAvatarIdentity = ({
  String seed,
  Uri? uri,
  String? profileUrl
});

ConversationAvatarIdentity conversationAvatarIdentity({
  required String matrixUserId,
  Uri? matrixAvatar,
  ContactDetails? contact,
  ProfileData? ownProfile,
}) {
  // Business identity is authoritative for known people, including removal.
  // Matrix remains the fallback for people absent from the business snapshot.
  if (ownProfile != null || contact != null) {
    final url = ownProfile != null ? ownProfile.avatarUrl : contact!.avatarUrl;
    return (
      seed: ownProfile?.fallbackSeed ?? contact!.username,
      uri: url == null ? null : Uri.tryParse(url),
      profileUrl: url
    );
  }
  return (seed: matrixUserId, uri: matrixAvatar, profileUrl: null);
}
