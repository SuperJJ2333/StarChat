import 'package:shared_preferences/shared_preferences.dart';
import 'system_notification_presenter.dart';

enum NotificationPermissionOutcome {
  deferred,
  granted,
  denied,
  error,
  settingsRequired,
  settingsOpened
}

/// Extracted notification introduction policy; the UI owns its explanation.
final class ContextualNotificationPermission {
  ContextualNotificationPermission(this.presenter);
  final SystemNotificationPresenter presenter;
  static final _flows = Expando<ContextualNotificationPermission>();
  static ContextualNotificationPermission forPresenter(
          SystemNotificationPresenter presenter) =>
      _flows[presenter] ??= ContextualNotificationPermission(presenter);
  static const requestedKey = 'notification.permission_requested_v3';
  Future<NotificationPermissionOutcome>? _pending;
  bool _deferredThisSession = false;

  Future<NotificationPermissionOutcome> request({
    required bool Function() canPresent,
    required Future<bool?> Function() explain,
    required Future<bool> Function() openSettings,
    bool explicit = false,
  }) {
    return _pending ??= _request(
            canPresent: canPresent,
            explain: explain,
            openSettings: openSettings,
            explicit: explicit)
        .whenComplete(() => _pending = null);
  }

  Future<NotificationPermissionOutcome> _request({
    required bool Function() canPresent,
    required Future<bool?> Function() explain,
    required Future<bool> Function() openSettings,
    required bool explicit,
  }) async {
    try {
      if (!canPresent()) return NotificationPermissionOutcome.deferred;
      final prefs = await SharedPreferences.getInstance();
      final permission = await readNotificationPermissionState(presenter);
      if (!canPresent()) return NotificationPermissionOutcome.deferred;
      final status = permission.status;
      if (permission.authorized &&
          (!explicit || status == NotificationAuthorizationStatus.granted)) {
        return NotificationPermissionOutcome.granted;
      }
      if (status == NotificationAuthorizationStatus.unavailable) {
        return NotificationPermissionOutcome.error;
      }
      if (status == NotificationAuthorizationStatus.denied ||
          (status == NotificationAuthorizationStatus.undetermined &&
              prefs.getBool(requestedKey) == true)) {
        if (!explicit) return NotificationPermissionOutcome.settingsRequired;
        return await openSettings()
            ? NotificationPermissionOutcome.settingsOpened
            : NotificationPermissionOutcome.error;
      }
      if (_deferredThisSession && !explicit) {
        return NotificationPermissionOutcome.deferred;
      }
      if (await explain() != true) {
        _deferredThisSession = true;
        return NotificationPermissionOutcome.deferred;
      }
      if (!canPresent()) return NotificationPermissionOutcome.deferred;
      final granted = await presenter.requestAuthorization();
      // Persist only a completed native request, never an explanation or API error.
      await prefs.setBool(requestedKey, true);
      await prefs.setBool('notification.permission_prompted_v2', true);
      return granted
          ? NotificationPermissionOutcome.granted
          : NotificationPermissionOutcome.denied;
    } catch (_) {
      return NotificationPermissionOutcome.error;
    }
  }
}
