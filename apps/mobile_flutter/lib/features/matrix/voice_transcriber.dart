import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// 语音转文字能力抽象：录音期间并行开启识别，
/// 松手“转文字”时停止并取回识别文本。
abstract interface class VoiceTranscriber {
  /// 设备是否具备语音识别能力（不可用时“转文字”降级提示）。
  Future<bool> isAvailable();

  /// 开始实时识别（与录音并行），重复调用安全。
  Future<void> start();

  /// 停止识别并返回累计识别文本；失败返回空串。
  Future<String> stop();
}

/// 基于 speech_to_text（系统语音识别）的实现。
final class SpeechToTextVoiceTranscriber implements VoiceTranscriber {
  SpeechToTextVoiceTranscriber({this.localeId = 'zh-CN', SpeechToText? speech})
      : _stt = speech ?? SpeechToText();

  final String localeId;
  final SpeechToText _stt;
  bool _available = false;
  Future<void>? _initialization;
  Future<void> _nativeQueue = Future<void>.value();
  _RecognitionSession? _session;

  @override
  Future<bool> isAvailable() async {
    await _ensureInitialized();
    return _available;
  }

  Future<void> _ensureInitialized() => _initialization ??= () async {
        try {
          _available = await _stt.initialize();
        } catch (_) {
          _available = false;
        }
      }();

  Future<void> _native(Future<void> Function() operation) {
    final work = _nativeQueue.then((_) => operation());
    _nativeQueue =
        work.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return work;
  }

  @override
  Future<void> start() async {
    // Repeated starts of the same recording cannot erase recognized words.
    final current = _session;
    if (current != null && current.stopping == null && !current.closed) return;
    final session = _RecognitionSession();
    _session = session;
    await _ensureInitialized();
    if (!_available ||
        !identical(_session, session) ||
        session.stopping != null) {
      return;
    }
    await _native(() async {
      if (!identical(_session, session) || session.stopping != null) {
        return;
      }
      try {
        await _stt.listen(
          onResult: session.accept,
          listenOptions: SpeechListenOptions(
              localeId: localeId, listenFor: const Duration(minutes: 2)),
        );
        session.listening = true;
      } catch (_) {
        session.closed = true;
      }
    });
  }

  @override
  Future<String> stop() {
    final session = _session;
    if (session == null) return Future<String>.value('');
    // A stop belongs to the captured session, even if another recording starts
    // during native stop or the bounded final-result wait.
    return session.stopping ??= _stopSession(session);
  }

  Future<String> _stopSession(_RecognitionSession session) async {
    var text = '';
    await _native(() async {
      if (session.listening) {
        session.listening = false;
        try {
          await _stt.stop();
        } catch (_) {}
      }
      // SpeechToText owns one native result listener. Keep a subsequent listen
      // behind this short final-result window so late native results still go
      // to the old session. Audio recording and the composer stay independent.
      if (_available && !session.closed) {
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (session.text.isEmpty && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      text = session.text;
      session.closed = true;
      session.clear();
    });
    return text;
  }
}

/// Each result callback captures one recording generation. Old final callbacks
/// may finish that generation; they can never mutate a newer recording.
final class _RecognitionSession {
  final _finalText = StringBuffer();
  String _partial = '';
  bool listening = false;
  bool closed = false;
  Future<String>? stopping;
  String get text => (_finalText.toString() + _partial).trim();

  void accept(SpeechRecognitionResult result) {
    if (closed) return;
    if (result.finalResult) {
      _finalText.write(result.recognizedWords);
      _partial = '';
    } else {
      _partial = result.recognizedWords;
    }
  }

  void clear() {
    _finalText.clear();
    _partial = '';
  }
}

/// 恒定不可用实现：测试与降级场景使用。
final class NoopVoiceTranscriber implements VoiceTranscriber {
  const NoopVoiceTranscriber();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<void> start() async {}

  @override
  Future<String> stop() async => '';
}
