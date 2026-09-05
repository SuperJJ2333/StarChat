import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/business_api_client.dart';
import '../../ui/foundation/avatar_cache.dart';
import '../contacts/contact_models.dart';
import '../profile/profile_controller.dart';

/// 好友资料统一投影（BUG 1）：头像按 `avatar:{userId}:{avatarVersion}` 键控，
/// 版本变化即视为新头像并逐出旧缓存。
final class FriendProfile {
  const FriendProfile({
    required this.userId,
    required this.nickname,
    required this.avatarUrl,
    required this.avatarVersion,
    required this.updatedAt,
  });

  factory FriendProfile.fromContact(ContactSummary contact, DateTime at) {
    final nickname = contact.nickname;
    return FriendProfile(
      userId: contact.userId,
      nickname:
          nickname == null || nickname.isEmpty ? contact.username : nickname,
      avatarUrl: contact.avatarUrl,
      avatarVersion: contact.avatarUrl == null
          ? 'none'
          : AvatarCache.avatarVersion(contact.avatarUrl!),
      updatedAt: at,
    );
  }

  final String userId;
  final String nickname;
  final String? avatarUrl;
  final String avatarVersion;
  final DateTime updatedAt;

  /// 统一缓存键（PRD BUG 1：avatar:{userId}:{avatarVersion}）。
  String get avatarCacheKey => 'avatar:$userId:$avatarVersion';
}

/// The non-sensitive identity metadata required to paint chat avatars before a
/// network refresh. It deliberately excludes business and Matrix credentials.
final class ProfileSnapshot {
  const ProfileSnapshot({
    required this.profile,
    required this.contacts,
    this.contactsRevision = 0,
  });

  final ProfileData profile;
  final List<ContactSummary> contacts;

  /// 好友数据修订号：任何好友集合/资料变化时递增（BUG 3）。
  final int contactsRevision;

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
        'contacts_revision': contactsRevision,
      };

  static ProfileSnapshot? fromJson(Object? encoded) {
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
    final revision = encoded['contacts_revision'];
    return ProfileSnapshot(
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
      contactsRevision: revision is int ? revision : 0,
    );
  }
}

abstract interface class ProfileStore {
  Future<ProfileSnapshot?> read(String accountKey);
  Future<void> write(String accountKey, ProfileSnapshot snapshot);
}

/// SQLite 快照存储（BUG 1 整改：替换 SharedPreferences）。
final class SqliteProfileStore implements ProfileStore {
  SqliteProfileStore({
    String? databasePath,
    DatabaseFactory? factory,
    Future<String> Function()? supportDirectory,
  })  : _databasePath = databasePath,
        _factory = factory ?? databaseFactoryFfi,
        _supportDirectory = supportDirectory ?? _defaultSupportDirectory;

  static const _databaseName = 'chatflow_profile_v1.db';
  static const _table = 'profile_snapshots';
  static const _legacyPrefix = 'changliao.chat_identity.v1.';

  /// Android 上 databaseFactoryFfi.getDatabasesPath() 返回的目录不可写
  /// （SQLITE_CANTOPEN 14，Mi 6 实测）。与 Matrix SDK 本地库同源，
  /// 使用 path_provider 的应用支持目录。
  static Future<String> _defaultSupportDirectory() async =>
      (await getApplicationSupportDirectory()).path;

  final String? _databasePath;
  final DatabaseFactory _factory;
  final Future<String> Function() _supportDirectory;
  Database? _database;

  /// 探活：打开并建表。ProfileRepository.create 用它决定是否降级。
  Future<void> probe() => _open();

  Future<Database> _open() async {
    final existing = _database;
    if (existing != null && existing.isOpen) return existing;
    String path = _databasePath ?? '';
    if (path.isEmpty) {
      path = p.join(await _supportDirectory(), _databaseName);
    }
    _database = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            create table $_table(
              account_key text primary key,
              payload text not null,
              revision integer not null,
              updated_at integer not null
            )
          ''');
        },
      ),
    );
    return _database!;
  }

  @override
  Future<ProfileSnapshot?> read(String accountKey) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      columns: ['payload'],
      where: 'account_key = ?',
      whereArgs: [accountKey],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final snapshot = ProfileSnapshot.fromJson(
        jsonDecode(rows.first['payload'] as String),
      );
      if (snapshot != null) return snapshot;
    }
    // 迁移：旧版 SharedPreferences 快照一次性搬入 SQLite。
    final legacy = await _readLegacy(accountKey);
    if (legacy != null) {
      await write(accountKey, legacy);
    }
    return legacy;
  }

  Future<ProfileSnapshot?> _readLegacy(String accountKey) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(
          '$_legacyPrefix${base64UrlEncode(utf8.encode(accountKey))}');
      if (raw == null) return null;
      return ProfileSnapshot.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) async {
    final db = await _open();
    await db.insert(
      _table,
      {
        'account_key': accountKey,
        'payload': jsonEncode(snapshot.toJson()),
        'revision': snapshot.contactsRevision,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

/// 降级存储：SQLite 不可用（目录不可写等）时兜底，保证身份加载
/// 永不因存储问题被阻断（Mi 6 SQLITE_CANTOPEN 实测教训）。
final class SharedPreferencesProfileStore implements ProfileStore {
  SharedPreferencesProfileStore(this._preferences);

  static const _prefix = 'changliao.chat_identity.v1.';
  final SharedPreferences _preferences;

  String _key(String accountKey) =>
      '$_prefix${base64UrlEncode(utf8.encode(accountKey))}';

  @override
  Future<ProfileSnapshot?> read(String accountKey) async {
    final raw = _preferences.getString(_key(accountKey));
    if (raw == null) return null;
    try {
      return ProfileSnapshot.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(String accountKey, ProfileSnapshot snapshot) =>
      _preferences.setString(_key(accountKey), jsonEncode(snapshot.toJson()));
}

/// 统一资料仓库（BUG 1）：消息页、通讯录、朋友圈的唯一好友资料来源。
///
/// - [hydrate] 在任何聊天路由构建前恢复磁盘快照（旧头像 URL 立即可用）；
/// - [preload]/[refresh] 从业务 API 整表刷新；
/// - [refreshContactsQuietly] 静默拉取好友列表：仅在有变化（昵称/头像/
///   备注等）时更新 SQLite、逐出旧头像缓存并 notify——供回前台与
///   好友申请轮询周期触发，通讯录实时重绘、禁止等待重启；
/// - [contactsRevision] 随任何好友数据变化递增，供消费方判断数据新旧。
final class ProfileRepositoryError {
  const ProfileRepositoryError({
    required this.operation,
    required this.errorType,
    required this.accountKeyHash,
    required this.stackTrace,
  });

  final String operation;
  final String errorType;
  final String accountKeyHash;
  final StackTrace stackTrace;

  String toDiagnosticString() =>
      'operation=$operation account=$accountKeyHash error_type=$errorType';
}

typedef ProfileErrorReporter = void Function(ProfileRepositoryError error);

final class ProfileRepository extends ChangeNotifier {
  ProfileRepository(BusinessApiClient api,
      {String? accountKey, ProfileStore? store})
      : api = api,
        _accountKey = accountKey,
        _store = store,
        _loadProfile = api.loadProfile,
        _loadContacts = api.listContacts,
        _onError = null;

  ProfileRepository.forTesting({
    required String accountKey,
    required ProfileStore store,
    Future<ProfileData> Function()? loadProfile,
    Future<List<ContactSummary>> Function()? loadContacts,
    ProfileErrorReporter? onError,
  })  : api = null,
        _accountKey = accountKey,
        _store = store,
        _loadProfile = loadProfile,
        _loadContacts = loadContacts,
        _onError = onError;

  static Future<ProfileRepository> create({
    required BusinessApiClient api,
    required String accountKey,
  }) async {
    // 存储策略：SQLite（应用支持目录）→ 探活失败降级 SharedPreferences。
    // 任何存储故障都不得阻断身份加载（否则消息/通讯录页永久加载中）。
    ProfileStore store;
    try {
      final sqlite = SqliteProfileStore();
      await sqlite.probe();
      store = sqlite;
    } catch (_) {
      store = SharedPreferencesProfileStore(
        await SharedPreferences.getInstance(),
      );
    }
    return ProfileRepository(api, accountKey: accountKey, store: store);
  }

  final BusinessApiClient? api;
  final String? _accountKey;
  final ProfileStore? _store;
  final Future<ProfileData> Function()? _loadProfile;
  final Future<List<ContactSummary>> Function()? _loadContacts;
  final ProfileErrorReporter? _onError;
  Future<void>? _hydrate;
  Future<void>? _preload;
  DateTime? _lastContactsRefreshAt;

  ProfileData? profile;
  List<ContactSummary> contacts = const [];
  Map<String, ContactDetails> contactsByMatrixId = const {};
  bool wasHydratedFromDisk = false;
  int contactsRevision = 0;

  Future<void> hydrate() => _hydrate ??= _hydrateNow();

  Future<void> _hydrateNow() async {
    final store = _store;
    final key = _accountKey;
    if (store == null || key == null) return;
    final snapshot = await store.read(key);
    if (snapshot == null) return;
    _apply(snapshot, invalidateChangedAvatars: false);
    wasHydratedFromDisk = true;
  }

  Future<void> preload() => _preload ??= _load(operation: 'preload');

  Future<void> refresh() => _load(operation: 'refresh');

  /// 静默好友刷新：回前台/申请轮询周期触发。有变化才落库+失效+notify；
  /// 失败静默（弱网不打扰），带最小间隔节流。
  Future<void> refreshContactsQuietly({
    Duration minInterval = const Duration(seconds: 15),
    DateTime Function()? now,
  }) async {
    final clock = now ?? DateTime.now;
    final last = _lastContactsRefreshAt;
    if (last != null && clock().difference(last) < minInterval) return;
    _lastContactsRefreshAt = clock();
    final loadContacts = _loadContacts;
    if (loadContacts == null) return;
    try {
      final fresh = await loadContacts();
      if (_contactsEqual(contacts, fresh)) return;
      final currentProfile = profile;
      if (currentProfile == null) return;
      await _applyAndPersist(ProfileSnapshot(
        profile: currentProfile,
        contacts: List.unmodifiable(fresh),
        contactsRevision: contactsRevision + 1,
      ));
    } catch (_) {
      // 静默：下次触发重试。
    }
  }

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
      await _applyAndPersist(ProfileSnapshot(
        profile: results[0] as ProfileData,
        contacts: results[1] as List<ContactSummary>,
        contactsRevision:
            _contactsEqual(contacts, results[1] as List<ContactSummary>)
                ? contactsRevision
                : contactsRevision + 1,
      ));
    } catch (error, stackTrace) {
      _report(operation, error, stackTrace);
      rethrow;
    }
  }

  /// BUG 3：accept 后乐观写入（也用于备注/标签等单点更新）。
  Future<void> applyUpdatedContact(ContactSummary updated) async {
    final currentProfile = profile;
    if (currentProfile == null) {
      // 尚无 profile 快照：仅更新内存并通知（与旧实现一致，不落库）。
      contacts = List.unmodifiable([updated]);
      contactsByMatrixId = {
        for (final contact in contacts)
          contact.matrixUserId: contact.toDetails(),
      };
      contactsRevision += 1;
      notifyListeners();
      return;
    }
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
    await _applyAndPersist(ProfileSnapshot(
      profile: currentProfile,
      contacts: List.unmodifiable(next),
      contactsRevision: contactsRevision + 1,
    ));
  }

  Future<void> removeContact(String userId) async {
    final currentProfile = profile;
    if (currentProfile == null) return;
    final next = [
      for (final contact in contacts)
        if (contact.userId != userId) contact,
    ];
    if (next.length == contacts.length) return;
    await _applyAndPersist(ProfileSnapshot(
      profile: currentProfile,
      contacts: List.unmodifiable(next),
      contactsRevision: contactsRevision + 1,
    ));
  }

  /// 当前全部好友的规范资料投影。
  List<FriendProfile> friendProfiles({DateTime Function()? now}) {
    final at = (now ?? DateTime.now)();
    return [
      for (final contact in contacts) FriendProfile.fromContact(contact, at),
    ];
  }

  Future<void> _applyAndPersist(ProfileSnapshot snapshot) async {
    _apply(snapshot);
    await _persist(operation: 'profile.persist');
  }

  Future<void> _persist({required String operation}) async {
    final store = _store;
    final key = _accountKey;
    if (store != null && key != null && profile != null) {
      try {
        await store.write(
          key,
          ProfileSnapshot(
            profile: profile!,
            contacts: contacts,
            contactsRevision: contactsRevision,
          ),
        );
      } catch (error, stackTrace) {
        _report(operation, error, stackTrace);
      }
    }
  }

  void _apply(ProfileSnapshot snapshot,
      {bool invalidateChangedAvatars = true}) {
    final previous = contacts;
    final previousByMatrixId = contactsByMatrixId;
    profile = snapshot.profile;
    contacts = snapshot.contacts;
    contactsByMatrixId = {
      for (final contact in contacts) contact.matrixUserId: contact.toDetails(),
    };
    if (invalidateChangedAvatars) {
      // 头像 URL/版本变化 → 逐出旧缓存（BUG 1：通讯录不得滞留旧头像）。
      for (final entry in contactsByMatrixId.entries) {
        final previousAvatar = previousByMatrixId[entry.key]?.avatarUrl;
        final currentAvatar = entry.value.avatarUrl;
        if (previousAvatar != currentAvatar) {
          unawaited(AvatarCache.invalidateUser(entry.key).catchError((_) {}));
        }
      }
    }
    if (!_contactsEqual(previous, contacts)) {
      contactsRevision = snapshot.contactsRevision;
    }
    notifyListeners();
  }

  void _report(String operation, Object error, StackTrace stackTrace) {
    final cacheError = ProfileRepositoryError(
      operation: operation,
      errorType: error.runtimeType.toString(),
      accountKeyHash:
          (_accountKey ?? 'unknown').hashCode.toUnsigned(32).toRadixString(16),
      stackTrace: stackTrace,
    );
    _onError?.call(cacheError);
    developer.log(
      'Profile repository operation failed ${cacheError.toDiagnosticString()}',
      name: 'ProfileRepository',
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

bool _contactsEqual(List<ContactSummary> a, List<ContactSummary> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].userId != b[i].userId ||
        a[i].username != b[i].username ||
        a[i].matrixUserId != b[i].matrixUserId ||
        a[i].nickname != b[i].nickname ||
        a[i].remark != b[i].remark ||
        a[i].avatarUrl != b[i].avatarUrl ||
        a[i].momentsPermission != b[i].momentsPermission ||
        a[i].starred != b[i].starred) {
      return false;
    }
    if (a[i].tags.length != b[i].tags.length) return false;
    for (var j = 0; j < a[i].tags.length; j++) {
      if (a[i].tags[j] != b[i].tags[j]) return false;
    }
  }
  return true;
}
