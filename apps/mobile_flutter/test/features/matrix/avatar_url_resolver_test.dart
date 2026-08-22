import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/avatar_url_resolver.dart';

void main() {
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
      'media.example.test/a1b2c3?width=48&height=48&method=crop&animated=false',
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
      'media.example.test/a1b2c3?width=48&height=48&method=crop&animated=false',
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
      'media.example.test/a1b2c3?width=40&height=40&method=crop&animated=false',
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

    expect(await first, await second);
    expect(capabilityChecks, 1);
  });
}
