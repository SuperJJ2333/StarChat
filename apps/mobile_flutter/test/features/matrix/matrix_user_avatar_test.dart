import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/avatar_url_resolver.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_user_avatar.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';

final class FakeAvatarMediaCapability implements AvatarMediaCapability {
  FakeAvatarMediaCapability(this.resolve);

  final Future<ResolvedAvatarUrl?> Function(Uri? uri, double size) resolve;

  @override
  Future<ResolvedAvatarUrl?> resolveAvatar({
    required Uri? avatarUri,
    required double size,
  }) =>
      resolve(avatarUri, size);
}

void main() {
  testWidgets('hidden Matrix avatar resumes retries only when visible again',
      (tester) async {
    var calls = 0;
    final avatars = FakeAvatarMediaCapability((uri, _) async {
      if (++calls == 1) throw StateError('offline');
      return null;
    });
    Widget build(bool visible) => CupertinoApp(
        home: TickerMode(
            enabled: visible,
            child: MatrixUserAvatar(
                avatarMedia: avatars,
                nickname: 'Alice',
                fallbackSeed: 'hidden:alice',
                matrixAvatarUri: Uri.parse('mxc://matrix.test/hidden'))));
    await tester.pumpWidget(build(true));
    await tester.pumpWidget(build(false));
    await tester.pump(const Duration(seconds: 120));
    expect(calls, 1);
    await tester.pumpWidget(build(true));
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('resuming during a retry does not start a competing resolution',
      (tester) async {
    var calls = 0;
    final pending = Completer<ResolvedAvatarUrl?>();
    final avatars = FakeAvatarMediaCapability((uri, _) async {
      if (++calls == 1) throw StateError('offline');
      return pending.future;
    });
    await tester.pumpWidget(CupertinoApp(
        home: MatrixUserAvatar(
            avatarMedia: avatars,
            nickname: 'Alice',
            fallbackSeed: 'account:alice',
            matrixAvatarUri: Uri.parse('mxc://matrix.test/retry'))));
    await tester.pump(const Duration(seconds: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 10));
    final observedCalls = calls;
    pending.complete(null);
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(observedCalls, 2);
  });

  testWidgets('retry pauses in background and resumes with unchanged props',
      (tester) async {
    var calls = 0;
    final avatars = FakeAvatarMediaCapability((uri, _) async {
      if (++calls == 1) throw StateError('offline');
      return const ResolvedAvatarUrl('https://safe/resumed');
    });
    await tester.pumpWidget(CupertinoApp(
        home: MatrixUserAvatar(
            avatarMedia: avatars,
            nickname: 'Alice',
            fallbackSeed: 'account:alice',
            matrixAvatarUri: Uri.parse('mxc://matrix.test/retry'))));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 10));
    expect(calls, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(calls, 2);
    expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl,
        'https://safe/resumed');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('avatar deletion cancels retries and rejects stale resolution',
      (tester) async {
    final pending = Completer<ResolvedAvatarUrl?>();
    var calls = 0;
    final avatars = FakeAvatarMediaCapability((uri, _) async {
      calls++;
      return uri == null ? null : pending.future;
    });
    Widget build(Uri? uri) => CupertinoApp(
        home: MatrixUserAvatar(
            avatarMedia: avatars,
            nickname: 'Alice',
            fallbackSeed: 'account:alice',
            matrixAvatarUri: uri));
    await tester.pumpWidget(build(Uri.parse('mxc://matrix.test/removed')));
    await tester.pumpWidget(build(null));
    pending.complete(const ResolvedAvatarUrl('https://safe/stale'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(
        tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl, isNull);
    expect(calls, 2);
  });

  testWidgets('account capability swap cancels previous retry', (tester) async {
    var oldCalls = 0;
    final old = FakeAvatarMediaCapability((uri, _) async {
      oldCalls++;
      throw StateError('offline');
    });
    final fresh = FakeAvatarMediaCapability(
        (uri, _) async => const ResolvedAvatarUrl('https://safe/new-account'));
    Widget build(AvatarMediaCapability media) => CupertinoApp(
        home: MatrixUserAvatar(
            avatarMedia: media,
            nickname: 'Alice',
            fallbackSeed: 'alice',
            matrixAvatarUri: Uri.parse('mxc://matrix.test/shared')));
    await tester.pumpWidget(build(old));
    await tester.pumpWidget(build(fresh));
    await tester.pump(const Duration(seconds: 10));
    expect(oldCalls, 1);
    expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl,
        'https://safe/new-account');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed resolution retries and paints without changing props',
      (tester) async {
    var calls = 0;
    final avatars = FakeAvatarMediaCapability((uri, _) async {
      if (++calls == 1) throw StateError('offline');
      return const ResolvedAvatarUrl('https://safe/recovered');
    });
    await tester.pumpWidget(CupertinoApp(
        home: MatrixUserAvatar(
            avatarMedia: avatars,
            nickname: 'Alice',
            fallbackSeed: 'account:alice',
            matrixAvatarUri: Uri.parse('mxc://matrix.test/retry'))));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(calls, 2);
    expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl,
        'https://safe/recovered');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('prolonged foreground outage recovers after initial retry budget',
      (tester) async {
    var calls = 0;
    var online = false;
    final avatars = FakeAvatarMediaCapability((uri, _) async {
      calls++;
      if (!online) throw StateError('offline');
      return const ResolvedAvatarUrl('https://safe/long-recovery');
    });
    await tester.pumpWidget(CupertinoApp(
        home: MatrixUserAvatar(
            avatarMedia: avatars,
            nickname: 'Alice',
            fallbackSeed: 'account:alice',
            matrixAvatarUri: Uri.parse('mxc://matrix.test/long-retry'))));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 10));
    }
    expect(calls, lessThanOrEqualTo(7));
    online = true;
    await tester.pump(const Duration(seconds: 60));
    await tester.pump();
    expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl,
        'https://safe/long-recovery');
    await tester.pumpWidget(const SizedBox());
    final beforeDispose = calls;
    await tester.pump(const Duration(seconds: 120));
    expect(calls, beforeDispose);
  });

  testWidgets('same user retains avatar during a non-null URI refresh',
      (tester) async {
    final pending = Completer<ResolvedAvatarUrl?>();
    final avatars = FakeAvatarMediaCapability((uri, _) async =>
        uri?.path == '/old'
            ? const ResolvedAvatarUrl('https://safe/old')
            : pending.future);
    Widget build(String version) => CupertinoApp(
            home: MatrixUserAvatar(
          avatarMedia: avatars,
          nickname: '用户',
          fallbackSeed: 'account:user',
          matrixAvatarUri: Uri.parse('mxc://matrix.test/$version'),
        ));
    await tester.pumpWidget(build('old'));
    await tester.pump();
    await tester.pumpWidget(build('new'));
    expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl,
        'https://safe/old');
    pending.complete(const ResolvedAvatarUrl('https://safe/new'));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl,
        'https://safe/new');
  });
  testWidgets('reused avatar never retains another user during resolution',
      (tester) async {
    final pending = Completer<ResolvedAvatarUrl?>();
    final avatars = FakeAvatarMediaCapability((uri, _) async =>
        uri?.path == '/alice'
            ? const ResolvedAvatarUrl('https://safe/alice')
            : pending.future);
    Widget build(String user) => CupertinoApp(
            home: MatrixUserAvatar(
          avatarMedia: avatars,
          nickname: user,
          fallbackSeed: user,
          matrixAvatarUri: Uri.parse('mxc://matrix.test/$user'),
        ));
    await tester.pumpWidget(build('alice'));
    await tester.pump();
    expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl,
        'https://safe/alice');
    await tester.pumpWidget(build('bob'));
    expect(
        tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl, isNull);
    pending.complete(null);
    await tester.pump();
  });

  testWidgets('late avatar resolution cannot replace the current generation',
      (tester) async {
    final first = Completer<ResolvedAvatarUrl?>();
    final second = Completer<ResolvedAvatarUrl?>();
    var calls = 0;
    Future<ResolvedAvatarUrl?> resolve(Uri? uri, double size) =>
        ++calls == 1 ? first.future : second.future;
    final avatars = FakeAvatarMediaCapability(resolve);

    await tester.pumpWidget(CupertinoApp(
      home: MatrixUserAvatar(
        avatarMedia: avatars,
        nickname: 'Alice',
        fallbackSeed: 'alice',
        matrixAvatarUri: Uri.parse('mxc://matrix.test/old'),
      ),
    ));
    await tester.pumpWidget(CupertinoApp(
      home: MatrixUserAvatar(
        avatarMedia: avatars,
        nickname: 'Alice',
        fallbackSeed: 'alice',
        matrixAvatarUri: Uri.parse('mxc://matrix.test/new'),
      ),
    ));

    second.complete(const ResolvedAvatarUrl('https://safe/new'));
    await tester.pump();
    first.complete(const ResolvedAvatarUrl('https://safe/old'));
    await tester.pump();

    expect(tester.widget<UserAvatar>(find.byType(UserAvatar)).avatarUrl,
        'https://safe/new');
  });
}
