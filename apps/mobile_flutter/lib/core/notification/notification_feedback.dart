import 'sound_type.dart';

/// 纯前台 UI 反馈音入口（PRD §2/§68-2：业务页面禁止直接播放声音）。
///
/// 页面只调用 [NotificationFeedback.play]；实际播放回调由组合根
/// （AppHome）安装为 NotificationCoordinator.playUiSound——它会先检查
/// 通知设置中的声音开关。未安装（测试/异常环境）时静默跳过。
final class NotificationFeedback {
  NotificationFeedback._();

  static final NotificationFeedback _shared = NotificationFeedback._();

  static NotificationFeedback get shared => _shared;

  void Function(SoundType type)? _player;

  /// 在组合根安装一次：传入协调器的 playUiSound。
  static void install(void Function(SoundType type) player) {
    _shared._player = player;
  }

  static void uninstall() {
    _shared._player = null;
  }

  void play(SoundType type) => _player?.call(type);
}
