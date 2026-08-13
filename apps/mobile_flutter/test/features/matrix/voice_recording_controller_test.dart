import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/voice_recording_controller.dart';
void main(){test('slide above cancellation threshold arms cancellation',(){final c=VoiceRecordingController();c.start();c.updateDrag(-61);expect(c.state,VoiceRecordingState.cancelArmed);c.release(const Duration(seconds:2));expect(c.state,VoiceRecordingState.idle);});test('valid recording enters preview before sending',(){final c=VoiceRecordingController();c.start();c.release(const Duration(seconds:3));expect(c.state,VoiceRecordingState.preview);});}
