import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/sending_session_warmup.dart';

void main() {
  test('one worker promotes current room and bounds all reads to eight',
      () async {
    final hold = Completer<void>();
    final reads = <String>[];
    var inFlight = 0;
    final warmup = SendingSessionWarmup(
        candidates: () => List.generate(20, (i) => 'room$i'),
        isActive: () => true,
        load: (room) async {
          expect(++inFlight, 1);
          reads.add(room);
          if (reads.length == 1) await hold.future;
          inFlight--;
        });
    final first = warmup.schedule();
    await Future<void>.delayed(Duration.zero);
    final second = warmup.schedule(current: 'room17');
    hold.complete();
    await Future.wait([first, second]);
    expect(reads, [
      'room0',
      'room17',
      'room1',
      'room2',
      'room3',
      'room4',
      'room5',
      'room6'
    ]);
    await warmup.schedule();
    expect(reads, hasLength(8));
  });
  test('revoke and candidate removal after await stop unwanted reads',
      () async {
    var active = true;
    final reads = <String>[];
    final warmup = SendingSessionWarmup(
        candidates: () => ['current', 'pinned', 'hidden'],
        isActive: () => active,
        load: (room) async {
          reads.add(room);
          active = false;
        });
    await warmup.schedule(current: 'current');
    expect(reads, ['current']);
  });
  test('failed optional read does not block later eligible rooms', () async {
    final eligible = ['pinned', 'recent', 'removed'];
    final reads = <String>[];
    final warmup = SendingSessionWarmup(
        candidates: () => eligible,
        isActive: () => true,
        load: (room) async {
          reads.add(room);
          if (room == 'pinned') {
            eligible.remove('removed');
            throw StateError('fixture');
          }
        });
    await warmup.schedule(current: 'not-eligible');
    expect(reads, ['pinned', 'recent']);
  });
}
