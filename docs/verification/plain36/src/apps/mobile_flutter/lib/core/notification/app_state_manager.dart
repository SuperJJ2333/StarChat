/// 应用运行状态（PRD §21）。
///
/// 通知决策不只看 App Lifecycle：当前会话由 ConversationReadState 提供，
/// 通话占用由 [setCallActive] 提供，本类只维护前后台与通话两个维度。
enum AppRunState { foreground, background, inactive }

final class AppStateManager {
  AppRunState _state = AppRunState.foreground;
  bool _callActive = false;

  AppRunState get state => _state;

  bool get isForeground => _state == AppRunState.foreground;

  bool get callActive => _callActive;

  void updateLifecycle(AppRunState state) => _state = state;

  void setCallActive(bool active) => _callActive = active;
}
