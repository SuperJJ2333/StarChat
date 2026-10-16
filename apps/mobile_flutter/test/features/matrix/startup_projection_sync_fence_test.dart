import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/core/startup_projection/startup_projection_coordinator.dart';

class _CommitDatabase implements DatabaseApi {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool rollback = false;
  @override
  Future<void> transaction(Future<void> Function() action) async {
    await action();
    entered.complete();
    await release.future;
    if (rollback) throw StateError('synthetic transaction rollback');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _Client extends Client {
  _Client(this.db, http.Client transport)
      : super('projection-sync-fixture', httpClient: transport);
  final DatabaseApi db;
  @override
  DatabaseApi? get database => db;
}

void main() {
  for (final rollback in [false, true]) {
    test(
        'production sync keeps capture fenced past onSync through commit; rollback=$rollback',
        () async {
      final db = _CommitDatabase()..rollback = rollback;
      final response = Completer<http.Response>();
      final requested = Completer<void>();
      final client = _Client(db, MockClient((request) {
        if (request.url.path.endsWith('/sync')) {
          requested.complete();
          return response.future;
        }
        return Future.value(http.Response('{}', 404));
      }))
        ..homeserver = Uri.parse('https://synthetic.test')
        ..accessToken = 'synthetic'
        ..backgroundSync = false;
      final coordinator =
          StartupProjectionCoordinator(invalidateHead: () async {})
            ..markVerified();
      var begins = 0;
      var settled = 0;
      var onSyncCaptureAllowed = false;
      client.beginLocalDisplayMutation = () async {
        begins++;
        final ticket = coordinator.beginMutation('sync');
        await ticket.beforeApply;
        return (applied) => ticket.finish(applied: applied);
      };
      client.onLocalDisplayApplySettled = (_) => settled++;
      final subscription = client.onSync.stream.listen((_) {
        onSyncCaptureAllowed = coordinator.beginCapture() != null;
      });
      try {
        final syncing = client.oneShotSync();
        await requested.future.timeout(const Duration(seconds: 3));
        expect(begins, 0, reason: 'held longpoll must not starve writer');
        expect(coordinator.beginCapture(), isNotNull);
        response.complete(http.Response(
            jsonEncode({
              'next_batch': 'synthetic',
              'account_data': {
                'events': [
                  {
                    'type': 'synthetic.display',
                    'content': {'value': true}
                  }
                ]
              }
            }),
            200));
        await db.entered.future.timeout(const Duration(seconds: 3));
        await Future<void>.delayed(Duration.zero);
        expect(begins, 1);
        expect(onSyncCaptureAllowed, isFalse);
        expect(coordinator.beginCapture(), isNull);
        expect(settled, 0);
        db.release.complete();
        await syncing;
        expect(settled, rollback ? 0 : 1);
        expect(coordinator.beginCapture(), rollback ? isNull : isNotNull);
      } finally {
        if (!db.release.isCompleted) db.release.complete();
        await subscription.cancel();
        await client.dispose();
      }
    });
  }
}
