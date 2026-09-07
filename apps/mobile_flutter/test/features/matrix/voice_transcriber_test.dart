import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:liuhetong_mobile/features/matrix/voice_transcriber.dart';

final class _Speech implements SpeechToText {
  final callbacks = <SpeechResultListener>[];
  Completer<void>? stopGate;
  int stopCalls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #initialize) return Future<bool>.value(true);
    if (invocation.memberName == #listen) {
      callbacks
          .add(invocation.namedArguments[#onResult] as SpeechResultListener);
      return Future<void>.value();
    }
    if (invocation.memberName == #stop) {
      stopCalls++;
      return stopGate?.future ?? Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }

  void words(int session, String value) =>
      callbacks[session](SpeechRecognitionResult.fromJson({
        'alternates': [
          {'recognizedWords': value, 'confidence': 1.0}
        ],
        'resultType': 2,
      }));
}

void main() {
  test('new native listener waits for the previous final-result window',
      () async {
    final engine = _Speech();
    final transcriber = SpeechToTextVoiceTranscriber(speech: engine);
    await transcriber.start();
    final oldStop = transcriber.stop();
    await Future<void>.delayed(Duration.zero);
    final next = transcriber.start();
    await Future<void>.delayed(Duration.zero);
    expect(engine.callbacks, hasLength(1),
        reason: 'speech plugin has one global result listener');
    engine.words(0, 'old final');
    expect(await oldStop, 'old final');
    await next;
    engine.words(1, 'new final');
    expect(await transcriber.stop(), 'new final');
  });

  test('late stop and old results cannot consume or clear the next recording',
      () async {
    final engine = _Speech();
    final transcriber = SpeechToTextVoiceTranscriber(speech: engine);
    await transcriber.start();
    engine.words(0, 'first');
    engine.stopGate = Completer<void>();
    final oldStop = transcriber.stop();
    await Future<void>.delayed(Duration.zero);
    final nextStart = transcriber.start();
    engine.stopGate!.complete();
    await nextStart;
    expect(await oldStop, 'first');
    engine.words(1, 'second');
    // Native callbacks from the old session can arrive after its stop Future.
    engine.words(0, 'stale');
    engine.stopGate = null;
    expect(await transcriber.stop(), 'second');
  });

  test('repeated start is idempotent and repeated stop shares the same result',
      () async {
    final engine = _Speech();
    final transcriber = SpeechToTextVoiceTranscriber(speech: engine);
    await transcriber.start();
    engine.words(0, 'retained');
    await transcriber.start();
    engine.stopGate = Completer<void>();
    final a = transcriber.stop();
    final b = transcriber.stop();
    engine.stopGate!.complete();
    expect(await a, 'retained');
    expect(await b, 'retained');
    expect(engine.callbacks, hasLength(1));
    expect(engine.stopCalls, 1);
  });
}
