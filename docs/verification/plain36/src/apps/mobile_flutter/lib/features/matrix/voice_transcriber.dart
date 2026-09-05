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
  SpeechToTextVoiceTranscriber({this.localeId = 'zh-CN'});

  final String localeId;
  final SpeechToText _stt = SpeechToText();
  bool _initialized = false;
  bool _available = false;
  bool _listening = false;
  final StringBuffer _finalText = StringBuffer();
  String _partial = '';

  void _onResult(SpeechRecognitionResult result) {
    if (result.finalResult) {
      _finalText.write(result.recognizedWords);
      _partial = '';
    } else {
      _partial = result.recognizedWords;
    }
  }

  void _onStatus(String status) {
    if (status == 'done' || status == 'notListening') {
      _listening = false;
    }
  }

  @override
  Future<bool> isAvailable() async {
    await _ensureInitialized();
    return _available;
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    try {
      _available = await _stt.initialize(onStatus: _onStatus);
    } catch (_) {
      _available = false;
    }
  }

  @override
  Future<void> start() async {
    _finalText.clear();
    _partial = '';
    await _ensureInitialized();
    if (!_available || _listening) return;
    await _stt.listen(
      onResult: _onResult,
      // 7.4.0：超时与语言迁移入 SpeechListenOptions（旧参数已废弃）。
      listenOptions: SpeechListenOptions(
        localeId: localeId,
        listenFor: const Duration(minutes: 2),
      ),
    );
    _listening = true;
  }

  @override
  Future<String> stop() async {
    if (_listening) {
      _listening = false;
      try {
        await _stt.stop();
      } catch (_) {}
    }
    if (!_available) {
      // 识别能力不可用时直接返回累计结果，不做无谓等待。
      final text = (_finalText.toString() + _partial).trim();
      _finalText.clear();
      _partial = '';
      return text;
    }
    // 系统“done”回调可能略晚于 stop()：有界等待最终识别结果落地，
    // 避免松手即返回空串（转文字因此被误判失败的主要根因）。
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      if ((_finalText.toString() + _partial).trim().isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final text = (_finalText.toString() + _partial).trim();
    _finalText.clear();
    _partial = '';
    return text;
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
