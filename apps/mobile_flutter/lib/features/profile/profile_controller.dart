import 'package:flutter/foundation.dart';

final class ProfileData {
  const ProfileData(
      {required this.username,
      required this.nickname,
      required this.maskedEmail,
      required this.fallbackSeed,
      this.signature,
      this.avatarUrl});
  final String username, nickname, maskedEmail, fallbackSeed;
  final String? signature, avatarUrl;
  ProfileData copyWith(
          {String? nickname,
          String? signature,
          String? avatarUrl,
          bool clearAvatar = false}) =>
      ProfileData(
          username: username,
          nickname: nickname ?? this.nickname,
          maskedEmail: maskedEmail,
          fallbackSeed: fallbackSeed,
          signature: signature ?? this.signature,
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
      {required String nickname, String? signature});
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
  ProfileController({required this.gateway, required this.avatarSource});
  final ProfileGateway gateway;
  final AvatarSource avatarSource;
  ProfileState state = const ProfileState(ProfileStatus.idle);
  AvatarCandidate? _retryCandidate;
  Future<void> load() async {
    _set(ProfileState(ProfileStatus.loading, profile: state.profile));
    try {
      _set(ProfileState(ProfileStatus.ready,
          profile: await gateway.loadProfile()));
    } catch (_) {
      _set(ProfileState(ProfileStatus.failed,
          profile: state.profile, message: '资料加载失败，请重试'));
    }
  }

  Future<void> save(String nickname, String? signature) async {
    _set(ProfileState(ProfileStatus.saving, profile: state.profile));
    try {
      _set(ProfileState(ProfileStatus.ready,
          profile: await gateway.updateProfile(
              nickname: nickname, signature: signature)));
    } catch (_) {
      _set(ProfileState(ProfileStatus.failed,
          profile: state.profile, message: '资料保存失败，请重试'));
    }
  }

  Future<void> chooseAvatar() async {
    _set(ProfileState(ProfileStatus.selectingAvatar, profile: state.profile));
    try {
      final candidate = await avatarSource.selectCropAndCompress();
      if (candidate == null) {
        _set(ProfileState(ProfileStatus.ready, profile: state.profile));
        return;
      }
      _retryCandidate = candidate;
      _set(ProfileState(ProfileStatus.previewing,
          profile: state.profile, candidate: candidate));
    } catch (_) {
      _set(ProfileState(ProfileStatus.failed,
          profile: state.profile, message: '无法访问相册，请在系统设置中允许照片权限'));
    }
  }

  void cancelPreview() {
    _retryCandidate = null;
    _set(ProfileState(ProfileStatus.ready, profile: state.profile));
  }

  Future<void> uploadAvatar() => _upload(_retryCandidate);
  Future<void> retryAvatar() => _upload(_retryCandidate);
  Future<void> _upload(AvatarCandidate? candidate) async {
    if (candidate == null) return;
    AvatarUploadSession? session;
    try {
      _set(ProfileState(ProfileStatus.uploading,
          profile: state.profile, candidate: candidate, progress: .2));
      session = await gateway.createAvatarUpload(
          mimeType: candidate.mimeType, byteSize: candidate.bytes.length);
      _set(ProfileState(ProfileStatus.uploading,
          profile: state.profile, candidate: candidate, progress: .55));
      await gateway.putAvatar(session, candidate);
      _set(ProfileState(ProfileStatus.uploading,
          profile: state.profile, candidate: candidate, progress: .85));
      final profile = await gateway.completeAvatar(session.uploadId);
      _retryCandidate = null;
      _set(ProfileState(ProfileStatus.ready, profile: profile, progress: 1));
    } catch (_) {
      _set(ProfileState(ProfileStatus.failed,
          profile: state.profile,
          candidate: candidate,
          progress: state.progress,
          message: '头像上传失败，请重试'));
    }
  }

  Future<void> restoreDefaultAvatar() async {
    await gateway.deleteAvatar();
    final current = state.profile;
    if (current != null) {
      _set(ProfileState(ProfileStatus.ready,
          profile: current.copyWith(clearAvatar: true)));
    }
  }

  void _set(ProfileState next) {
    state = next;
    notifyListeners();
  }
}
