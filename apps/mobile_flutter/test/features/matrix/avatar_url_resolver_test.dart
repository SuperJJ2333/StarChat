import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/foundation/avatar_cache.dart';
import 'package:liuhetong_mobile/features/matrix/avatar_url_resolver.dart';

void main() {
  test('unversioned disk key uses a process-stable URL digest', () {
    expect(
        AvatarCache.avatarVersion(
            'https://cdn.test/avatar.jpg?token=ephemeral'),
        '1b2fcb337f59b31e4377d1a6dceb2976ad0bd4afdebf298c9f5b5cf7ad5b7917');
  });
  test('failed cached capability resolution can succeed on retry', () async {
    var calls = 0;
    Future<ResolvedAvatarUrl?> request() =>
        MatrixAvatarUrlResolver.resolveCached(
            avatarUri: Uri.parse('mxc://media.test/failure-retry'),
            homeserver: Uri.parse('https://matrix.test'),
            accessToken: 'test-token',
            size: 40,
            authenticatedMediaSupported: () async {
              if (++calls == 1) throw StateError('offline');
              return true;
            });
    await expectLater(request(), throwsStateError);
    expect((await request())?.url, contains('/_matrix/client/v1/'));
    expect(calls, 2);
  });
  test('cached resolution uses the current session credentials', () async {
    Future<ResolvedAvatarUrl?> request(String token) =>
        MatrixAvatarUrlResolver.resolveCached(
            avatarUri: Uri.parse('mxc://media.test/rotation'),
            homeserver: Uri.parse('https://matrix.test'),
            accessToken: token,
            size: 40,
            authenticatedMediaSupported: () async => true);
    await request('old-session');
    expect((await request('new-session'))?.headers,
        {'authorization': 'Bearer new-session'});
  });

  test('keeps a normal HTTPS avatar URL and no Matrix-only headers', () async {
    final resolved = await MatrixAvatarUrlResolver.resolve(
      avatarUri: Uri.parse('https://cdn.example.test/avatar.png?v=3'),
      homeserver: Uri.parse('https://matrix.example.test'),
      accessToken: 'matrix-token',
      authenticatedMediaSupported: () async => true,
      size: 48,
    );

    expect(resolved?.url, 'https://cdn.example.test/avatar.png?v=3');
    expect(resolved?.headers, isEmpty);
  });

  test('resolves an mxc avatar into an authenticated thumbnail URL', () async {
    final resolved = await MatrixAvatarUrlResolver.resolve(
      avatarUri: Uri.parse('mxc://media.example.test/a1b2c3'),
      homeserver: Uri.parse('https://matrix.example.test'),
      accessToken: 'matrix-token',
      authenticatedMediaSupported: () async => true,
      size: 48,
    );

    expect(
      resolved?.url,
      'https://matrix.example.test/_matrix/client/v1/media/thumbnail/'
      'media.example.test/a1b2c3?width=96&height=96&method=crop&animated=false',
    );
    expect(resolved?.headers, {'authorization': 'Bearer matrix-token'});
  });

  test('builds an authenticated Matrix thumbnail synchronously for first paint',
      () {
    final resolved = MatrixAvatarUrlResolver.resolveImmediately(
      avatarUri: Uri.parse('mxc://media.example.test/a1b2c3'),
      homeserver: Uri.parse('https://matrix.example.test'),
      accessToken: 'matrix-token',
      size: 48,
    );

    expect(
      resolved?.url,
      'https://matrix.example.test/_matrix/client/v1/media/thumbnail/'
      'media.example.test/a1b2c3?width=96&height=96&method=crop&animated=false',
    );
    expect(resolved?.headers, {'authorization': 'Bearer matrix-token'});
  });

  test('resolves an mxc avatar to the unauthenticated v3 thumbnail endpoint',
      () async {
    final resolved = await MatrixAvatarUrlResolver.resolve(
      avatarUri: Uri.parse('mxc://media.example.test/a1b2c3'),
      homeserver: Uri.parse('https://matrix.example.test'),
      accessToken: null,
      authenticatedMediaSupported: () async => false,
      size: 40,
    );

    expect(
      resolved?.url,
      'https://matrix.example.test/_matrix/media/v3/thumbnail/'
      'media.example.test/a1b2c3?width=96&height=96&method=crop&animated=false',
    );
    expect(resolved?.headers, isEmpty);
  });

  test('does not select authenticated media for an anonymous client', () async {
    final resolved = await MatrixAvatarUrlResolver.resolve(
      avatarUri: Uri.parse('mxc://media.example.test/anonymous'),
      homeserver: Uri.parse('https://matrix.example.test'),
      accessToken: null,
      authenticatedMediaSupported: () async => true,
      size: 40,
    );

    expect(resolved?.url, contains('/_matrix/media/v3/thumbnail/'));
    expect(resolved?.headers, isEmpty);
  });

  test(
      'shares a cached Matrix avatar resolution when the same avatar is rebuilt',
      () async {
    var capabilityChecks = 0;
    final first = MatrixAvatarUrlResolver.resolveCached(
      avatarUri: Uri.parse('mxc://media.example.test/a1b2c3'),
      homeserver: Uri.parse('https://matrix.example.test'),
      accessToken: 'matrix-token',
      authenticatedMediaSupported: () async {
        capabilityChecks++;
        return true;
      },
      size: 48,
    );
    final second = MatrixAvatarUrlResolver.resolveCached(
      avatarUri: Uri.parse('mxc://media.example.test/a1b2c3'),
      homeserver: Uri.parse('https://matrix.example.test'),
      accessToken: 'matrix-token',
      authenticatedMediaSupported: () async {
        capabilityChecks++;
        return true;
      },
      size: 48,
    );

    expect((await first)?.url, (await second)?.url);
    expect((await first)?.headers, (await second)?.headers);
    expect(capabilityChecks, 1);
  });

  test('message list and contacts request the same canonical thumbnail',
      () async {
    // 头像一致性：渲染尺寸不同（48/40）也必须命中同一缩略图 URL，
    // 保证同头像只下载一次、两页展示时延一致。
    final conversation = await MatrixAvatarUrlResolver.resolve(
      avatarUri: Uri.parse('mxc://media.example.test/a1b2c3'),
      homeserver: Uri.parse('https://matrix.example.test'),
      accessToken: 'matrix-token',
      authenticatedMediaSupported: () async => true,
      size: MatrixAvatarUrlResolver.canonicalThumbnailSize.toDouble(),
    );
    final contacts = await MatrixAvatarUrlResolver.resolve(
      avatarUri: Uri.parse('mxc://media.example.test/a1b2c3'),
      homeserver: Uri.parse('https://matrix.example.test'),
      accessToken: 'matrix-token',
      authenticatedMediaSupported: () async => true,
      size: 40,
    );

    expect(contacts?.url, conversation?.url);
    expect(contacts?.url, contains('width=96'));
  });
}
