/// 规格§二：统一互动权限服务（集中管理，禁止散落 UI 判断）。
///
/// 删除好友/拉黑后：保留聊天记录，禁止继续互动（发消息/媒体/通话/
/// 朋友圈）。入口层（输入框/相册/语音/通话按钮/朋友圈）与服务层
/// （发送路径守卫）都必须经过本服务——只隐藏 UI 不算防护。
enum InteractionState { friend, deleted, blocked, stranger }

extension InteractionStateX on InteractionState {
  bool get canInteract => this == InteractionState.friend;
}

final class InteractionPermission {
  const InteractionPermission._(this._state);

  factory InteractionPermission.resolve({
    required bool isFriend,
    required bool isBlocked,
  }) {
    if (isBlocked) return const InteractionPermission._(InteractionState.blocked);
    if (isFriend) return const InteractionPermission._(InteractionState.friend);
    // 曾为好友（有共同会话）但已删除 → deleted；无任何关系 → stranger。
    return const InteractionStateDeleted();
  }

  const InteractionPermission.of(this._state);

  final InteractionState _state;

  InteractionState get state => _state;

  bool canSendMessage() => _state.canInteract;
  bool canSendImage() => _state.canInteract;
  bool canSendVoice() => _state.canInteract;
  bool canStartVoiceCall() => _state.canInteract;
  bool canStartVideoCall() => _state.canInteract;
  bool canViewMoments() => _state == InteractionState.friend;

  /// 互动被拒时的用户可读提示（微信语义）。
  String denialMessage() => switch (_state) {
        InteractionState.friend => '',
        InteractionState.blocked => '对方已被拉黑，无法发送消息',
        InteractionState.deleted => '对方不是你的好友，请先添加好友',
        InteractionState.stranger => '对方不是你的好友，请先添加好友',
      };
}

/// resolve 的删除态构造（有共同会话但已非好友）。
final class InteractionStateDeleted extends InteractionPermission {
  const InteractionStateDeleted() : super.of(InteractionState.deleted);
}
