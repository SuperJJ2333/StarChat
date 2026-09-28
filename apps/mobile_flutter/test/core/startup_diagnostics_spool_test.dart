import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/startup_diagnostics_spool.dart';

Map<String, Object> report({int index = 1, DateTime? at}) => {
      'schema': 1,
      'platform': 'ios',
      'event_id':
          '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
      'app_version': '0.4.15',
      'build': 2184,
      'os_version': '18.1',
      'occurred_at': (at ?? DateTime.utc(2026, 9, 27, 7))
          .toIso8601String()
          .replaceFirst('.000Z', 'Z'),
      'stage': 'initialization',
      'boundary': 'version_load',
      'category': 'unknown',
      'count': 1,
    };

Future<Directory> testDirectory(String prefix) async {
  final root = Directory(
          '../../docs/verification/artifacts/2026-09-27/ios-startup-alerts/mobile-recorder/test-files')
      .absolute;
  await root.create(recursive: true);
  return root.createTemp(prefix);
}

void main() {
  final now = DateTime.utc(2026, 9, 27, 7);
  test('uncertain IO faults propagate instead of claiming an empty queue',
      () async {
    final directory = await testDirectory('startup-read-fault-');
    addTearDown(() => directory.delete(recursive: true));
    var inaccessible = false;
    final spool = FileStartupDiagnosticsSpool(
        directoryProvider: () async {
          if (inaccessible) throw const FileSystemException('inaccessible');
          return directory;
        },
        clock: () => now);
    await spool.write([report()]);
    inaccessible = true;
    await expectLater(spool.read(), throwsA(isA<FileSystemException>()));
    await expectLater(spool.write([]), throwsA(isA<FileSystemException>()));
    inaccessible = false;
    expect(await spool.read(), [report()]);
  });
  test('queue decoder rejects corrupt foreign fields old and oversized data',
      () {
    expect(decodeStartupDiagnosticsQueue('{', now: now), isEmpty);
    expect(
        decodeStartupDiagnosticsQueue(
            jsonEncode([report()..['token'] = 'private']),
            now: now),
        isEmpty);
    expect(
        decodeStartupDiagnosticsQueue(
            jsonEncode([report(at: now.subtract(const Duration(hours: 25)))]),
            now: now),
        isEmpty);
    expect(decodeStartupDiagnosticsQueue(' ' * 32769, now: now), isEmpty);
    expect(
        decodeStartupDiagnosticsQueue(
            jsonEncode([for (var i = 1; i <= 21; i++) report(index: i)]),
            now: now),
        hasLength(20));
    expect(
        decodeStartupDiagnosticsQueue(jsonEncode([report()..['count'] = true]),
            now: now),
        isEmpty);
  });
  test('fixed file spool validates data and refuses non-files and symlinks',
      () async {
    final directory = await testDirectory('startup-diagnostics-test-');
    addTearDown(() => directory.delete(recursive: true));
    final spool = FileStartupDiagnosticsSpool(
        directoryProvider: () async => directory, clock: () => now);
    await spool.write([report()]);
    expect(await spool.read(), [report()]);
    final file =
        File('${directory.path}/${FileStartupDiagnosticsSpool.fileName}');
    await file
        .writeAsString(jsonEncode([report()..['account_id'] = 'private']));
    expect(await spool.read(), isEmpty);
    await file.delete();
    await Directory(file.path).create();
    await spool.write([report()]);
    expect(await spool.read(), isEmpty);
    expect(await Directory(file.path).exists(), isTrue);
  });
  test('spool never reads or overwrites a symlink target', () async {
    final directory = await testDirectory('startup-diagnostics-link-');
    addTearDown(() => directory.delete(recursive: true));
    final target = File('${directory.path}/private-target.json');
    await target.writeAsString(jsonEncode([report()]));
    final link =
        Link('${directory.path}/${FileStartupDiagnosticsSpool.fileName}');
    await link.create(target.path);
    final spool = FileStartupDiagnosticsSpool(
        directoryProvider: () async => directory, clock: () => now);
    expect(await spool.read(), isEmpty);
    await spool.write([report(index: 2)]);
    expect(jsonDecode(await target.readAsString()), [report()]);
    expect(await FileSystemEntity.type(link.path, followLinks: false),
        FileSystemEntityType.link);
  });
  test(
      'trusted support path creates missing directory and canonicalizes ancestor alias',
      () async {
    final directory = await testDirectory('startup-support-path-');
    addTearDown(() => directory.delete(recursive: true));
    final real = Directory('${directory.path}/real');
    await real.create();
    final child = Directory('${real.path}/support');
    final spool = FileStartupDiagnosticsSpool(
        directoryProvider: () => Future.value(child), clock: () => now);
    await spool.write([report()]);
    expect(await spool.read(), [report()]);
    final alias = Link('${directory.path}/alias');
    await alias.create(real.path);
    final aliasSpool = FileStartupDiagnosticsSpool(
        directoryProvider: () =>
            Future.value(Directory('${alias.path}/support')),
        clock: () => now);
    expect(await aliasSpool.read(), [report()]);
    await aliasSpool.write([report(index: 2)]);
    expect(await spool.read(), [report(index: 2)]);
  });
  test('atomic spool write refuses a linked staging file', () async {
    final directory = await testDirectory('startup-spool-staging-');
    addTearDown(() => directory.delete(recursive: true));
    final spool = FileStartupDiagnosticsSpool(
        directoryProvider: () => Future.value(directory), clock: () => now);
    await spool.write([report()]);
    final target = File('${directory.path}/unrelated.json');
    await target.writeAsString('private');
    final staging =
        Link('${directory.path}/${FileStartupDiagnosticsSpool.fileName}.tmp');
    await staging.create(target.path);
    await spool.write([report(index: 2)]);
    expect(await target.readAsString(), 'private');
    expect(await spool.read(), [report()]);
  });
  test(
      'strict report allows only documented enums precision and optional fields',
      () {
    expect(
        validateStartupDiagnosticsReport(
            report()..['app_version'] = '9999.9999.9999',
            now: now),
        isNotNull);
    expect(
        validateStartupDiagnosticsReport(
            report()..['app_version'] = '99999.1.1',
            now: now),
        isNull);
    expect(
        validateStartupDiagnosticsReport(report()..['os_version'] = '1000',
            now: now),
        isNull);
    expect(
        validateStartupDiagnosticsReport(
            report()..['occurred_at'] = '2026-09-27T07:00:01Z',
            now: now),
        isNull);
    expect(
        validateStartupDiagnosticsReport(
            report()..['occurred_at'] = '2026-02-31T07:00:00Z',
            now: now),
        isNull);
    expect(
        validateStartupDiagnosticsReport(
            report()..['occurred_at'] = '2026-09-27T07:06:00Z',
            now: now),
        isNull);
    expect(
        validateStartupDiagnosticsReport(
            report()..['preflight_cause'] = 'secret',
            now: now),
        isNull);
    expect(
        validateStartupDiagnosticsReport(report()..['native_status'] = -12345,
            now: now),
        isNull);
    expect(
        validateStartupDiagnosticsReport(report()..['login_stage'] = 'L09',
            now: now),
        isNull);
    expect(
        validateStartupDiagnosticsReport(report()..['login_stage'] = 'L04',
            now: now),
        isNotNull);
    expect(
        validateStartupDiagnosticsReport(report()..['count'] = 101, now: now),
        isNull);
    expect(
        validateStartupDiagnosticsReport(report()..['build'] = 1.0, now: now),
        isNull);
  });
}
