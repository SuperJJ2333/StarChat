import 'package:flutter/foundation.dart';

import '../../ui/foundation/avatar_cache.dart';

final class ProfileData {
  const ProfileData(
      {required this.username,
      required this.nickname,
      required this.maskedEmail,
      required this.fallbackSeed,
      this.signature,
      this.nudgeSuffix,
      this.avatarUrl});
  final String username, nickname, maskedEmail, fallbackSeed;
  final String? signature, nudgeSuffix, avatarUrl;
  ProfileData copyWith(
          {String? nickname,
          String? signature,
          String? nudgeSuffix,
          bool clearNudgeSuffix = false,
          String? avatarUrl,
          bool clearAvatar = false}) =>
      ProfileData(
          username: username,
          nickname: nickname ?? this.nickname,
          maskedEmail: maskedEmail,
          fallbackSeed: fallbackSeed,
          signature: signature ?? this.signature,
          nudgeSuffix:
              clearNudgeSuffix ? null : nudgeSuffix ?? this.nudgeSuffix,
          avatarUrl: clearAvatar ? null : avatarUrl ?? this.avatarUrl);
}

final class AvatarCandidate {
  const AvatarCandidate({required this.bytes, required this.mimeType});
  final Uint8List bytes;
  final String mimeType;
}

final class AvatarUploadSession {
  const AvatarUploadSession({required this.uploadId, required this.uploadUrl});
  final String uploadId, uploadUrl;
}

abstract interface class ProfileGateway {
  Future<ProfileData> loadProfile();
  Future<ProfileData> updateProfile(
      {required String nickname, String? signature, String? nudgeSuffix});
  Future<AvatarUploadSession> createAvatarUpload(
      {required String mimeType, required int byteSize});
  Future<void> putAvatar(
      AvatarUploadSession session, AvatarCandidate candidate);
  Future<ProfileData> completeAvatar(String uploadId);
  Future<void> cancelAvatar(String uploadId);
  Future<void> deleteAvatar();
}

abstract interface class AvatarSource {
  Future<AvatarCandidate?> selectCropAndCompress();
}

enum ProfileStatus {
  idle,
  loading,
  ready,
  saving,
  selectingAvatar,
  previewing,
  uploading,
  failed
}

final class ProfileState {
  const ProfileState(this.status,
      {this.profile, this.candidate, this.progress = 0, this.message});
  final ProfileStatus status;
  final ProfileData? profile;
  final AvatarCandidate? candidate;
  final double progress;
  final String? message;
}

final class ProfileController extends ChangeNotifier {
  ProfileController({
    required this.gateway,
    required this.avatarSource,
    Future<void> Function(String userId)? invalidateAvatarCache,
    this.readCachedProfile,
    this.persistProfile,
    this.onAvatarUpdated,
    ProfileData? initialProfile,
  })  : _invalidateAvatarCache =
            invalidateAvatarCache ?? AvatarCache.invalidateUser,
        state = initialProfile == null
            ? const ProfileState(ProfileStatus.idle)
            : ProfileState(ProfileStatus.ready, profile: initialProfile);
  final ProfileGateway gateway;
  final AvatarSource avatarSource;
  final Future<void> Function(String userId) _invalidateAvatarCache;
  final Future<ProfileData?> Function()? readCachedProfile;
  final Future<void> Function(ProfileData profile)? persistProfile;

  /// 新头像上传成功（本地缓存已失效）后回调，用于立即刷新所有展示该
  /// 头像的界面（身份缓存重载 → 各页面重建 → 命中新的签名 URL）。
  final VoidCallback? onAvatarUpdated;
  ProfileState state;
  AvatarCandidate? _retryCandidate;
  Future<void>? _loadFlight;
  int _generation = 0;
  bool _disposed = false;

  Future<void> load() {
    if (_disposed) return Future.value();
    final existing = _loadFlight;
    if (existing != null) return existing;
    final future = _load();
    _loadFlight = future;
    future.whenComplete(() {
      if (identical(_loadFlight, future)) _loadFlight = null;
    });
    return future;
  }

  /// Allows AppHome to provide its account repository after this tab was
  /// constructed. It fills only an empty identity section and never replaces a
  /// fresher gateway result or starts a second network request.
  Future<void> hydrateCachedProfile() async {
    if (_disposed || state.profile != null) return;
    try {
      final cached = await readCachedProfile?.call();
      if (!_disposed && state.profile == null && cached != null) {
        _set(ProfileState(ProfileStatus.ready, profile: cached));
      }
    } catch (_) {
      // The normal gateway load remains responsible for the empty-cache path.
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    if (state.profile == null) {
      _set(const ProfileState(ProfileStatus.loading));
    }
    try {
      final cached = await readCachedProfile?.call();
      if (_isCurrent(generation) && cached != null) {
        _set(ProfileState(ProfileStatus.ready, profile: cached));
      }
    } catch (_) {
      // A cache miss/read failure is inconclusive; continue with the gateway.
    }
    if (!_isCurrent(generation)) return;
    try {
      final loaded = await gateway.loadProfile();
      if (!_isCurrent(generation)) return;
      _set(ProfileState(ProfileStatus.ready, profile: loaded));
      await _persist(loaded, generation);
    } catch (_) {
      if (!_isCurrent(generation)) return;
      final current = state.profile;
      _set(ProfileState(ProfileStatus.failed,
          profile: current, message: '资料加载失败，请重试'));
    }
  }

  Future<void> save(String nickname, String? signature,
      {String? nudgeSuffix}) async {
    if (_disposed) return;
    final generation = ++_generation;
    _set(ProfileState(ProfileStatus.saving, profile: state.profile));
    try {
      final requestedNudgeSuffix = nudgeSuffix ?? state.profile?.nudgeSuffix;
      final updated = await gateway.updateProfile(
        nickname: nickname,
        signature: signature,
        nudgeSuffix: requestedNudgeSuffix,
      );
      if (!_isCurrent(generation)) return;
      final next = requestedNudgeSuffix != null && requestedNudgeSuffix.isEmpty
          ? updated.copyWith(clearNudgeSuffix: true)
          : updated;
      _set(ProfileState(
        ProfileStatus.ready,
        profile: next,
      ));
      await _persist(next, generation);
    } catch (_) {
      if (!_isCurrent(generation)) return;
      _set(ProfileState(ProfileStatus.failed,
          profile: state.profile, message: '资料保存失败，请重试'));
    }
  }

  Future<void> chooseAvatar() async {
    if (_disposed) return;
    final generation = ++_generation;
    _set(ProfileState(ProfileStatus.selectingAvatar, profile: state.profile));
    try {
      final candidate = await avatarSource.selectCropAndCompress();
      if (!_isCurrent(generation)) return;
      if (candidate == null) {
        _set(ProfileState(ProfileStatus.ready, profile: state.profile));
        return;
      }
      _retryCandidate = candidate;
      _set(ProfileState(ProfileStatus.previewing,
          profile: state.profile, candidate: candidate));
    } catch (_) {
      if (!_isCurrent(generation)) return;
      _set(ProfileState(ProfileStatus.failed,
          profile: state.profile, message: '无法访问相册，请在系统设置中允许照片权限'));
    }
  }

  void cancelPreview() {
    if (_disposed) return;
    _generation++;
    _retryCandidate = null;
    _set(ProfileState(ProfileStatus.ready, profile: state.profile));
  }

  Future<void> uploadAvatar() => _upload(_retryCandidate);
  Future<void> retryAvatar() => _upload(_retryCandidate);
  Future<void> _upload(AvatarCandidate? candidate) async {
    if (_disposed || candidate == null) return;
    final generation = ++_generation;
    AvatarUploadSession? session;
    try {
      _set(ProfileState(ProfileStatus.uploading,
          profile: state.profile, candidate: candidate, progress: .2));
      session = await gateway.createAvatarUpload(
          mimeType: candidate.mimeType, byteSize: candidate.bytes.length);
      if (!_isCurrent(generation)) return;
      _set(ProfileState(ProfileStatus.uploading,
          profile: state.profile, candidate: candidate, progress: .55));
      await gateway.putAvatar(session, candidate);
      if (!_isCurrent(generation)) return;
      _set(ProfileState(ProfileStatus.uploading,
          profile: state.profile, candidate: candidate, progress: .85));
      final profile = await gateway.completeAvatar(session.uploadId);
      if (!_isCurrent(generation)) return;
      await _invalidateAvatarCache(profile.fallbackSeed);
      if (!_isCurrent(generation)) return;
      _retryCandidate = null;
      _set(ProfileState(ProfileStatus.ready, profile: profile, progress: 1));
      await _persist(profile, generation);
      if (_isCurrent(generation)) onAvatarUpdated?.call();
    } catch (_) {
      if (!_isCurrent(generation)) return;
      _set(ProfileState(ProfileStatus.failed,
          profile: state.profile,
          candidate: candidate,
          progress: state.progress,
          message: '头像上传失败，请重试'));
    }
  }

  Future<void> restoreDefaultAvatar() async {
    if (_disposed) return;
    final generation = ++_generation;
    await gateway.deleteAvatar();
    if (!_isCurrent(generation)) return;
    final current = state.profile;
    if (current != null) await _invalidateAvatarCache(current.fallbackSeed);
    if (!_isCurrent(generation)) return;
    if (current != null) {
      _set(ProfileState(ProfileStatus.ready,
          profile: current.copyWith(clearAvatar: true)));
      await _persist(state.profile!, generation);
    }
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  Future<void> _persist(ProfileData profile, int generation) async {
    if (!_isCurrent(generation)) return;
    try {
      await persistProfile?.call(profile);
    } catch (_) {
      // The displayed successful mutation remains valid if the local cache
      // temporarily cannot persist; a future gateway refresh can retry it.
    }
    if (!_isCurrent(generation)) return;
  }

  void _set(ProfileState next) {
    if (_disposed) return;
    state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
