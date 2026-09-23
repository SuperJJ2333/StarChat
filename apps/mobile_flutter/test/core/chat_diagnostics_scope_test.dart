import 'dart:ui';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics.dart';
import 'package:liuhetong_mobile/core/chat_diagnostics_scope.dart';

void main() {
  testWidgets(
      'foreground display budget counts build and raster, not total span',
      (tester) async {
    var now = DateTime(2026);
    final diagnostics = ChatDiagnostics(now: () => now);
    final batches = <ChatDiagnosticBatch>[];
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(ChatDiagnosticsScope(
      sessionEpoch: 1,
      version: '1.2.3',
      platform: ChatDiagnosticPlatform.android,
      diagnostics: diagnostics,
      upload: (batch, _) async {
        batches.add(batch);
        return 202;
      },
      child: const SizedBox(),
    ));
    FrameTiming frame(int build, int raster) => FrameTiming(
          vsyncStart: 0,
          buildStart: 1000,
          buildFinish: 1000 + build,
          rasterStart: 100000,
          rasterFinish: 100000 + raster,
          rasterFinishWallTime: 100000 + raster,
        );
    tester.binding.platformDispatcher.onReportTimings!([
      frame(9000, 1000),
      frame(1000, 9000),
      frame(1000, 1000),
    ]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.platformDispatcher.onReportTimings!([frame(20000, 20000)]);
    now = now.add(const Duration(minutes: 1));
    await diagnostics.flush();
    expect(batches.single.toJson()['frames'], {
      'frame_count': 3,
      'slow_frame_count': 2,
      'slow_build_count': 1,
      'slow_raster_count': 1,
    });
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('scope clears diagnostics across account switch and disposal',
      (tester) async {
    final diagnostics = ChatDiagnostics();
    Widget scope(int epoch) => ChatDiagnosticsScope(
          diagnostics: diagnostics,
          sessionEpoch: epoch,
          version: '0.3.103+2152',
          platform: ChatDiagnosticPlatform.android,
          upload: (batch, abort) async => 202,
          child: const SizedBox(),
        );
    await tester.pumpWidget(scope(1));
    diagnostics.record(
        stage: ChatDiagnosticStage.matrixSend,
        error: ChatDiagnosticError.timeout);
    expect(diagnostics.pendingCount, 1);
    await tester.pumpWidget(scope(2));
    expect(diagnostics.pendingCount, 0);
    diagnostics.record(
        stage: ChatDiagnosticStage.framework,
        error: ChatDiagnosticError.unknown);
    await tester.pumpWidget(const SizedBox());
    expect(diagnostics.pendingCount, 0);
    diagnostics.record(
        stage: ChatDiagnosticStage.framework,
        error: ChatDiagnosticError.unknown);
    expect(diagnostics.pendingCount, 0);
  });
}
