import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/business_api_client.dart';
import '../../ui/foundation/avatar_cache.dart';
import '../contacts/contact_models.dart';
import '../profile/profile_controller.dart';

/// The non-sensitive identity metadata required to paint chat avatars before a
/// network refresh. It deliberately excludes business and Matrix credentials.
final class ChatIdentitySnapshot {
  const ChatIdentitySnapshot({required this.profile, required this.contacts});

  final ProfileData profile;
  final List<ContactSummary> contacts;

  Map<String, dynamic> toJson() => {
        'profile': {
          'username': profile.username,
          'nickname': profile.nickname,
          'masked_email': profile.maskedEmail,
          'fallback_seed': profile.fallbackSeed,
          'signature': profile.signature,
          'avatar_url': profile.avatarUrl,
        },
        'contacts': [
          for (final contact in contacts)
            {
              'user_id': contact.userId,
              'username': contact.username,
              'matrix_user_id': contact.matrixUserId,
              'nickname': contact.nickname,
              'remark': contact.remark,
              'avatar_url': contact.avatarUrl,
              'moments_permission': contact.momentsPermission,
              'tags': contact.tags,
              'starred': contact.starred,
            },
        ],
      };

  static ChatIdentitySnapshot? fromJson(Object? encoded) {
    if (encoded is! Map<String, dynamic>) return null;
    final profileJson = encoded['profile'];
    final contactsJson = encoded['contacts'];
    if (profileJson is! Map<String, dynamic> || contactsJson is! List) {
      return null;
    }
    final username = profileJson['username'];
    final nickname = profileJson['nickname'];
    final maskedEmail = profileJson['masked_email'];
    final fallbackSeed = profileJson['fallback_seed'];
    if (username is! String ||
        nickname is! String ||
        maskedEmail is! String ||
        fallbackSeed is! String) {
      return null;
    }
    final contacts = <ContactSummary>[];
    for (final raw in contactsJson) {
      if (raw is! Map) return null;
      try {
        contacts.add(ContactSummary.fromJson(Map<String, dynamic>.from(raw)));
      } on FormatException {
        return null;
      }
    }
    return ChatIdentitySnapshot(
      profile: ProfileData(
        username: username,
        nickname: nickname,
        maskedEmail: maskedEmail,
        fallbackSeed: fallbackSeed,
        signature: profileJson['signature']?.toString(),
        avatarUrl: profileJson['avatar_url']?.toString(),
      ),
      contacts: List.unmodifiable(contacts),
    );
  }
}

abstract interface class ChatIdentityStore {
  Future<ChatIdentitySnapshot?> read(String accountKey);
  Future<void> write(String accountKey, ChatIdentitySnapshot snapshot);
}

final class SharedPreferencesChatIdentityStore implements ChatIdentityStore {
  SharedPreferencesChatIdentityStore(this._preferences);

  static const _prefix = 'changliao.chat_identity.v1.';
  final SharedPreferences _preferences;

  String _key(String accountKey) =>
      '$_prefix${base64UrlEncode(utf8.encode(accountKey))}';

  @override
  Future<ChatIdentitySnapshot?> read(String accountKey) async {
    final raw = _preferences.getString(_key(accountKey));
    if (raw == null) return null;
    try {
      return ChatIdentitySnapshot.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(String accountKey, ChatIdentitySnapshot snapshot) =>
      _preferences.setString(_key(accountKey), jsonEncode(snapshot.toJson()));
}

/// Session identity cache. [hydrate] restores prior avatar URLs before any
/// RoomPage is allowed to build; [preload] refreshes from the business API.
final class ChatIdentityCache {
  ChatIdentityCache(this.api, {String? accountKey, ChatIdentityStore? store})
      : _accountKey = accountKey,
        _store = store;

  ChatIdentityCache.forTesting({
    required String accountKey,
    required ChatIdentityStore store,
  })  : api = null,
        _accountKey = accountKey,
        _store = store;

  static Future<ChatIdentityCache> create({
    required BusinessApiClient api,
    required String accountKey,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    return ChatIdentityCache(
      api,
      accountKey: accountKey,
      store: SharedPreferencesChatIdentityStore(preferences),
    );
  }

  final BusinessApiClient? api;
  final String? _accountKey;
  final ChatIdentityStore? _store;
  Future<void>? _hydrate;
  Future<void>? _preload;
  ProfileData? profile;
  List<ContactSummary> contacts = const [];
  Map<String, ContactDetails> contactsByMatrixId = const {};
  bool wasHydratedFromDisk = false;

  Future<void> hydrate() => _hydrate ??= _hydrateNow();

  Future<void> _hydrateNow() async {
    final store = _store;
    final key = _accountKey;
    if (store == null || key == null) return;
    final snapshot = await store.read(key);
    if (snapshot == null) return;
    _apply(snapshot);
    wasHydratedFromDisk = true;
  }

  Future<void> preload() => _preload ??= _load();

  Future<void> _load() async {
    await hydrate();
    final gateway = api;
    if (gateway == null) return;
    final results = await Future.wait<Object>([
      gateway.loadProfile(),
      gateway.listContacts(),
    ]);
    _apply(ChatIdentitySnapshot(
      profile: results[0] as ProfileData,
      contacts: results[1] as List<ContactSummary>,
    ));
    final store = _store;
    final key = _accountKey;
    if (store != null && key != null && profile != null) {
      await store.write(
        key,
        ChatIdentitySnapshot(profile: profile!, contacts: contacts),
      );
    }
  }

  void _apply(ChatIdentitySnapshot snapshot) {
    profile = snapshot.profile;
    contacts = snapshot.contacts;
    contactsByMatrixId = {
      for (final contact in contacts) contact.matrixUserId: contact.toDetails(),
    };
  }

  /// Decodes known profile/contact avatar bytes before a chat route transition.
  /// Failed prewarming is non-blocking: the route still uses its metadata URL.
  Future<void> precacheAvatarImages(BuildContext context,
      {double size = 40}) async {
    final images = <(String, String)>[
      if (profile?.avatarUrl case final url?) (profile!.fallbackSeed, url),
      for (final contact in contacts)
        if (contact.avatarUrl case final url?) (contact.matrixUserId, url),
    ];
    for (final image in images) {
      try {
        await precacheImage(
          AvatarCache.imageProvider(
            userId: image.$1,
            avatarUrl: image.$2,
            size: size,
          ),
          context,
          onError: (_, __) {},
        );
      } catch (_) {
        // A subsequent network attempt and the retained image cache handle it.
      }
    }
  }
}
