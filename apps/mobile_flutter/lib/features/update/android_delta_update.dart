import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../core/maintenance_activity.dart';
import 'app_update.dart';

enum DeltaUpdateOutcome {
  installerOpened,
  permissionRequired,
  cancelled,
  fallback
}

/// Paths and bytes never cross this channel. The installed certificate is the
/// trust anchor; the API supplies only the signed envelope candidate.
final class AndroidDeltaUpdater {
  static const _channel = MethodChannel('chatflow/android_delta');
  static int _cancelEpoch = 0;
  static Completer<void> _cancelSignal = Completer<void>();
  static Future<DeltaUpdateOutcome> run(AndroidDeltaEnvelope envelope) async {
    final epoch = _cancelEpoch;
    final maintenance = MaintenanceActivity.instance;
    final pressureEpoch = maintenance.pressureEpoch;
    Future<void> pause() async {
      try {
        await _channel
            .invokeMethod<void>('paused', {'value': !maintenance.canMaintain});
      } on PlatformException {
        /* teardown races are harmless */
      } on MissingPluginException {/* full APK fallback below */}
    }

    void listener() {
      if (!maintenance.isForeground ||
          maintenance.pressureEpoch != pressureEpoch) {
        unawaited(cancel());
      } else {
        unawaited(pause());
      }
    }

    MaintenanceLease? lease;
    var listening = false;
    try {
      lease = await maintenance.acquireHeavy(
        cancelled: () =>
            !maintenance.isForeground ||
            epoch != _cancelEpoch ||
            maintenance.pressureEpoch != pressureEpoch,
        cancellation: _cancelSignal.future,
      );
      if (lease == null || epoch != _cancelEpoch) {
        return DeltaUpdateOutcome.cancelled;
      }
      maintenance.addListener(listener);
      listening = true;
      await pause();
      // A MethodChannel pause acknowledgement may arrive after cancellation or
      // lifecycle/pressure changes. Never let prepare.restart erase that signal.
      if (epoch != _cancelEpoch ||
          maintenance.pressureEpoch != pressureEpoch ||
          !maintenance.isForeground) {
        return DeltaUpdateOutcome.cancelled;
      }
      final status = await _channel
          .invokeMethod<String>('prepare', {'delta': envelope.toMap()});
      if (epoch != _cancelEpoch || !maintenance.isForeground) {
        return DeltaUpdateOutcome.cancelled;
      }
      if (status == 'cancelled') return DeltaUpdateOutcome.cancelled;
      if (status != 'ready') return DeltaUpdateOutcome.fallback;
      final install = await _channel.invokeMethod<String>('install');
      return switch (install) {
        'installer_opened' => DeltaUpdateOutcome.installerOpened,
        'permission_required' => DeltaUpdateOutcome.permissionRequired,
        'cancelled' => DeltaUpdateOutcome.cancelled,
        _ => DeltaUpdateOutcome.fallback,
      };
    } on PlatformException {
      return DeltaUpdateOutcome.fallback;
    } on MissingPluginException {
      return DeltaUpdateOutcome.fallback;
    } finally {
      if (listening) maintenance.removeListener(listener);
      lease?.release();
    }
  }

  static Future<void> cancel() async {
    _cancelEpoch++;
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
    _cancelSignal = Completer<void>();
    try {
      await _channel.invokeMethod<void>('cancel');
    } on PlatformException {
      // Cancellation is best effort if an engine is being destroyed.
    } on MissingPluginException {
      // There is no Android task on other platforms.
    }
  }

  static Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod<void>('permission');
    } on PlatformException {
      // The dialog keeps the full download action available.
    } on MissingPluginException {
      // There is no Android installer on other platforms.
    }
  }
}

Future<DeltaUpdateOutcome> launchAppUpdate(
  AppUpdateInfo info, {
  bool? android,
  Future<void> Function(String) launchExternal = launchAppDownload,
  Future<DeltaUpdateOutcome> Function(AndroidDeltaEnvelope) native =
      AndroidDeltaUpdater.run,
}) async {
  final isAndroid =
      android ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);
  final envelope = info.androidDelta;
  final outcome = isAndroid && envelope != null
      ? await native(envelope)
      : DeltaUpdateOutcome.fallback;
  if (outcome == DeltaUpdateOutcome.fallback) {
    await launchExternal(info.downloadUrl);
  }
  return outcome;
}
