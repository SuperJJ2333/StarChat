import 'dart:convert';
import 'dart:developer' as developer;

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
          'nudge_suffix': profile.nudgeSuffix,
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
        nudgeSuffix: profileJson['nudge_suffix']?.toString(),
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
final class ChatIdentityCacheError {
  const ChatIdentityCacheError({
    required this.operation,
    required this.errorType,
    required this.accountKeyHash,
    required this.error,
    required this.stackTrace,
  });

  final String operation;
  final String errorType;
  final String accountKeyHash;
  final Object error;
  final StackTrace stackTrace;
}

typedef ChatIdentityErrorReporter = void Function(ChatIdentityCacheError error);

final class ChatIdentityCache extends ChangeNotifier {
  ChatIdentityCache(BusinessApiClient api,
      {String? accountKey, ChatIdentityStore? store})
      : api = api,
        _accountKey = accountKey,
        _store = store,
        _loadProfile = api.loadProfile,
        _loadContacts = api.listContacts,
        _onError = null;

  ChatIdentityCache.forTesting({
    required String accountKey,
    required ChatIdentityStore store,
    Future<ProfileData> Function()? loadProfile,
    Future<List<ContactSummary>> Function()? loadContacts,
    ChatIdentityErrorReporter? onError,
  })  : api = null,
        _accountKey = accountKey,
        _store = store,
        _loadProfile = loadProfile,
        _loadContacts = loadContacts,
        _onError = onError;

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
  final Future<ProfileData> Function()? _loadProfile;
  final Future<List<ContactSummary>> Function()? _loadContacts;
  final ChatIdentityErrorReporter? _onError;
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

  Future<void> preload() => _preload ??= _load(operation: 'preload');

  Future<void> refresh() => _load(operation: 'refresh');

  Future<void> _load({required String operation}) async {
    await hydrate();
    final loadProfile = _loadProfile;
    final loadContacts = _loadContacts;
    if (loadProfile == null || loadContacts == null) return;
    try {
      final results = await Future.wait<Object>([
        loadProfile(),
        loadContacts(),
      ]);
      _apply(ChatIdentitySnapshot(
        profile: results[0] as ProfileData,
        contacts: results[1] as List<ContactSummary>,
      ));
    } catch (error, stackTrace) {
      _report(operation, error, stackTrace);
      rethrow;
    }
    await _persist(operation: '$operation.persist');
  }

  Future<void> applyUpdatedContact(ContactSummary updated) async {
    final next = <ContactSummary>[];
    var replaced = false;
    for (final contact in contacts) {
      if (contact.userId == updated.userId ||
          contact.matrixUserId == updated.matrixUserId) {
        next.add(updated);
        replaced = true;
      } else {
        next.add(contact);
      }
    }
    if (!replaced) next.add(updated);
    final currentProfile = profile;
    if (currentProfile == null) {
      contacts = List.unmodifiable(next);
      contactsByMatrixId = {
        for (final contact in contacts)
          contact.matrixUserId: contact.toDetails(),
      };
      notifyListeners();
      return;
    }
    _apply(ChatIdentitySnapshot(
      profile: currentProfile,
      contacts: List.unmodifiable(next),
    ));
    await _persist(operation: 'contact_update.persist');
  }

  Future<void> _persist({required String operation}) async {
    final store = _store;
    final key = _accountKey;
    if (store != null && key != null && profile != null) {
      try {
        await store.write(
          key,
          ChatIdentitySnapshot(profile: profile!, contacts: contacts),
        );
      } catch (error, stackTrace) {
        _report(operation, error, stackTrace);
      }
    }
  }

  void _apply(ChatIdentitySnapshot snapshot) {
    profile = snapshot.profile;
    contacts = snapshot.contacts;
    contactsByMatrixId = {
      for (final contact in contacts) contact.matrixUserId: contact.toDetails(),
    };
    notifyListeners();
  }

  void _report(String operation, Object error, StackTrace stackTrace) {
    final cacheError = ChatIdentityCacheError(
      operation: operation,
      errorType: error.runtimeType.toString(),
      accountKeyHash:
          (_accountKey ?? 'unknown').hashCode.toUnsigned(32).toRadixString(16),
      error: error,
      stackTrace: stackTrace,
    );
    _onError?.call(cacheError);
    developer.log(
      'Identity cache operation failed '
      'operation=${cacheError.operation} '
      'account=${cacheError.accountKeyHash} '
      'error_type=${cacheError.errorType}',
      name: 'ChatIdentityCache',
      error: error,
      stackTrace: stackTrace,
    );
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
