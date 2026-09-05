/// SoundType 统一枚举（PRD §68-26）。
///
/// 每个枚举值对应 `assets/sounds/` 下的固定文件名；缺失素材以现有素材
/// 顶替（同名拷贝），正式素材到位后覆盖同名文件即可，无需改代码。
/// 生成管线见 `scripts/build_notification_sounds.ps1`。
enum SoundType {
  /// 普通新消息（PRD §5：短促、干净、清脆）。
  messageReceived('message_received.mp3'),

  /// 用户发送成功（PRD §26：纯前台反馈，不计未读）。
  messageSent('message_sent.mp3'),

  /// 特别关注（PRD §27：双音、辨识度高）。
  messageAttention('message_attention.mp3'),

  /// 群聊 @我（PRD §28）。
  mention('mention.mp3'),

  /// 通用通知（PRD §3 P3 业务通知）。
  notification('notification.mp3'),

  /// 语音来电铃声（循环段，PRD §9）。
  callVoiceIncoming('call_voice_incoming.mp3'),

  /// 视频来电铃声（循环段，PRD §10）。
  callVideoIncoming('call_video_incoming.mp3'),

  /// 主叫呼叫等待（循环段）。
  callOutgoing('call_outgoing.mp3'),

  /// 通话接通确认音。
  callConnected('call_connected.mp3'),

  /// 通话结束音（下降式、柔和）。
  callEnded('call_ended.mp3'),

  /// 点钻到账（PRD §45：通知默认不展示金额）。
  diamondReceived('diamond_received.mp3'),

  /// 转账到账。
  transferReceived('transfer_received.mp3'),

  /// 红包到达。
  redpacketReceived('redpacket_received.mp3'),

  /// 红包开启。
  redpacketOpen('redpacket_open.mp3'),

  /// 扫码 UI 反馈。
  scan('scan.mp3');

  const SoundType(this.fileName);

  /// 音频文件名（位于 `assets/sounds/`）。
  final String fileName;

  /// 完整 asset 路径。
  String get assetPath => 'assets/sounds/$fileName';
}
