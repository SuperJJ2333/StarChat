import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'session_failure.dart';
import 'startup_failure_metadata.dart';

abstract interface class StartupDiagnosticsSpool {
  Future<List<Map<String, Object>>> read();
  Future<void> write(List<Map<String, Object>> reports);
}

const startupDiagnosticsMaxEvents = 20;
const startupDiagnosticsMaxBytes = 32768;
const startupDiagnosticsMaxAge = Duration(hours: 24);
final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
final _version = RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}$');
final _osVersion = RegExp(r'^\d{1,3}(?:\.\d{1,3}){0,2}$');
final _minute = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00Z$');

bool isStartupDiagnosticsUuid(Object? value) =>
    value is String && _uuid.hasMatch(value);
String safeStartupDiagnosticsOsVersion(String value) =>
    _osVersion.hasMatch(value) ? value : 'unknown';
bool isStartupDiagnosticsAppVersion(String value) => _version.hasMatch(value);

/// Every value loaded from disk is untrusted. Reconstruct only the closed wire
/// schema; no old envelope, arbitrary field or raw text can reach the uploader.
Map<String, Object>? validateStartupDiagnosticsReport(Object? raw,
    {required DateTime now}) {
  if (raw is! Map ||
      raw.keys.any((key) => !const {
            'schema',
            'platform',
            'event_id',
            'app_version',
            'build',
            'os_version',
            'occurred_at',
            'stage',
            'boundary',
            'category',
            'preflight_cause',
            'native_status',
            'login_stage',
            'count',
          }.contains(key))) {
    return null;
  }
  final build = raw['build'];
  final count = raw['count'];
  final version = raw['app_version'];
  final os = raw['os_version'];
  final occurred = raw['occurred_at'];
  if (raw['schema'] is! int ||
      raw['schema'] != 1 ||
      raw['platform'] != 'ios' ||
      !isStartupDiagnosticsUuid(raw['event_id']) ||
      version is! String ||
      !_version.hasMatch(version) ||
      build is! int ||
      build < 1 ||
      build > 10000000 ||
      os is! String ||
      (os != 'unknown' && !_osVersion.hasMatch(os)) ||
      count is! int ||
      count < 1 ||
      count > 100 ||
      occurred is! String ||
      !_minute.hasMatch(occurred)) {
    return null;
  }
  final at = DateTime.tryParse(occurred);
  if (at == null ||
      at.toUtc().toIso8601String().replaceFirst('.000Z', 'Z') != occurred ||
      at.isBefore(now.toUtc().subtract(startupDiagnosticsMaxAge)) ||
      at.isAfter(now.toUtc().add(const Duration(minutes: 5)))) {
    return null;
  }
  if (!StartupFailureStage.values
          .any((value) => value.wireName == raw['stage']) ||
      !StartupFailureBoundary.values
          .any((value) => value.wireName == raw['boundary']) ||
      !SessionFailureCategory.values
          .any((value) => value.wireName == raw['category']) ||
      (raw.containsKey('preflight_cause') &&
          !StartupIdentityCause.values
              .any((value) => value.wireName == raw['preflight_cause'])) ||
      (raw.containsKey('login_stage') &&
          !StartupLoginStage.values
              .any((value) => value.wireName == raw['login_stage'])) ||
      (raw.containsKey('native_status') &&
          (!StartupNativeStatus.values
                  .any((value) => value.wireValue == raw['native_status']) ||
              !const {'platform', 'protected_data', 'keychain_permission'}
                  .contains(raw['category'])))) {
    return null;
  }
  return Map<String, Object>.unmodifiable(
      raw.map((key, value) => MapEntry(key as String, value as Object)));
}

List<Map<String, Object>> boundedStartupDiagnosticsReports(
    Iterable<Object?> raw,
    {required DateTime now}) {
  final reports = <Map<String, Object>>[];
  final ids = <Object>{};
  for (final item in raw) {
    final report = validateStartupDiagnosticsReport(item, now: now);
    if (report == null || !ids.add(report['event_id']!)) continue;
    reports.add(report);
    while (reports.length > startupDiagnosticsMaxEvents ||
        utf8.encode(jsonEncode(reports)).length > startupDiagnosticsMaxBytes) {
      reports.removeAt(0);
    }
  }
  return reports;
}

List<Map<String, Object>> decodeStartupDiagnosticsQueue(String payload,
    {required DateTime now}) {
  try {
    if (utf8.encode(payload).length > startupDiagnosticsMaxBytes) return [];
    final decoded = jsonDecode(payload);
    return decoded is List
        ? boundedStartupDiagnosticsReports(decoded, now: now)
        : [];
  } catch (_) {
    return [];
  }
}

/// A single fixed, app-private filename. The adapter never follows a link or
/// accepts a path from serialized data. Recorder owns serialized/bounded I/O.
final class FileStartupDiagnosticsSpool implements StartupDiagnosticsSpool {
  FileStartupDiagnosticsSpool(
      {Future<Directory> Function()? directoryProvider,
      DateTime Function()? clock})
      : _directoryProvider =
            directoryProvider ?? getApplicationSupportDirectory,
        _clock = clock ?? DateTime.now;
  static const fileName = 'startup-diagnostics-v1.json';
  final Future<Directory> Function() _directoryProvider;
  final DateTime Function() _clock;

  Future<File?> _file() async {
    final directory = await _directoryProvider();
    final directoryType =
        await FileSystemEntity.type(directory.path, followLinks: false);
    if (directoryType == FileSystemEntityType.notFound) {
      await directory.create(recursive: true);
    } else if (directoryType != FileSystemEntityType.directory) {
      return null;
    }
    // Provider supplies the trusted app-support path; iOS may alias ancestors
    // (for example /var). Refuse a linked leaf, then use its canonical location.
    final canonical = path.normalize(await directory.resolveSymbolicLinks());
    final file = File(path.join(canonical, fileName));
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    return type == FileSystemEntityType.file ||
            type == FileSystemEntityType.notFound
        ? file
        : null;
  }

  @override
  Future<List<Map<String, Object>>> read() async {
    final file = await _file();
    if (file == null ||
        !await file.exists() ||
        await file.length() > startupDiagnosticsMaxBytes) {
      return [];
    }
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > startupDiagnosticsMaxBytes) return [];
      bytes.addAll(chunk);
    }
    try {
      return decodeStartupDiagnosticsQueue(utf8.decode(bytes), now: _clock());
    } on FormatException {
      return [];
    }
  }

  @override
  Future<void> write(List<Map<String, Object>> reports) async {
    final file = await _file();
    if (file == null) return;
    final staging = File('${file.path}.tmp');
    final stagingType =
        await FileSystemEntity.type(staging.path, followLinks: false);
    if (stagingType != FileSystemEntityType.file &&
        stagingType != FileSystemEntityType.notFound) {
      return;
    }
    final body =
        jsonEncode(boundedStartupDiagnosticsReports(reports, now: _clock()));
    await staging.writeAsString(body, encoding: utf8, flush: true);
    await staging.rename(file.path);
  }
}
