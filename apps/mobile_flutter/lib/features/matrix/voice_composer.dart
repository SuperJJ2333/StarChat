import 'dart:io';

import 'package:flutter/cupertino.dart';

import '../../ui/chat/wechat_hold_to_talk.dart';
import 'media_message_service.dart';
import 'voice_recording_controller.dart';

final class VoiceComposer extends StatefulWidget {
  const VoiceComposer({super.key, required this.service, required this.roomId});
  final MediaMessageService service;
  final String roomId;
  @override State<VoiceComposer> createState() => _VoiceComposerState();
}

final class _VoiceComposerState extends State<VoiceComposer> {
  final controller = VoiceRecordingController();
  String? previewPath;
  String? message;
  String get path => '${Directory.systemTemp.path}${Platform.pathSeparator}liuhetong-${DateTime.now().microsecondsSinceEpoch}.m4a';
  Future<void> start() => widget.service.startVoiceRecording(path);
  Future<void> stop(Duration _) async { previewPath = await widget.service.stopVoiceRecordingForPreview(); if (mounted) setState(() {}); }
  Future<void> cancel() => widget.service.cancelVoiceRecording();
  Future<void> send() async {
    final local = previewPath; if (local == null) return;
    controller.confirmSend();
    try { await widget.service.sendVoicePreview(widget.roomId, local); message='语音已加密发送'; controller.discard(); previewPath=null; }
    catch (_) { controller.fail(); message='发送失败，请重试'; }
    if (mounted) setState(() {});
  }
  Future<void> discard() async { final local=previewPath; if(local!=null)await File(local).delete().catchError((_)=>File(local));previewPath=null;controller.discard();if(mounted)setState((){}); }
  @override void dispose(){controller.dispose();widget.service.dispose();super.dispose();}
  @override Widget build(BuildContext context)=>Padding(padding:const EdgeInsets.all(16),child:Column(mainAxisSize:MainAxisSize.min,children:[
    WeChatHoldToTalk(controller:controller,onStart:start,onStop:stop,onCancel:cancel),
    if(controller.state==VoiceRecordingState.preview)...[const SizedBox(height:12),Text('录音 ${controller.duration?.inSeconds ?? 0} 秒，确认后发送'),Row(mainAxisAlignment:MainAxisAlignment.center,children:[CupertinoButton(onPressed:discard,child:const Text('重录')),CupertinoButton.filled(onPressed:send,child:const Text('发送'))])],
    if(message!=null)Text(message!),
  ]));
}
