import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:liuhetong_mobile/core/maintenance_activity.dart';
import 'package:liuhetong_mobile/features/emoji/emoji_resource_manifest.dart';
import 'package:liuhetong_mobile/features/emoji/emoji_resource_store.dart';
import 'package:liuhetong_mobile/features/emoji/fluent_vector_emoji_catalog.dart';
import 'package:liuhetong_mobile/features/emoji/static_emoji_recent_store.dart';
import 'package:liuhetong_mobile/ui/chat/emoji_resource_glyph.dart';
import 'package:liuhetong_mobile/ui/chat/shared_emoji_player.dart';
import 'package:liuhetong_mobile/ui/chat/shared_emoji_image.dart';
import 'package:liuhetong_mobile/ui/chat/chat_emoji_panel.dart';

// Native synthetic data only. Uses the same verified resources/player as chat,
// without reading user rooms or sending messages. Debug emulator timings are
// recorded as diagnostics, not phone/profile frame-rate acceptance.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const source = '/data/local/tmp/chatflow-visible-emoji-2210';
  final report = <String, Object>{
    'scope': 'native_real_webp_direct_send_warm_resume_debug',
    'real_account_network': false,
    'release_performance_acceptance': false,
  };
  late EmojiResourceStore store;
  late SharedEmojiPlayerPool pool;
  late Directory cache;
  final buildUs = <int>[];
  final rasterUs = <int>[];
  void timings(List<FrameTiming> values) {
    for (final frame in values) {
      if (buildUs.length >= 10000) break;
      buildUs.add(frame.buildDuration.inMicroseconds);
      rasterUs.add(frame.rasterDuration.inMicroseconds);
    }
  }

  Future<void> waitFor(WidgetTester tester, bool Function() ready,
      {int seconds = 20}) async {
    final until = DateTime.now().add(Duration(seconds: seconds));
    while (!ready() && DateTime.now().isBefore(until)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(ready(), isTrue, reason: 'native playback/IME condition timed out');
  }

  Future<void> playFor(WidgetTester tester, int milliseconds) async {
    final until = DateTime.now().add(Duration(milliseconds: milliseconds));
    while (DateTime.now().isBefore(until)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
  }

  int count(String key) => pool.diagnostics[key] as int;
  Widget scene({int messages = 2000}) {
    const names = [
      'grinning',
      'smile',
      'joy',
      'halo',
      'heart-eyes',
      'hearts-face',
      'kiss',
      'wink',
      'zany',
      'savoring',
      'holding-back-tears',
      'sob',
      'cry',
      'angry',
      'smiling-angry',
      'thinking',
    ];
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Synthetic animation verification')),
        body: Column(children: [
          Expanded(
            child: GridView.builder(
              key: const Key('emoji-grid'),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 10, mainAxisExtent: 36),
              itemCount: messages,
              itemBuilder: (_, index) => Center(
                child: EmojiResourceGlyph(
                  key: ValueKey('emoji-$index'),
                  asset: 'assets/emoji/${names[index % names.length]}.webp',
                  size: 32,
                  store: store,
                  pool: pool,
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(8),
            child: TextField(key: Key('synthetic-input')),
          ),
        ]),
      ),
    );
  }

  setUpAll(() async {
    expect(Platform.isAndroid, isTrue);
    SchedulerBinding.instance.addTimingsCallback(timings);
    final manifest = EmojiResourceManifest.parse(emojiManifestJson,
        expectedDigest: emojiManifestDigest);
    cache = await Directory.systemTemp.createTemp('visible-emoji-native-');
    store = EmojiResourceStore(directory: cache, manifest: manifest);
    for (final entry in manifest.entries.values) {
      final accepted = await store.accept(
          entry.id, File('$source/${entry.path}').openRead());
      expect(accepted, isNotNull,
          reason: 'real fixture must pass SHA/size/WebP validation');
    }
    report['verifiedResources'] = manifest.entries.length;
    report['manifestSha256'] = emojiManifestDigest;
    // The synthetic audit package has its own files directory. Seed the real
    // runtime path as well, so a fresh default store exercises production init.
    final support = await getApplicationSupportDirectory();
    final runtimeFixtures = EmojiResourceStore(
        directory: Directory('${support.path}/emoji-resources'),
        manifest: manifest);
    for (final entry in manifest.entries.values) {
      expect(
          await runtimeFixtures.accept(
              entry.id, File('$source/${entry.path}').openRead()),
          isNotNull);
    }
    runtimeFixtures.dispose();
  });
  setUp(() => pool = SharedEmojiPlayerPool());
  tearDown(() async {
    MaintenanceActivity.instance.setInteractive('native-emoji-input', false);
    pool.dispose();
  });
  tearDownAll(() async {
    SchedulerBinding.instance.removeTimingsCallback(timings);
    store.dispose();
    await cache.delete(recursive: true);
    Map<String, int> distribution(List<int> values) {
      values.sort();
      if (values.isEmpty) return {'samples': 0};
      return {
        'samples': values.length,
        'p50_us': values[(values.length * .50).floor()],
        'p95_us': values[(values.length * .95).floor()],
        'p99_us': values[(values.length * .99).floor()],
        'max_us': values.last,
      };
    }

    report['build'] = distribution(buildUs);
    report['raster'] = distribution(rasterUs);
    binding.reportData = report;
    debugPrint('VISIBLE_EMOJI_NATIVE_REPORT ${jsonEncode(report)}');
  });

  testWidgets('all visible real WebP play and repeated emoji share decoding',
      (tester) async {
    await tester.pumpWidget(scene());
    await waitFor(
        tester,
        () =>
            count('activeEntries') >= 16 &&
            count('framesEmitted') > 48 &&
            count('subscribers') > 80);
    final before = count('framesEmitted');
    final beforeEach =
        Map<String, int>.from(pool.diagnostics['activeFrameCounts']! as Map);
    MaintenanceActivity.instance.setInteractive('native-emoji-input', true);
    await playFor(tester, 1000);
    final afterEach =
        Map<String, int>.from(pool.diagnostics['activeFrameCounts']! as Map);
    for (final entry in beforeEach.entries) {
      expect(afterEach[entry.key], greaterThan(entry.value),
          reason:
              'every visible unique emoji must advance, not just aggregate');
    }
    expect(count('framesEmitted'), greaterThan(before + 30));
    expect(count('activeEntries'), greaterThan(4));
    expect(count('peakInFlight'), lessThanOrEqualTo(2));
    expect(count('codecCreates'), lessThanOrEqualTo(16));
    expect(count('decodedImageBytes'), 16 * 96 * 96 * 4,
        reason:
            'actual output frames must be resized, not just requested size');
    report['visiblePlayback'] = Map<String, Object>.from(pool.diagnostics);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await waitFor(tester, () => count('activeEntries') == 0);
  });

  testWidgets('scroll and real keyboard keep visible emoji playing',
      (tester) async {
    await tester.pumpWidget(scene());
    await waitFor(tester, () => count('framesEmitted') > 32);
    for (var index = 0; index < 12; index++) {
      final before = count('framesEmitted');
      await tester.fling(find.byKey(const Key('emoji-grid')),
          Offset(0, index.isEven ? -450 : 450), 2400);
      await playFor(tester, 200);
      expect(count('framesEmitted'), greaterThan(before));
      expect(tester.takeException(), isNull);
    }
    expect(tester.binding.testTextInput.isRegistered, isFalse);
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    Future<void> waitIme(bool shown) => waitFor(
        tester,
        () =>
            (ui.PlatformDispatcher.instance.views.single.viewInsets.bottom >
                0) ==
            shown);
    for (var cycle = 0; cycle < 10; cycle++) {
      final before = count('framesEmitted');
      await tester.tap(find.byKey(const Key('synthetic-input')));
      editable.requestKeyboard();
      // Focus/client binding is frame scheduled. A show call before that
      // connection reaches Android can be ignored by the real input method.
      await tester.pump();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      debugPrint(
          'EMOJI_NATIVE_IME cycle=$cycle focus=${editable.widget.focusNode.hasFocus}');
      await waitIme(true);
      MaintenanceActivity.instance.setInteractive('native-emoji-input', true);
      await playFor(tester, 200);
      expect(count('activeEntries'), greaterThan(4));
      expect(count('framesEmitted'), greaterThan(before));
      FocusManager.instance.primaryFocus?.unfocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      await waitIme(false);
      MaintenanceActivity.instance.setInteractive('native-emoji-input', false);
    }
    report['interactionPlayback'] = Map<String, Object>.from(pool.diagnostics);
    report['nativeKeyboardShowHideCycles'] = 10;
    report['fastFlings'] = 12;
    await tester.pumpWidget(const SizedBox.shrink());
    await waitFor(tester, () => count('activeEntries') == 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'default static panel restores sixteen recent emoji without animating',
      (tester) async {
    final recents =
        StaticEmojiRecentStore(accountId: 'native-synthetic-recents');
    for (final emoji in vectorEmojis.take(16)) {
      await recents.record(emoji.char);
    }
    final expected = vectorEmojis.take(16).toList().reversed.toList();
    Widget panel() => MaterialApp(
        home: Scaffold(
            body: SizedBox(
                height: 320,
                child: ChatEmojiPanel(
                    accountId: recents.accountId,
                    onEmojiSelected: (_) {},
                    onDynamicEmojiSelected: (_) {},
                    playbackPool: pool,
                    customItems: const [],
                    onCustomSelected: (_) {}))));
    for (var cycle = 0; cycle < 3; cycle++) {
      await tester.pumpWidget(panel());
      await waitFor(
          tester,
          () => find
              .byKey(const Key('recent-static-emoji-grid'))
              .evaluate()
              .isNotEmpty);
      final points = [
        for (final emoji in expected)
          tester
              .getCenter(find.byKey(Key('recent-static-emoji-${emoji.name}'))),
      ];
      expect(points.take(8).map((point) => point.dy).toSet(), hasLength(1));
      expect(points.skip(8).map((point) => point.dy).toSet(), hasLength(1));
      expect(points[8].dy, greaterThan(points[0].dy));
      expect(count('activeEntries'), 0);
      expect(count('framesEmitted'), 0);
      expect(find.byType(SvgPicture), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    }
    report['defaultStaticRecentRows'] = 2;
    report['defaultStaticRecentCount'] = 16;
    report['defaultStaticAnimationEntries'] = count('activeEntries');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'actual panel cold open and repeated warm reopen avoid static flash',
      (tester) async {
    final dynamicSelections = <String>[];
    final plainSelections = <String>[];
    Widget panel() => MaterialApp(
        home: Scaffold(
            body: Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                    height: 320,
                    child: ChatEmojiPanel(
                        initialTab: ChatEmojiTab.superEmoji,
                        onEmojiSelected: plainSelections.add,
                        onDynamicEmojiSelected: dynamicSelections.add,
                        resourceStore: store,
                        playbackPool: pool,
                        customItems: const [],
                        onCustomSelected: (_) {})))));
    await tester.pumpWidget(panel());
    await tester.pump();
    expect(find.byType(SvgPicture), findsNothing,
        reason: 'downloaded dynamic resources must not flash unrelated SVG');
    await waitFor(tester,
        () => count('activeEntries') > 4 && count('framesEmitted') > 30);
    await playFor(tester, 300);
    await tester.tap(find.byKey(const Key('fluent-emoji-grinning')));
    await tester.pump();
    expect(dynamicSelections, ['😄']);
    expect(plainSelections, isEmpty);
    report['panelColdPlayback'] = Map<String, Object>.from(pool.diagnostics);
    for (var cycle = 0; cycle < 10; cycle++) {
      await tester.pumpWidget(const SizedBox.shrink());
      await waitFor(
          tester, () => count('activeEntries') == 0 && count('inFlight') == 0);
      final paused = count('framesEmitted');
      await playFor(tester, 150);
      expect(count('framesEmitted'), paused,
          reason: 'closed panel must not tick hidden animation');
      await tester.pumpWidget(panel());
      await tester.pump();
      expect(find.byType(SvgPicture), findsNothing);
      final renderers =
          tester.widgetList<SharedEmojiImage>(find.byType(SharedEmojiImage));
      expect(renderers, isNotEmpty,
          reason: 'verified files are available on warm first build');
      final paints = tester.widgetList<CustomPaint>(find.descendant(
          of: find.byType(SharedEmojiImage),
          matching: find.byType(CustomPaint)));
      final ready = paints.where((p) =>
          p.painter != null && (p.painter as dynamic).playback.frame != null);
      expect(ready.length, renderers.length,
          reason: 'all current-panel warm first paints use retained frames');
      await waitFor(tester,
          () => count('activeEntries') > 4 && count('framesEmitted') > paused);
    }
    report['panelReopenCycles'] = 10;
    report['panelWarmPlayback'] = Map<String, Object>.from(pool.diagnostics);
    await tester.pumpWidget(const SizedBox.shrink());
    await waitFor(
        tester, () => count('activeEntries') == 0 && count('inFlight') == 0);
    report['panelIdle'] = Map<String, Object>.from(pool.diagnostics);
    expect(count('idleFrameBytes'), lessThanOrEqualTo(4 * 1024 * 1024));
    expect(count('idleEntries'), lessThanOrEqualTo(64));
    expect(count('idleCodecCount'), lessThanOrEqualTo(8));
    expect(tester.takeException(), isNull);
  });

  testWidgets('fresh default runtime panel avoids SVG before async store init',
      (tester) async {
    final stopwatch = Stopwatch()..start();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                height: 320,
                child: ChatEmojiPanel(
                    initialTab: ChatEmojiTab.superEmoji,
                    onEmojiSelected: (_) {},
                    onDynamicEmojiSelected: (_) {},
                    playbackPool: pool,
                    customItems: const [],
                    onCustomSelected: (_) {})))));
    expect(find.byType(SvgPicture), findsNothing,
        reason: 'unknown production runtime store must not flash SVG');
    await waitFor(tester, () => count('framesEmitted') > 0);
    report['defaultRuntimeFirstFrameMs'] = stopwatch.elapsedMilliseconds;
    await waitFor(tester,
        () => count('activeEntries') > 4 && count('framesEmitted') > 30);
    stopwatch.stop();
    expect(find.byType(SvgPicture), findsNothing);
    report['defaultRuntimePlaybackReadyMs'] = stopwatch.elapsedMilliseconds;
    report['defaultRuntimePlayback'] =
        Map<String, Object>.from(pool.diagnostics);
    await tester.pumpWidget(const SizedBox.shrink());
    await waitFor(tester, () => count('activeEntries') == 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden route and background stop; visible route resumes',
      (tester) async {
    await tester.pumpWidget(scene());
    await waitFor(tester, () => count('framesEmitted') > 32);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(
            body: Center(child: Text('Synthetic second room')))));
    await playFor(tester, 600);
    await waitFor(tester, () => count('activeEntries') == 0);
    debugPrint('VISIBLE_EMOJI_STAGE hidden route released');
    final stopped = count('framesEmitted');
    await playFor(tester, 250);
    expect(count('framesEmitted'), stopped);
    navigator.pop();
    await playFor(tester, 600);
    await waitFor(tester,
        () => count('activeEntries') > 4 && count('framesEmitted') > stopped);
    debugPrint('VISIBLE_EMOJI_STAGE returned route resumed');
    binding.handleAppLifecycleStateChanged(ui.AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(ui.AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(ui.AppLifecycleState.paused);
    // Paused engines supply no vsync. Background teardown must not await a pump.
    expect(count('activeEntries'), 0);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)));
    debugPrint('VISIBLE_EMOJI_STAGE paused lifecycle released');
    binding.handleAppLifecycleStateChanged(ui.AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(ui.AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(ui.AppLifecycleState.resumed);
    await tester.pump();
    await waitFor(tester, () => count('activeEntries') > 4);
    binding.handleMemoryPressure();
    await playFor(tester, 250);
    report['lifecyclePlayback'] = Map<String, Object>.from(pool.diagnostics);
    await tester.pumpWidget(const SizedBox.shrink());
    await waitFor(
        tester, () => count('activeEntries') == 0 && count('inFlight') == 0);
    report['afterExit'] = Map<String, Object>.from(pool.diagnostics);
    pool.dispose();
    await waitFor(tester, () => count('inFlight') == 0);
    report['afterDispose'] = Map<String, Object>.from(pool.diagnostics);
    expect(count('totalFrameBytes'), 0);
    expect(count('idleCodecCount'), 0);
    expect(tester.takeException(), isNull);
  });
}
