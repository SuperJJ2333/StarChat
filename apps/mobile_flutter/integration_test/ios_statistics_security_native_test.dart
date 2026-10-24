import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liuhetong_mobile/features/statistics/statistics_assistant_page.dart';
import 'package:liuhetong_mobile/features/statistics/statistics_state_store.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'bundled WKWebView restores hostile text without executing it and blocks external navigation',
      (tester) async {
    expect(Platform.isIOS, isTrue);
    const room = '!statistics-security:local.invalid';
    const payload = '<img src=x onerror="window.__statsAttack=1">';
    await StatisticsStateStore.write(
        room,
        jsonEncode({
          'v': 2,
          't1': {
            'lastInput': {'text': payload, 'money': '1', 'opt': 'add'}
          }
        }));
    await tester.pumpWidget(
        const CupertinoApp(home: StatisticsAssistantPage(roomId: room)));
    await tester.pump();
    final controller = WebViewController.fromPlatform(tester
        .widget<WebViewWidget>(find.byType(WebViewWidget))
        .platform
        .params
        .controller);
    bool restored = false;
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      try {
        final result = await controller.runJavaScriptReturningResult(
            'Boolean(document.getElementById("lastInput")?.textContent.includes("onerror"))');
        restored = result == true || result.toString() == 'true';
        if (restored) break;
      } catch (_) {
        // The native document may still be loading.
      }
    }
    expect(restored, isTrue,
        reason:
            'Real asset URL must pass the navigation and state injection policy');
    expect(isStatisticsAssetUrl(await controller.currentUrl() ?? ''), isTrue);
    expect(
        await controller.runJavaScriptReturningResult(
            'document.querySelectorAll("#lastInput img").length'),
        0);
    expect(
        await controller
            .runJavaScriptReturningResult('window.__statsAttack === 1'),
        false);
    await controller.runJavaScript('location.href="about:blank"');
    await tester.pump(const Duration(seconds: 1));
    expect(isStatisticsAssetUrl(await controller.currentUrl() ?? ''), isTrue);
    // Positive control: the same navigation succeeds when the policy is removed.
    // No DNS failure can masquerade as a successful block.
    await controller.setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (_) => NavigationDecision.navigate));
    await controller.runJavaScript('location.href="about:blank"');
    for (var i = 0;
        i < 40 && await controller.currentUrl() != 'about:blank';
        i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(await controller.currentUrl(), 'about:blank');
    await tester.pumpWidget(const CupertinoApp(home: SizedBox.shrink()));
    await tester.pump(const Duration(seconds: 1));
    await StatisticsStateStore.clear(room);
  });
}
