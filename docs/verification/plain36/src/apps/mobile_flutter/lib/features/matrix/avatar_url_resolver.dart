import 'package:matrix/matrix.dart';

final class ResolvedAvatarUrl {
  const ResolvedAvatarUrl(this.url, {this.headers = const {}});

  final String url;
  final Map<String, String> headers;
}

abstract final class MatrixAvatarUrlResolver {
  static final Map<String, Future<ResolvedAvatarUrl?>> _resolved = {};

  /// 全应用统一的头像缩略图请求尺寸：消息页、通讯录、群成员等任何渲染
  /// 尺寸都请求同一 URL，命中同一缓存条目，杜绝同头像重复下载。
  static const canonicalThumbnailSize = 96;

  /// Builds the deterministic first request without waiting for a server
  /// capability round-trip.  A logged-in Matrix client can use the v1.11
  /// authenticated media endpoint immediately; anonymous clients use the
  /// legacy public endpoint.
  static ResolvedAvatarUrl? resolveImmediately({
    required Uri? avatarUri,
    required Uri? homeserver,
    required String? accessToken,
    required double size,
  }) {
    if (avatarUri == null) return null;
    if (avatarUri.scheme == 'http' || avatarUri.scheme == 'https') {
      return ResolvedAvatarUrl(avatarUri.toString());
    }
    if (avatarUri.scheme != 'mxc' || homeserver == null) return null;
    return _thumbnail(
      avatarUri: avatarUri,
      homeserver: homeserver,
      accessToken: accessToken,
      authenticated: accessToken?.isNotEmpty == true,
    );
  }

  static Future<ResolvedAvatarUrl?> resolveCached({
    required Uri? avatarUri,
    required Uri? homeserver,
    required String? accessToken,
    required Future<bool> Function() authenticatedMediaSupported,
    required double size,
  }) {
    if (avatarUri == null) return Future.value(null);
    final key = '${homeserver ?? ''}|$avatarUri|'
        '${accessToken == null ? 'public' : 'authenticated'}';
    return _resolved.putIfAbsent(
      key,
      () => resolve(
        avatarUri: avatarUri,
        homeserver: homeserver,
        accessToken: accessToken,
        authenticatedMediaSupported: authenticatedMediaSupported,
        size: size,
      ),
    );
  }

  static Future<ResolvedAvatarUrl?> resolveForClient({
    required Uri? avatarUri,
    required Client client,
    required double size,
  }) =>
      resolveCached(
        avatarUri: avatarUri,
        homeserver: client.homeserver,
        accessToken: client.accessToken,
        authenticatedMediaSupported: client.authenticatedMediaSupported,
        size: size,
      );

  static Future<ResolvedAvatarUrl?> resolve({
    required Uri? avatarUri,
    required Uri? homeserver,
    required String? accessToken,
    required Future<bool> Function() authenticatedMediaSupported,
    required double size,
  }) async {
    if (avatarUri == null) return null;
    if (avatarUri.scheme == 'http' || avatarUri.scheme == 'https') {
      return ResolvedAvatarUrl(avatarUri.toString());
    }
    if (avatarUri.scheme != 'mxc' || homeserver == null) return null;

    // The authenticated media endpoint requires a bearer token. Anonymous
    // clients must use the legacy public endpoint even when the homeserver
    // advertises authenticated media support.
    final authenticated =
        accessToken?.isNotEmpty == true && await authenticatedMediaSupported();
    return _thumbnail(
      avatarUri: avatarUri,
      homeserver: homeserver,
      accessToken: accessToken,
      authenticated: authenticated,
    );
  }

  static ResolvedAvatarUrl _thumbnail({
    required Uri avatarUri,
    required Uri homeserver,
    required String? accessToken,
    required bool authenticated,
  }) {
    final mediaPath = authenticated
        ? '/_matrix/client/v1/media/thumbnail'
        : '/_matrix/media/v3/thumbnail';
    final target = homeserver.replace(
      path: '$mediaPath/${avatarUri.host}${avatarUri.path}',
      queryParameters: {
        'width': canonicalThumbnailSize.toString(),
        'height': canonicalThumbnailSize.toString(),
        'method': 'crop',
        'animated': 'false',
      },
    );
    return ResolvedAvatarUrl(
      target.toString(),
      headers: authenticated && accessToken != null
          ? {'authorization': 'Bearer $accessToken'}
          : const {},
    );
  }
}
