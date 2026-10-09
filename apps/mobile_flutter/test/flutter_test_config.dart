import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/maintenance_activity.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  tearDown(() => MaintenanceActivity.instance.resetForTesting());
  await testMain();
}
