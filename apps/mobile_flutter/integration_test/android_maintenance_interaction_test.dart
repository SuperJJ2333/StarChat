import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test/features/matrix/room_history_interaction_test.dart'
    as room_interactions;
import '../test/features/matrix/nonblocking_legacy_timeline_test.dart'
    as legacy_authority;
import '../test/ui/composer_input_isolation_test.dart' as composer_isolation;

/// Runs existing actual RoomPage/controller/storage interactions on Android.
/// All rooms, events and HTTP responses are synthetic. This is debug functional
/// evidence, not a release/profile frame-rate acceptance test or a real account.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  room_interactions.historyInteractionDatabaseFactory =
      createDatabaseFactoryFfi(
    ffiInit: SQfLiteEncryptionHelper.ffiInit,
  );
  room_interactions.runNativeHistoryKeyboardInteractions = true;
  legacy_authority.nativeLegacyArtifactRoot = Directory(
      '${Directory.systemTemp.path}/docs/verification/artifacts/2026-10-09/mobile-responsive-maintenance/history');
  final buildUs = <int>[];
  final rasterUs = <int>[];
  void timings(List<FrameTiming> values) {
    for (final value in values) {
      if (buildUs.length >= 10000) break;
      buildUs.add(value.buildDuration.inMicroseconds);
      rasterUs.add(value.rasterDuration.inMicroseconds);
    }
  }

  setUpAll(() {
    expect(Platform.isAndroid, isTrue);
    SchedulerBinding.instance.addTimingsCallback(timings);
  });
  tearDownAll(() {
    SchedulerBinding.instance.removeTimingsCallback(timings);
    Map<String, int> distribution(List<int> samples) {
      samples.sort();
      if (samples.isEmpty) return {'samples': 0};
      return {
        'samples': samples.length,
        'p50_us': samples[(samples.length * .50).floor()],
        'p95_us': samples[
            (samples.length * .95).floor().clamp(0, samples.length - 1)],
        'max_us': samples.last,
      };
    }

    final result = <String, Object>{
      'scope': 'synthetic_actual_RoomPage_debug_android',
      'real_account_network': false,
      'release_performance_acceptance': false,
      'build': distribution(buildUs),
      'raster': distribution(rasterUs),
      'rss_bytes': ProcessInfo.currentRss,
      'max_rss_bytes': ProcessInfo.maxRss,
    };
    binding.reportData = result;
    // Synthetic counts/timings only; never logs room/event IDs or message text.
    // ignore: avoid_print
    print('ANDROID_MAINTENANCE_METRICS ${jsonEncode(result)}');
  });

  group('actual RoomPage native interactions', room_interactions.main);
  group('composer isolation', composer_isolation.main);
  group('native legacy authority', legacy_authority.main);
}
