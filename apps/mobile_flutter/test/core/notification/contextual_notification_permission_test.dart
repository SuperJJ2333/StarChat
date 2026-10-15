import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/notification/contextual_notification_permission.dart';
import 'package:liuhetong_mobile/core/notification/system_notification_presenter.dart';

class _Presenter extends Fake implements SystemNotificationPresenter {
  NotificationAuthorizationStatus status =
      NotificationAuthorizationStatus.undetermined;
  int requests = 0;
  bool requestError = false;
  bool grantRequest = true;
  Completer<void>? held;
  @override
  Future<NotificationAuthorizationStatus> authorizationStatus() async {
    await held?.future;
    return status;
  }

  @override
  Future<bool> requestAuthorization() async {
    requests++;
    if (requestError) throw StateError('permission service unavailable');
    status = grantRequest
        ? NotificationAuthorizationStatus.granted
        : NotificationAuthorizationStatus.denied;
    return grantRequest;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Presenter presenter;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    presenter = _Presenter();
  });
  Future<NotificationPermissionOutcome> run(
          ContextualNotificationPermission flow,
          {bool explicit = false,
          bool Function()? canPresent,
          Future<bool?> Function()? explain,
          Future<bool> Function()? settings}) =>
      flow.request(
        canPresent: canPresent ?? () => true,
        explain: explain ?? () async => true,
        openSettings: settings ?? () async => true,
        explicit: explicit,
      );

  test('deferring explanation never persists system request or denial',
      () async {
    final flow = ContextualNotificationPermission(presenter);
    expect(await run(flow, explain: () async => false),
        NotificationPermissionOutcome.deferred);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('notification.permission_prompted_v2'), isNot(true));
    expect(presenter.requests, 0);
    expect(
        await run(flow, explicit: true), NotificationPermissionOutcome.granted);
  });
  test('old prompted marker cannot seal an undetermined permission', () async {
    SharedPreferences.setMockInitialValues(
        {'notification.permission_prompted_v2': true});
    expect(await run(ContextualNotificationPermission(presenter)),
        NotificationPermissionOutcome.granted);
    expect(presenter.requests, 1);
  });
  test('interrupted foreground query does not consume the opportunity',
      () async {
    presenter.held = Completer<void>();
    var foreground = true;
    final flow = ContextualNotificationPermission(presenter);
    final pending = run(flow, canPresent: () => foreground);
    foreground = false;
    presenter.held!.complete();
    expect(await pending, NotificationPermissionOutcome.deferred);
    expect(presenter.requests, 0);
    expect(
        (await SharedPreferences.getInstance())
            .getBool('notification.permission_prompted_v2'),
        isNot(true));
  });
  test('concurrent contextual requests share one explanation and OS request',
      () async {
    final explanation = Completer<bool?>();
    var explanations = 0;
    final flow = ContextualNotificationPermission(presenter);
    final first = run(flow, explain: () {
      explanations++;
      return explanation.future;
    });
    final second = run(flow);
    await Future<void>.delayed(Duration.zero);
    explanation.complete(true);
    expect(await first, NotificationPermissionOutcome.granted);
    expect(await second, NotificationPermissionOutcome.granted);
    expect(explanations, 1);
    expect(presenter.requests, 1);
  });
  test('native request API error remains retryable and distinct from denial',
      () async {
    final flow = ContextualNotificationPermission(presenter);
    presenter.requestError = true;
    expect(await run(flow), NotificationPermissionOutcome.error);
    expect(
        (await SharedPreferences.getInstance())
            .getBool('notification.permission_prompted_v2'),
        isNot(true));
    presenter.requestError = false;
    expect(
        await run(flow, explicit: true), NotificationPermissionOutcome.granted);
  });
  test('denied permission only opens settings on explicit user action',
      () async {
    presenter.status = NotificationAuthorizationStatus.denied;
    var opens = 0;
    final flow = ContextualNotificationPermission(presenter);
    expect(
        await run(flow, settings: () async {
          opens++;
          return true;
        }),
        NotificationPermissionOutcome.settingsRequired);
    expect(opens, 0);
    expect(presenter.requests, 0);
    expect(
        await run(flow, explicit: true, settings: () async {
          opens++;
          return true;
        }),
        NotificationPermissionOutcome.settingsOpened);
    expect(opens, 1);
    expect(presenter.requests, 0);
  });

  test(
      'completed native denial records request and never automatically repeats it',
      () async {
    presenter.grantRequest = false;
    final flow = ContextualNotificationPermission(presenter);
    expect(await run(flow), NotificationPermissionOutcome.denied);
    expect(
        (await SharedPreferences.getInstance())
            .getBool(ContextualNotificationPermission.requestedKey),
        true);
    expect(await run(flow), NotificationPermissionOutcome.settingsRequired);
    expect(presenter.requests, 1);
  });

  test('unavailable status never explains or requests and can refresh later',
      () async {
    presenter.status = NotificationAuthorizationStatus.unavailable;
    final flow = ContextualNotificationPermission(presenter);
    var explanations = 0;
    expect(
        await run(flow, explain: () async {
          explanations++;
          return true;
        }),
        NotificationPermissionOutcome.error);
    expect(explanations, 0);
    expect(presenter.requests, 0);
    presenter.status = NotificationAuthorizationStatus.granted;
    expect(await run(flow), NotificationPermissionOutcome.granted);
    expect(presenter.requests, 0);
  });

  test(
      'deferring suppresses automatic re-prompt in this session but not explicit reentry',
      () async {
    final flow = ContextualNotificationPermission.forPresenter(presenter);
    expect(
        identical(
            flow, ContextualNotificationPermission.forPresenter(presenter)),
        true);
    expect(await run(flow, explain: () async => false),
        NotificationPermissionOutcome.deferred);
    expect(await run(flow), NotificationPermissionOutcome.deferred);
    expect(presenter.requests, 0);
    expect(
        await run(flow, explicit: true), NotificationPermissionOutcome.granted);
  });
}
