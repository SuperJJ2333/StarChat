import 'package:flutter/foundation.dart' show ValueListenable;
import 'logical_conversation_timeline.dart';
import 'room_navigation_coordinator.dart';
import '../settings/voice_auto_play_preferences.dart';
import 'coordinated_direct_chat.dart';
import 'timeline_scroll_anchor.dart';
import 'nudge_rate_limiter.dart';
// 会话聊天页（RoomPage）：私聊与群聊共用的消息时间线与交互。
// 自 matrix_home_page.dart 拆分（巨石文件治理）。
import 'dart:async';
import 'dart:io';

import 'room_draft_store.dart';
import 'media_load_scheduler.dart';
import 'media_memory_budget.dart';

import 'package:flutter/cupertino.dart';
import '../../ui/chat/group_avatar_mosaic.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/business_api_client.dart';
import '../../core/outbox/outbox_message.dart';
import '../../core/outbox/outbox_room_sender_registry.dart';
import '../../core/outbox/persistent_outbox_manager.dart';
import '../../core/permissions/blocked_contacts.dart';
import '../../core/support_identity_repository.dart';
import '../../ui/chat/flash_photo.dart';
import '../../core/performance_metrics.dart';
import '../../core/chat_payment_intent.dart';
import 'chat_payment_flow.dart';
import '../contacts/contact_models.dart';
import '../contacts/add_friend_profile_page.dart';
import '../contacts/contacts_page.dart';
import '../profile/profile_controller.dart';
import '../../ui/chat/chat_composer_bar.dart';
import '../../ui/chat/wechat_composer.dart' show chatComposerPanelGroupId;
import '../../ui/chat/chat_composer_state.dart';
import '../../ui/chat/chat_emoji_panel.dart';
import '../../ui/chat/chat_more_panel.dart';
import 'package:flutter/services.dart';

import '../../ui/chat/message_action.dart';
import '../../ui/chat/message_bubble_menu.dart';
import '../../ui/chat/message_menu_placement.dart';
import '../../ui/chat/emoji_text_controller.dart';
import '../../ui/chat/message_highlight_pulse.dart';
import '../../ui/components/wechat_toast.dart';
import '../../ui/chat/message_text_selection.dart';
import '../../ui/chat/quote_preview_card.dart';
import '../../ui/chat/quote_return_banner.dart';
import 'reply_message_resolution.dart';
import '../../features/emoji/emoji_shortcode.dart';
import '../../ui/chat/chat_forward_picker_page.dart';
import 'recent_forward_store.dart';
import 'media_thumbnail.dart';
import 'gif_image_policy.dart';
import 'chat_image_preview.dart';
import '../../ui/chat/message_scroll_locator.dart';
import '../../ui/chat/latest_message_anchor.dart';
import 'room_image_preview_cache.dart';
import 'group_announcement_page.dart';
import 'video_transcode.dart';
import '../../ui/chat/message_action_sheet.dart' show MessageSelectionBar;
import '../../ui/chat/wechat_attachment_tile.dart';
import '../../ui/chat/wechat_mention_panel.dart';
import '../../ui/chat/wechat_message_bubble.dart';
import '../../ui/chat/wechat_nudge_notice.dart';
import '../../ui/chat/wechat_voice_bubble.dart';
import '../../ui/chat/wechat_call_bubble.dart';
import '../../ui/chat/wechat_video_message.dart';
import '../../ui/chat/chat_tools.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/components/wechat_nav_title.dart';
import '../../ui/finance/wechat_red_packet_card.dart';
import '../../ui/finance/wechat_transfer_card.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../transfer/chat_transfer_adapters.dart';
import '../transfer/chat_transfer_controller.dart';
import '../transfer/chat_transfer_sheet.dart';
import 'matrix_e2ee_client.dart';
import 'matrix_outgoing_work_coordinator.dart';
import 'image_picker_page.dart';
import 'gallery_media_payload.dart';
import 'voice_recording_controller.dart';
import 'call_ui_manager.dart' show callAudioActivity;
import 'voice_playback_controller.dart' hide VoicePlaybackState;
import 'voice_transcriber.dart';
import '../../ui/chat/wechat_hold_to_talk.dart';
import '../../ui/chat/voice_recording_overlay.dart';
import '../../features/emoji/fluent_emoji_catalog.dart';
import '../../ui/chat/emoji_text.dart';
import '../../ui/chat/contain_image_bubble.dart';
import '../../ui/chat/super_emoji_message.dart';
import '../statistics/statistics_tool.dart';
import 'media_cache.dart';
import 'content_addressed_media.dart';
import 'matrix_user_avatar.dart';
import 'profile_repository.dart';
import 'matrix_room_timeline_adapter.dart';
import 'chat_red_packet_adapters.dart';
import 'chat_red_packet_controller.dart';
import 'chat_red_packet_sheet.dart';
import 'group_member_picker.dart';
import 'group_chat_info_controller.dart';
import 'group_chat_info_page.dart';
import '../contacts/member_directory_service.dart';
import '../../ui/chat/chat_search_page.dart';
import 'unread_mention_tracker.dart';
import 'room_mention_store.dart';
import '../../ui/chat/conversation_mention_banner.dart';
import 'video_poster_session_cache.dart';
import 'video_poster_disk_store.dart';
import 'video_poster_diagnostics.dart';
import 'video_poster_pipeline.dart';
import 'chat_search_query_controller.dart'
    show ChatSearchMessage, ChatSearchMediaCategory;
import 'conversation_preferences.dart';
import '../../core/permissions/interaction_permission.dart';
import 'conversation_presentation.dart';
import 'conversation_read_state.dart';
import 'direct_chat_info_page.dart';
import 'matrix_emoji_vault.dart';
import 'media_message_service.dart';
import 'message_reminder_service.dart';
import 'mention_composer_model.dart';
import 'message_interaction_service.dart';
import 'nudge_service.dart';
import 'local_hidden_events.dart';
import 'room_timeline_controller.dart';
import 'sent_video_local_registry.dart';
import 'room_history_date_capability.dart';
import '../../ui/chat/room_image_gallery.dart';
import '../contacts/contact_actions.dart';
import '../finance/finance_card_store.dart';
import '../finance/finance_message_entry.dart';
import '../finance/finance_message_presentation.dart';
import 'media_message_access_policy.dart';
import 'room_media_gallery_projection.dart';
import '../search/local_message_search_repository.dart';
import '../search/room_search_index_scheduler.dart';
import '../../ui/motion/motion_page_route.dart';

/// Counts the authoritative joined snapshot exactly once per Matrix member.
/// The local account must be present in that snapshot; callers must not infer
/// membership from a stale room object.
int redPacketJoinedMemberCount(
    Iterable<MatrixRoomMemberSnapshot> members, String? selfId) {
  final ids = <String>{
    for (final member in members)
      if (member.isJoined) member.id,
  };
  if (selfId == null || selfId.isEmpty || !ids.contains(selfId)) {
    throw StateError('群成员状态已失效');
  }
  return ids.length;
}

class RoomPage extends StatefulWidget {
  const RoomPage({
    super.key,
    this.voiceTranscriber,
    required this.api,
    required this.roomName,
    required this.roomLease,
    this.mediaSenderFactory,
    this.initialContact,
    this.initialAnchorEventId,
    required this.onCreateGroup,
    this.onCreateGroupWithPeer,
    this.reminderService,
    this.onMessage,
    this.onVoice,
    this.onVideo,
    this.initialIdentityCache,
    this.initialOutbox = const <String>[],
    this.outbox,
    this.readOnly = false,
    this.initialAnchorRoomId,
    this.navigationRequests,
    this.requestOutboxDrain,
    this.resolveDirectSendTarget,
    this.onDirectTargetChanged,
    this.initialOutboxLocalIds = const <String>[],
  });

  final BusinessApiClient api;
  final String roomName;
  final MatrixRoomLease roomLease;
  final RoomPickedMediaSender Function(MatrixEncryptedMediaGateway gateway)?
      mediaSenderFactory;
  final ContactDetails? initialContact;
  final VoidCallback onCreateGroup;

  /// BUG-16：携带当前会话对端发起群聊（进入发起页即默认选中该对端，
  /// 可取消）；为 null 的入口保持原 [onCreateGroup] 行为。
  final ValueChanged<String?>? onCreateGroupWithPeer;
  final MessageReminderService? reminderService;
  final ContactAction? onMessage;
  final ContactAction? onVoice;
  final ContactAction? onVideo;
  final ProfileRepository? initialIdentityCache;

  /// 语音转文字实现（可注入；默认系统语音识别）。
  final VoiceTranscriber? voiceTranscriber;

  /// 正式的房间导航契约：全局搜索/深链可携带 anchorEventId 打开房间，
  /// 进入后定位并高亮该消息（不使用全局变量或 SharedPreferences 传参）。
  final String? initialAnchorEventId;

  /// 只读打开（缺陷 0919 项 3）：历史孤儿房间经搜索/通知定位时为 true，
  /// 隐藏输入区与面板——保留查看与定位能力，但不提供任何发送入口。
  final bool readOnly;

  final String? initialAnchorRoomId;
  final ValueListenable<RoomOpenRequest>? navigationRequests;
  final VoidCallback? requestOutboxDrain;
  final Future<String> Function(String matrixPeer)? resolveDirectSendTarget;
  final void Function(String roomId)? onDirectTargetChanged;
  final List<String> initialOutboxLocalIds;

  /// Offline First：pending conversation 期间输入、尚未发送的文本。
  /// 页面首次加载完成后按顺序自动发送（弱网/无网时由消息状态机进入
  /// “等待发送”并在网络恢复后重试）。
  ///
  /// 注意：这些原文**只在没有对应持久化 outbox 行时**才会走"新建发送"，
  /// 已落盘的行由 `outbox`（同一 txid）派发，避免同一条消息发两次。
  final List<String> initialOutbox;

  /// 持久化出站消息管理器；为空时回退 [PersistentOutboxManager.shared]。
  final PersistentOutboxManager? outbox;

  @override
  State<RoomPage> createState() => _RoomPageState();
}

/// BUG 2 群成员点击分流：好友 → "好友资料"页；非好友 → 按 Matrix ID
/// 反查业务资料后进"用户资料"页（可"添加到通讯录"）；自己不可点。
/// 反查失败（不存在/拉黑）提示后返回，不再静默无响应。
Future<void> openGroupMemberProfile(
  BuildContext context, {
  required AddFriendGateway api,
  required Future<Map<String, dynamic>> Function(String matrixUserId)
      lookupByMatrixId,
  required GroupChatMember member,
  String? selfMatrixUserId,
  ProfileRepository? identityCache,
  ContactActions? contactActions,
  ContactDetails? friendContact,
  void Function(ContactDetails contact)? onOpenFriendContact,
}) async {
  if (member.matrixUserId == selfMatrixUserId) return;
  if (friendContact != null) {
    onOpenFriendContact?.call(friendContact);
    return;
  }
  try {
    final profile = await lookupByMatrixId(member.matrixUserId);
    if (!context.mounted) return;
    await Navigator.of(context, rootNavigator: true).push(
      MotionPageRoute(
        builder: (_) => AddFriendProfilePage(
          api: api,
          identityCache: identityCache,
          contactActions: contactActions,
          userId: profile['user_id']?.toString() ?? '',
          username: profile['username']?.toString() ?? member.matrixUserId,
          nickname: (profile['nickname']?.toString() ?? '').isNotEmpty
              ? profile['nickname'].toString()
              : member.displayName,
          relationshipState:
              profile['relationship_state']?.toString() ?? 'NONE',
          avatarUrl: profile['avatar_url']?.toString(),
        ),
      ),
    );
  } catch (_) {
    if (!context.mounted) return;
    await showCupertinoDialog<void>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('无法获取用户资料'),
        content: const Text('该用户不存在或暂时不可添加。'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

class _RoomPageState extends State<RoomPage> with WidgetsBindingObserver {
  bool _paymentEntryBusy = false;

  Future<ChatPaymentIntent?> _preparePayment() async {
    if (_paymentEntryBusy) return null;
    _paymentEntryBusy = true;
    try {
      return await prepareChatPayment(context, api: widget.api,
          recipient: (payload) {
        final id = payload['receiver_id'] ?? payload['recipient_id'];
        if (id != null) {
          for (final contact in contactsByMatrixId.values) {
            if (contact.userId == id || contact.matrixUserId == id) {
              return contact.displayName;
            }
          }
          return id.toString();
        }
        return roomInfo.name;
      });
    } on BusinessApiException catch (error) {
      if (mounted) await _showError(error.message);
      return null;
    } catch (_) {
      if (mounted) await _showError('支付设置暂时无法加载，请稍后重试');
      return null;
    } finally {
      _paymentEntryBusy = false;
    }
  }

  late MatrixRoomInfoSnapshot roomInfo;
  final Completer<void> _disposed = Completer<void>();
  final Set<Future<void>> _pendingMatrixOperations = {};
  List<MatrixRoomMemberSnapshot> get _joinedMembers {
    final members = {
      for (final member in roomInfo.members)
        if (member.isJoined) member.id: member,
    };
    return [
      for (final id in reconcileMemberOrder(
        roomInfo.preference.memberOrderIds,
        members.keys,
      ))
        members[id]!,
    ];
  }

  MatrixRoomMemberSnapshot _member(String id) => roomInfo.members.firstWhere(
        (member) => member.id == id,
        orElse: () => MatrixRoomMemberSnapshot(
          id: id,
          displayName: localPart(id),
          avatarUri: null,
          isJoined: false,
        ),
      );
  Future<void> _trackMatrixOperation(Future<void> operation) async {
    _pendingMatrixOperations.add(operation);
    try {
      await operation;
    } finally {
      _pendingMatrixOperations.remove(operation);
    }
  }

  Future<void> _trackAction(FutureOr<void> Function() action) =>
      _trackMatrixOperation(Future<void>.sync(action));
  Future<void> _drainMatrixOperations() async {
    await _disposed.future;
    await _outgoingMediaQueue;
    while (_pendingMatrixOperations.isNotEmpty) {
      await Future.wait(_pendingMatrixOperations.toList(growable: false));
    }
  }

  late final _draftKey = RoomDraftStore.key(
    '${roomInfo.homeserver}',
    roomInfo.currentUserId ?? '',
    roomInfo.id,
  );
  int _draftRevision = 0;

  void _saveDraft() {
    _draftRevision++;
    RoomDraftStore.shared
        .save(_draftKey, RoomDraft(input.text, tokens: mentionComposer.tokens));
    // BUG-20：同步登记列表草稿预览（空文本即清除）。
    RoomDraftStore.shared.recordDraftPreview(roomInfo.id, input.text);
  }

  Future<void> _restoreDraft() async {
    // 草稿恢复绝不阻断会话进入：损坏/异常时丢弃草稿（输入框为空），
    // 页面照常打开。此前 emoji 草稿场景出现过进入失败的报告。
    try {
      final draft = await RoomDraftStore.shared.read(_draftKey);
      if (!mounted || _draftRevision != 0 || draft == null) return;
      mentionComposer.tokens
        ..clear()
        ..addAll(draft.tokens);
      _setComposerText(draft.text, draft.text.length);
    } catch (error) {
      if (!mounted) return;
      // 丢弃无法恢复的草稿，避免同一条坏数据反复阻断进入。
      try {
        await RoomDraftStore.shared.flush(_draftKey);
      } catch (_) {}
      RoomDraftStore.shared.save(_draftKey, const RoomDraft(''));
      unawaited(RoomDraftStore.shared.flush(_draftKey));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _readReceiptDebounce?.cancel();
      unawaited(RoomDraftStore.shared.flush(_draftKey));
    } else {
      _syncReadReceiptWhileViewing();
      if (_readReceiptDirty) _scheduleReadReceipt(Duration.zero);
    }
  }

  bool _disposing = false;
  // 输入框控制器：表情目录内 emoji 以彩色/动态字形渲染（与气泡一致），
  // 修复老系统字体缺字导致的空白/方框；光标、选区、IME 行为不变。
  final input = EmojiEditingController();
  final inputFocusNode = FocusNode();
  final messageScrollController = ScrollController();
  late final latestMessageAnchor = LatestMessageAnchor(messageScrollController);
  final messageListScrolling = ValueNotifier<bool>(false);
  final _stableMessageKeys = <String, GlobalKey>{};
  // 文本消息渲染对象的 key：长按选择（规格 #5）用它定位选区/手柄。
  final _messageTextKeys = <String, GlobalKey>{};
  late final roomImagePreviewCache = RoomImagePreviewCache.forRoomSession(
      accountId: '${roomInfo.homeserver}|${roomInfo.currentUserId}',
      memoryNamespace: roomInfo.currentUserId ?? '',
      roomId: roomInfo.id);
  bool _locatingMessage = false;
  bool _userTimelineDragActive = false;
  bool? _pendingEarlierWindow;
  double? _lastTimelineScrollOffset;
  int _timelineScrollGeneration = 0;
  ScrollPosition? _observedTimelineScrollPosition;
  VoicePlaybackController? _voicePlayback;
  VoicePlaybackController get voicePlayback =>
      _voicePlayback ??= VoicePlaybackController(
        canPlay: () => _canPlayVoice,
        // 语音附件经本地缓存：首次解密下载，重播直接读缓存（无重复网络）。
        loadAttachment: (eventId) => controller!.loadAttachment(eventId),
        // BUG-40（D7 默认开）：同会话连播——上一条自然播完后自动播下一条未读语音。
        autoPlayNextVoiceEnabled: () => voiceAutoPlayPreferences.autoPlayNext,
        nextAutoPlayVoice: _nextUnreadVoiceAfter,
      );
  /// BUG-40：同会话内 [eventId] 之后最近的一条**未播过**的非本人语音。
  RoomMessageViewModel? _nextUnreadVoiceAfter(String eventId) {
    final timeline = controller;
    if (timeline == null) return null;
    final current = timeline.findMessage(eventId);
    if (current == null) return null;
    RoomMessageViewModel? best;
    for (final message in timeline.allMessages) {
      if (message.isOwn || message.kind != RoomMessageKind.voice) continue;
      if (voicePlayback.isPlayed(message.id)) continue;
      if (!message.timestamp.isAfter(current.timestamp)) continue;
      if (best == null || message.timestamp.isBefore(best.timestamp)) {
        best = message;
      }
    }
    return best;
  }

  final messageKeys = <String, GlobalKey>{};
  final recalledDrafts = <String, String>{};
  final selection = MessageSelectionController();
  // 会话级图片内存缓存：滚动往复时同步命中，杜绝重复解密与布局抖动。
  late final imageMemoryCache = MediaMemoryCache(
      budget: sharedMediaMemoryBudget,
      accountNamespace: roomInfo.currentUserId ?? '');

  // 缩略图独立缓存（键前缀 thumb:）：消息气泡优先渲染发送端压缩演绎版，
  // 与原图、视频和房间预览共享编码字节预算。
  late final thumbnailMemoryCache = MediaMemoryCache(
      budget: sharedMediaMemoryBudget,
      accountNamespace: roomInfo.currentUserId ?? '');

  final _posterDisk = VideoPosterDiskStore();
  final Map<String, String> _posterKeys = {};

  /// Room-instance cache: independent encrypted temporary files, no global LRU.
  /// （Phase 1 保留：会话级内存 LRU + 单飞 + 临时加密磁盘层，未删除。）
  late final VideoPosterSessionCache videoPosterCache = VideoPosterSessionCache(
    diskRead: _posterDisk.read,
    diskWrite: _posterDisk.write,
    diskDelete: _posterDisk.delete,
    diskListKeys: _posterDisk.keys,
  );

  /// 视频封面脱敏诊断（只记加盐哈希 ID + 来源 + 耗时/字节数）。
  late final videoPosterDiagnostics = VideoPosterDiagnostics(
    salt: roomInfo.currentUserId ?? '',
  );

  /// Phase 1 视频封面流水线：**没有任何视频下载入口**。
  late final VideoPosterPipeline videoPosterPipeline = VideoPosterPipeline(
    accountId: roomInfo.currentUserId ?? '',
    roomId: roomInfo.id,
    memory: videoPosterCache,
    loadServerPoster: _loadServerVideoPoster,
    readCachedPoster: _readCachedVideoPoster,
    writeCachedPoster: _writeCachedVideoPoster,
    findLocalVideoFile: _findLocalVideoFile,
    diagnostics: videoPosterDiagnostics,
  );

  /// 封面仍缺失的视频消息（播放完成后尝试补生成，避免无意义刷新）。
  final Set<String> _posterMissing = <String>{};

  /// 封面补生成信号（`message.id` → revision），驱动卡片重新解析。
  final Map<String, int> _posterRevisions = <String, int>{};

  /// R4：未读 @ 跟踪器（账号隔离；会话实例生命周期）。
  UnreadMentionTracker? unreadMentions;
  Timer? _mentionVisibilityTimer;
  final _mentionVisibleSince = <String, DateTime>{};
  final _timelineViewportKey = GlobalKey();

  final _mentionRevision = ValueNotifier<int>(0);
  void _mentionStateChanged() {
    if (mounted) _mentionRevision.value++;
  }

  final Set<String> _visibleReadIds = {};
  // E1：搜索索引增量调度与突发去抖。
  final RoomSearchIndexScheduler _searchIndexScheduler =
      RoomSearchIndexScheduler();
  Timer? _searchIndexDebounce;
  final Set<String> _acknowledgedVisibleIds = {};
  bool _immediateVisibleReceipt = false;
  void _observeVisibleReadReceipts() {
    if (!_canSyncReadReceipt ||
        _logicalTimeline is! RoomVisibleReadCapability ||
        ModalRoute.of(context)?.isCurrent != true ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) {
      return;
    }
    final viewport = _timelineViewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return;
    final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
    var changed = false;
    for (final entry in messageKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (!_acknowledgedVisibleIds.contains(entry.key) &&
          rect.overlaps(bounds) &&
          !rect.intersect(bounds).isEmpty) {
        changed = _visibleReadIds.add(entry.key) || changed;
      }
    }
    if (changed) {
      _readReceiptDirty = true;
      if (_immediateVisibleReceipt) {
        _immediateVisibleReceipt = false;
        unawaited(_trackMatrixOperation(_sendReadReceipt()));
      } else {
        _scheduleReadReceipt(const Duration(milliseconds: 800));
      }
    }
  }

  void _observeVisibleMentions() {
    _observeVisibleReadReceipts();
    final state = unreadMentions;
    if (!mounted || state == null || !state.hasPending) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        ModalRoute.of(context)?.isCurrent != true) {
      _mentionVisibleSince.clear();
      return;
    }
    final viewport = _timelineViewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return;
    final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
    final now = DateTime.now();
    var changed = false;
    for (final id in state.pendingEventIdsNewestFirst()) {
      final box = messageKeys[id]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) {
        _mentionVisibleSince.remove(id);
        continue;
      }
      final rect = box.localToGlobal(Offset.zero) & box.size;
      final intersection = rect.intersect(bounds);
      final visible = !intersection.isEmpty &&
          rect.height > 0 &&
          intersection.height >=
              mentionVisibleHeightThreshold(rect.height, bounds.height);
      if (!visible) {
        _mentionVisibleSince.remove(id);
        continue;
      }
      final since = _mentionVisibleSince.putIfAbsent(id, () => now);
      if (now.difference(since) >= const Duration(milliseconds: 500)) {
        changed = state.markViewed(id) || changed;
      }
    }
    if (changed) {
      unawaited(widget.roomLease.saveMentions());
      _mentionRevision.value++;
    }
  }

  Future<void> _ingestMentions() async {
    if (!isGroup || widget.roomLease.canceled) return;
    await widget.roomLease.ingestMentions();
  }

  late final VoiceTranscriber voiceTranscriber =
      widget.voiceTranscriber ?? SpeechToTextVoiceTranscriber();
  // 语音模式：按住说话录音状态机 + 60 秒上限自动发送。
  final voiceRecording = VoiceRecordingController();
  MediaMessageService? voiceService;
  Timer? _voiceMaxTimer;
  Timer? _voiceTicker;
  DateTime? _voiceStartedAt;
  Duration _voiceElapsed = Duration.zero;
  RoomTimelineController? controller;

  LocalHiddenEvents? hiddenEvents;
  final mentionDraft = MentionDraft();

  /// 规格#3：统一提及模型（范围式 token 替换，修复双 @）。
  /// mentionDraft 仅保留给既有测试路径兼容，发送侧以本模型为准。
  final mentionComposer = MentionComposerModel();
  String _lastComposerText = '';
  final menuLinks = <String, LayerLink>{};
  final menuAnchorKeys = <String, GlobalKey>{};
  OverlayEntry? actionMenuEntry;
  RoomMessageViewModel? replyingTo;
  String? _selectedReplyExcerpt;
  MatrixEmojiVault? emojiVault;
  List<CustomEmojiItem> customEmojiItems = const [];
  MessageReminderService? reminderService;
  String nudgeSuffix = '';
  Map<String, ContactDetails> contactsByMatrixId = const {};
  ProfileData? ownProfile;
  late final ProfileRepository _identityCache =
      widget.initialIdentityCache ?? ProfileRepository(widget.api);

  /// Offline First：本房间的持久化出站队列（可注入；组合根写入 shared）。
  PersistentOutboxManager? get _outbox =>
      widget.outbox ?? PersistentOutboxManager.shared;

  /// 本房间的发送日志（房间号 + 接收方在这里绑定一次）。
  late final OutboxJournal? _outboxJournal = _buildOutboxJournal();

  /// 注册到发送句柄注册表，供调度器在网络恢复时把持久化行交回本会话发送。
  _RoomOutboxSender? _outboxSender;
  PersistentOutboxManager? _observedOutbox;

  void _outboxChanged() {
    if (!mounted || _disposing || widget.roomLease.canceled) return;
    unawaited(controller?.reconcileOutboxStatuses().catchError((Object _) {}));
  }

  OutboxJournal? _buildOutboxJournal() {
    final outbox = _outbox;
    if (outbox == null) return null;
    if (_outboxReceiverId == roomInfo.id) {
      return outbox.journalFor(
          roomId: roomInfo.id, receiverId: _outboxReceiverId);
    }
    return RoomOutboxJournal(
        manager: outbox,
        roomId: null,
        receiverId: _outboxReceiverId,
        beforeClaim: (localId) async {
          var row = await outbox.store.byLocalId(localId);
          if (row == null || !mounted || _disposing) return false;
          if (row.roomId == null) {
            final contact =
                _identityCache.contactsByMatrixId[_outboxReceiverId] ??
                    widget.initialContact;
            final resolver = widget.resolveDirectSendTarget;
            if (resolver == null && contact == null) {
              throw StateError('当前不可发送消息');
            }
            final String canonical;
            try {
              canonical = resolver != null
                  ? await resolver(_outboxReceiverId)
                  : await widget.api.canonicalDirectRoomId(contact!.userId) ??
                      await widget.api.registerDirectConversation(
                          contact.userId, roomInfo.id);
            } on DirectRoomPendingException {
              await outbox.updateStatus(localId, OutboxStatus.waitingNetwork,
                  lastError: 'conversation_recovery_pending');
              widget.requestOutboxDrain?.call();
              return false;
            }
            if (!mounted || _disposing || widget.roomLease.canceled) {
              return false;
            }
            await outbox.bindRoomForReceiver(_outboxReceiverId, canonical,
                localIds: [localId]);
            row = await outbox.store.byLocalId(localId);
            if (canonical != roomInfo.id) {
              widget.onDirectTargetChanged?.call(canonical);
            }
          }
          if (row?.roomId != roomInfo.id) {
            widget.requestOutboxDrain?.call();
            return false;
          }
          return true;
        });
  }

  Future<bool> _prepareNewDirectOperation() async {
    if (isGroup || widget.resolveDirectSendTarget == null) return true;
    try {
      final target = await widget.resolveDirectSendTarget!(_outboxReceiverId);
      if (!mounted || _disposing || widget.roomLease.canceled) return false;
      if (target == roomInfo.id) return true;
      widget.onDirectTargetChanged?.call(target);
      _showMediaMessage('连接已恢复，请重试刚才的操作');
    } catch (_) {
      if (mounted && !_disposing) _showMediaMessage('会话暂时无法发送，请稍后重试');
    }
    return false;
  }

  /// 接收方：单聊取对端 Matrix 用户 ID（房间信息 → 身份缓存 → 入口联系人），
  /// 群聊取房间 ID。入口联系人兜底保证 pending conversation 绑定过的行一定
  /// 能被本房间认领。
  String get _outboxReceiverId =>
      roomInfo.directPeerId ??
      peer?.matrixUserId ??
      widget.initialContact?.matrixUserId ??
      roomInfo.id;
  late SupportIdentityRepository _supportIdentities;
  Timer? _supportTimer;
  /// E2：金融卡片缓存提升到会话级（进程共享、会话失效才重建），
  /// 每次进入房间不再清零重拉——气泡状态稳定不闪烁（微信式机制）。
  late final FinanceCardStore _financeCardStore =
      sessionFinanceCardStore(() => BusinessFinanceCardGateway(widget.api));
  ContactDetails? peer;
  bool loading = true;

  // Camera capture and automatic video preparation state.
  bool _capturingVideo = false;

  /// 视频发送阶段（转码→加密→上传→发送事件；转码有真实进度，
  /// 其余阶段按 SDK 上传伪事件状态显示）。
  ComposerPanel composerPanel = ComposerPanel.none;
  String? errorMessage;
  String? mediaMessage;
  Timer? mediaMessageTimer;
  OverlayEntry? _nudgeToast;
  Timer? _nudgeToastTimer;
  FlashPhotoViewedStore? _flashViewed;
  bool mediaMessageVisible = false;

  /// 「拍摄」自动发送时的暂存缩略图（200px），随发送横幅一并展示。
  late int joinedMemberCount;
  late final announcementService = widget.roomLease.openAnnouncementService();
  String? highlightedMessageId;

  /// “回到引用位置”弹窗目标：引用发起消息的事件 ID。
  /// 点击引用跳转成功后置位；点击弹窗返回发起消息并清空。
  String? quoteReturnMessageId;

  bool get isGroup => !roomInfo.isDirect;

  @override
  void initState() {
    super.initState();
    MessageTextSelectionSession.dismissActive();
    callAudioActivity.addListener(_handleCallAudioActivity);
    widget.roomLease.bindOwnerDrain(_drainMatrixOperations);
    widget.navigationRequests?.addListener(_onNavigationRequest);
    roomInfo = widget.roomLease.roomInfo;
    _supportIdentities = SupportIdentityRepository(widget.api);
    peer = widget.initialContact;
    joinedMemberCount = _joinedMembers.length;
    ownProfile = _identityCache.profile;
    contactsByMatrixId = _identityCache.contactsByMatrixId;
    _identityCache.addListener(_identityChanged);
    input.addListener(_handleComposerChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restoreDraft());
    // 上滑接近顶部时自动加载更早的历史消息（顶部有加载/结束提示）。
    messageScrollController.addListener(_onMessageScroll);
    // 未读状态机（BUG 5）：本房间进入"查看中"，收到新消息不计未读。
    ConversationReadState.shared().setRoomOpen(roomInfo.id, open: true);
    unawaited(_identityCache.preload().catchError((_) {}));
    final supportPeerId = roomInfo.directPeerId ?? peer?.matrixUserId;
    if (!isGroup && supportPeerId != null) {
      unawaited(_supportIdentities.warm([supportPeerId]));
      _supportTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        unawaited(_supportIdentities.warm([supportPeerId], force: true));
      });
    }
    unawaited(_trackMatrixOperation(_refreshJoinedMemberCount()));
    unawaited(
        FlashPhotoViewedStore.load('matrix:${roomInfo.currentUserId ?? ''}')
            .then((store) {
      if (!mounted) return;
      setState(() => _flashViewed = store);
    }));
    // 聊天工具：幂等注册「统计助手」。
    // 「当前可见会话」作用域栈（StatisticsRoomScope）**不再由页面维护**：
    // 它属于房间打开流程，由组合根在 register/release 时统一登记与释放
    // （AppHome._openManagedRoomRoute），避免会话状态出现第二个真相源。
    ensureStatisticsToolRegistered();
    unawaited(_trackMatrixOperation(_load()));
  }

  @override
  void didUpdateWidget(covariant RoomPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.api, widget.api)) {
      _supportIdentities.dispose();
      _supportIdentities = SupportIdentityRepository(widget.api);
      if (!isGroup && roomInfo.directPeerId != null) {
        unawaited(_supportIdentities.warm([roomInfo.directPeerId]));
      }
    }
  }

  /// WeChat opens the 「选择提醒的人」 panel when a group message ends with a
  /// freshly typed "@" and closes it again as soon as the text moves on.
  void _handleComposerChanged() {
    // R3 修复：程序化更新（_insertMention/appendMentionDraft）期间跳过——
    // 它们已同步模型与 _lastComposerText，此处再差分会把同次编辑应用两次。
    if (_programmaticComposerEdit) return;
    // 规格#3：差分同步 + 新 @ 触发记录。
    final next = input.text;
    if (next != _lastComposerText) {
      final (start, removed, inserted) = MentionComposerModel.diffEdit(
        _lastComposerText,
        next,
      );
      mentionComposer.text = next;
      mentionComposer.applyEdit(
        start: start,
        removed: removed,
        inserted: inserted,
      );
      final cursor = input.selection.baseOffset;
      if (inserted > 0 && cursor > 0 && cursor <= next.length) {
        final insertedEnd = start + inserted;
        if (insertedEnd == cursor &&
            next.codeUnitAt(cursor - 1) == 0x40 /* @ */) {
          mentionComposer.triggerAt(cursor - 1);
        }
      }
      _lastComposerText = next;
      _saveDraft();
    }
    // 光标范围检查移到文本差分**之外**：仅移动光标（文本不变）时
    // 监听器仍触发（selection 通知），面板应正确关闭（R6 三审修复）。
    {
      final cursor = input.selection.baseOffset;
      final trigger = mentionComposer.pendingTriggerStart;
      if (trigger != null && cursor >= 0) {
        final inQueryRange = cursor > trigger && cursor <= next.length;
        if (!inQueryRange) {
          mentionComposer.pendingTriggerStart = null;
        }
      }
    }
    final shouldShow = isGroup && mentionComposer.pendingTriggerStart != null;
    if (mounted && shouldShow != (composerPanel == ComposerPanel.mention)) {
      setState(() {
        composerPanel = shouldShow ? ComposerPanel.mention : ComposerPanel.none;
      });
    }
  }

  /// R3 修复：程序化更新输入框期间置 true，监听器跳过差分。
  bool _programmaticComposerEdit = false;

  /// 程序化更新输入框（面板选中/长按头像）：同步模型、token、
  /// _lastComposerText 与 TextEditingController，不经过监听器差分。
  void _setComposerText(String text, int caret) {
    _programmaticComposerEdit = true;
    try {
      input
        ..text = text
        ..selection = TextSelection.collapsed(offset: caret);
      _lastComposerText = text;
      mentionComposer.text = text;
    } finally {
      _programmaticComposerEdit = false;
    }
    _saveDraft();
  }

  List<MentionOption> _mentionMembers() {
    final selfId = roomInfo.currentUserId;
    final options = <MentionOption>[];
    for (final member in _joinedMembers) {
      if (member.id == selfId) continue;
      final identity = _identityCache.resolveIdentity(
          matrixUserId: member.id, displayName: member.displayName);
      final nickname = identity.publicDisplayName;
      final remark = contactsByMatrixId[member.id]?.remark?.trim() ?? '';
      options.add(MentionOption(
        id: member.id,
        primaryName: identity.displayName,
        nickname: nickname,
        hasRemark: remark.isNotEmpty,
      ));
    }
    return options;
  }

  /// 「@所有人」 is pinned for the group owner and administrators only,
  /// mirroring the group-info role resolution (custom account data first,
  /// then the room creation event).
  bool get _canMentionAll {
    if (!isGroup) return false;
    final myId = roomInfo.currentUserId;
    if (myId == null) return false;
    return roomInfo.canMentionAll;
  }

  void _insertMention(MentionOption option) {
    // 规格#3：替换触发范围为一个 token（不再追加双 @）。
    final cursor = input.selection.baseOffset;
    final caret = option.isAll
        ? mentionComposer.replaceTrigger(
            displayName: option.publicName,
            userId: '@all',
            cursor: cursor < 0 ? null : cursor,
            mentionAllUserIds: [
              for (final member in _joinedMembers)
                if (member.id != roomInfo.currentUserId) member.id,
            ],
          )
        : mentionComposer.replaceTrigger(
            displayName: option.publicName,
            userId: option.id,
            cursor: cursor < 0 ? null : cursor,
          );
    // R3 修复：经统一程序化更新（不走监听器差分，防同次编辑二次应用）。
    _setComposerText(mentionComposer.text, caret);
    setState(() {
      composerPanel = ComposerPanel.none;
    });
  }

  Future<void> _refreshJoinedMemberCount() async {
    if (!isGroup) return;
    try {
      final refreshed = await widget.roomLease.refreshRoomInfo();
      if (!mounted) return;
      roomInfo = refreshed;
      final count = _joinedMembers.length;
      if (mounted) setState(() => joinedMemberCount = count);
    } catch (_) {
      // Preserve the synchronized local count if a transient member request
      // fails; the next room sync refreshes the title.
    }
  }

  Future<int> _refreshJoinedMemberCountForRedPacket() async {
    final epoch = widget.api.sessionEpoch;
    final refreshed = await widget.roomLease.refreshRoomInfo();
    if (!mounted ||
        widget.roomLease.canceled ||
        widget.api.sessionEpoch != epoch) {
      throw StateError('群成员状态已失效');
    }
    final count =
        redPacketJoinedMemberCount(refreshed.members, refreshed.currentUserId);
    roomInfo = refreshed;
    if (mounted) setState(() => joinedMemberCount = count);
    return count;
  }

  /// 群聊收款人/专属红包成员：实时拉取当前房间已加入成员。
  ///
  /// 只包含本会话成员，绝不含通讯录好友；好友备注与业务身份来自身份缓存，
  /// Matrix 头像与业务头像分别保留，供两种头像解析路径使用。
  Future<List<GroupMemberIdentity>> _liveGroupMemberIdentities() async {
    final epoch = widget.api.sessionEpoch;
    final refreshed = await widget.roomLease.refreshRoomInfo();
    if (!mounted ||
        widget.roomLease.canceled ||
        widget.api.sessionEpoch != epoch) {
      throw StateError('群成员状态已失效');
    }
    roomInfo = refreshed;
    final identity = _identityCache;
    return [
      for (final member in refreshed.members)
        if (member.isJoined && member.id != refreshed.currentUserId)
          _groupMemberIdentity(member, identity),
    ];
  }

  GroupMemberIdentity _groupMemberIdentity(
    MatrixRoomMemberSnapshot member,
    ProfileRepository identity,
  ) {
    final contact = identity.contactsByMatrixId[member.id];
    return GroupMemberIdentity(
      matrixUserId: member.id,
      displayName: identity
          .resolveIdentity(
            matrixUserId: member.id,
            displayName: member.displayName,
          )
          .displayName,
      matrixAvatarUri: member.avatarUri,
      businessUserId: contact?.userId,
      businessAvatarUrl: contact?.avatarUrl,
    );
  }

  String get _navigationTitle => isGroup
      ? groupRoomNavigationTitle(roomInfo.name, joinedMemberCount)
      : directRoomNavigationTitle(
          peerMatrixUserId: roomInfo.directPeerId,
          contactsByMatrixId: contactsByMatrixId,
          fallbackRoomName: widget.roomName,
        );

  void _identityChanged() {
    if (!mounted) return;
    final mapped = _identityCache.contactsByMatrixId;
    setState(() {
      contactsByMatrixId = mapped;
      ownProfile = _identityCache.profile ?? ownProfile;
      final peerId = roomInfo.directPeerId;
      // A repository notification is an updated contact snapshot. Retaining
      // initialContact here would keep deleted-friend actions reachable.
      if (!isGroup && peerId != null) peer = mapped[peerId];
    });
  }

  RoomTimelineCapability? _logicalTimeline;

  void _onNavigationRequest() {
    final request = widget.navigationRequests?.value;
    final event = request?.anchorEventId;
    if (event != null && controller != null) {
      unawaited(_navigateToLogicalAnchor(event, request!.anchorRoomId));
    }
  }

  Future<void> _navigateToLogicalAnchor(String event, String? source) async {
    try {
      if (source != null) {
        await widget.roomLease.hintLogicalEventSource(event, source);
      }
      if (!mounted || _disposing) return;
      await _scrollToMessage(event);
    } catch (_) {
      if (mounted && !_disposing) {
        await _showError('消息暂时无法定位');
      }
    }
  }

  Future<void> _load() async {
    try {
      final accountId = roomInfo.currentUserId;
      if (accountId == null) throw StateError('Matrix 账号尚未登录');
      hiddenEvents = SharedPreferencesLocalHiddenEvents(
        preferences: await SharedPreferences.getInstance(),
        accountId: accountId,
      );
      if (isGroup) {
        unreadMentions = await widget.roomLease.openMentions();
        if (!mounted) return;
        RoomMentionStore.shared.addListener(_mentionStateChanged);
        unawaited(widget.roomLease.scanMentions());
      }
      final timeline =
          // Timeline 分页策略（优化 4）：初始窗口直读 Matrix 本地 DB
          // （不等待服务器）；历史分页 requestHistory 默认 30 条/页
          // （Room.defaultHistoryCount，处于 30~50 规范区间），
          // 由上滑接近顶部时按页追加（见 _onMessageScroll）。
          await widget.roomLease.openLogicalRoomTimeline(
        anchorRoomId: widget.navigationRequests?.value.anchorRoomId ??
            widget.initialAnchorRoomId,
        anchorEventId: widget.navigationRequests?.value.anchorEventId ??
            widget.initialAnchorEventId,
        onUpdate: () {
          _scheduleRoomMetadataRefresh();
          controller?.setHiddenFilter(hiddenEvents?.readFilter(roomInfo.id));
          controller?.scheduleRefresh();
        },
      );
      if (!mounted) {
        timeline.dispose();
        return;
      }
      _logicalTimeline = timeline;
      controller = RoomTimelineController(
        windowed: true,
        // 规格§二：服务层权威权限门（UI 之外的第二道，删除好友/拉黑后
        // 发送必失败，消息进入本地 failed 状态）。拉黑状态取自业务 API
        // 投影（GET /blocks + 本地立即更新），不做写死放行。
        canSendNow: () =>
            !widget.readOnly &&
            InteractionPermission.resolve(
              isFriend: _peerIsFriend(),
              isBlocked: blockedContacts.isBlocked(_peerUserId()),
            ).canSendMessage(),
        // Offline First：发送前先落盘；重试/重启复用同一 txid。
        outboxJournal: _outboxJournal,
        outboxRoomId: roomInfo.id,
        MatrixRoomTimelineAdapter(timeline),
      )..addListener(_changed);
      _observedOutbox = _outbox;
      _observedOutbox?.addListener(_outboxChanged);
      // 调度器只有在房间已打开时才允许派发持久化行；句柄随页面销毁注销。
      final sender = _RoomOutboxSender(this);
      _outboxSender = sender;
      OutboxRoomSenderRegistry.shared.register(sender);
      controller!.setHiddenFilter(hiddenEvents?.readFilter(roomInfo.id));
      replyResolver?.dispose();
      replyResolver = ReplyMessageResolver(
        lookup: (eventId) =>
            controller?.lookupReplyMessage(eventId) ?? Future.value(null),
        onChanged: _replyResolutionChanged,
      );
      await controller!.refresh();
      await _ingestMentions();
      if (!mounted) return;
      _mentionVisibilityTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => _observeVisibleMentions(),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) => _prefetchHistory());
      setState(() => loading = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          errorMessage = '会话加载失败，请检查网络后重试';
        });
      }
      return;
    }
    // The SDK's local timeline and privacy gates are ready. Optional network
    // work must neither hide that history nor serialize unrelated features.
    if (!mounted || widget.roomLease.canceled) return;
    _syncReadReceiptWhileViewing(immediate: true);
    unawaited(_trackMatrixOperation(_loadEmojiVault()));
    unawaited(_trackMatrixOperation(_loadReminderService()));
    unawaited(_trackMatrixOperation(_loadIdentities()));
    unawaited(_flushInitialOutbox());
  }

  /// Offline First：把 pending conversation 期间排队 / 上次进程遗留的消息
  /// 按顺序重新接回发送路径。
  ///
  /// 两点必须同时成立：
  /// 1. **持久化行优先**：房间号已绑定的 `queued` / `waitingNetwork` 行用
  ///    行内 txid 派发（幂等，绝不重新生成 txid）；
  /// 2. **原文兜底且不重复**：`initialOutbox` 里没有对应持久化行的文本
  ///    （持久层不可用等降级路径）才走"新建发送"，按内容多重集逐个抵扣，
  ///    不会把同一条消息发两次。
  ///
  /// 服务端明确拒绝过的 `failed` 行只恢复展示（红色感叹号 + 点击重试），
  /// 绝不自动重发。
  Future<void> _flushInitialOutbox() async {
    if (widget.readOnly) return;
    final outbox = _outbox;
    final controller = this.controller;
    if (controller == null) return;
    if (outbox == null) {
      await _sendRawOutboxTexts(controller, _trimmedInitialOutbox());
      return;
    }
    // 1) 先把本会话接收方还没有房间号的行绑定到本房间（幂等）：用户可能在
    //    pending conversation 里离线输入后杀掉进程，重开时由这里接手。
    // New direct messages bind only after canonical verification in the journal.
    if (!mounted || widget.roomLease.canceled) return;
    // 2) 读取本房间所有未送达行（queued / waitingNetwork / failed）。
    var rows = <OutboxMessage>[];
    try {
      final sources = widget.roomLease.owner
          .logicalRoomSourcesSync(roomInfo.id)
          .toSet()
        ..add(roomInfo.id);
      for (final source in sources) {
        rows.addAll(await outbox.store.query(
            unsent: true,
            roomId: source,
            accountId: outbox.accountId.isEmpty ? null : outbox.accountId));
      }
      if (_outboxReceiverId != roomInfo.id) {
        rows.addAll((await outbox.store.query(
                unsent: true,
                receiverId: _outboxReceiverId,
                accountId: outbox.accountId.isEmpty ? null : outbox.accountId))
            .where((row) => row.roomId == null));
      }
      rows.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    } catch (_) {
      rows = const <OutboxMessage>[];
    }
    if (!mounted || widget.roomLease.canceled) return;
    // 3) 原文兜底：抵扣掉已经由持久化行拥有的内容。
    final orphaned = textsWithoutOutboxRows(
        texts: widget.initialOutboxLocalIds.isEmpty
            ? widget.initialOutbox
            : const [],
        rows: rows);
    await _sendRawOutboxTexts(controller, orphaned);
    if (!mounted || widget.roomLease.canceled) return;
    // 4) 持久化行：失败的只恢复展示，其余用原 txid 派发。
    for (final row in rows) {
      if (!mounted || widget.roomLease.canceled) return;
      if ((row.roomId != null && row.roomId != roomInfo.id) ||
          row.status == OutboxStatus.failed) {
        controller.restoreOutboxMessage(row);
        continue;
      }
      try {
        await _trackMatrixOperation(
          controller.sendText(row.content, outboxRow: row),
        );
      } catch (_) {
        // 发送失败由气泡状态呈现（等待发送/失败 + 重试），这里不吞掉信息。
      }
    }
  }

  List<String> _trimmedInitialOutbox() => <String>[
        for (final text in widget.initialOutbox)
          if (text.trim().isNotEmpty) text.trim(),
      ];

  /// 认领本会话接收方"还没有房间号"的持久化行（幂等）。
  /// 降级路径：没有持久化行的原文按顺序新建发送。
  Future<void> _sendRawOutboxTexts(
      RoomTimelineController controller, List<String> texts) async {
    for (final text in texts) {
      if (!mounted || widget.roomLease.canceled) return;
      try {
        await _trackMatrixOperation(controller.sendText(text));
      } catch (_) {
        // 同上：状态由气泡呈现。
      }
    }
  }

  Future<void> _loadIdentities() async {
    try {
      await _identityCache.preload();
      final contacts = _identityCache.contacts;
      final profile = _identityCache.profile;
      final mapped = _identityCache.contactsByMatrixId;
      final participantIds = roomInfo.members
          .map((participant) => participant.id)
          .where((id) => id != roomInfo.currentUserId)
          .toSet();
      ContactDetails? resolvedPeer;
      for (final contact in contacts) {
        if (participantIds.contains(contact.matrixUserId)) {
          resolvedPeer = contact.toDetails();
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        contactsByMatrixId = mapped;
        ownProfile = profile ?? ownProfile;
        peer ??= resolvedPeer;
      });
    } catch (_) {
      // The encrypted timeline remains usable when optional profile metadata
      // is temporarily unavailable. Avatar and name fallbacks stay local.
    }
  }

  Future<void> _loadEmojiVault() async {
    try {
      final session = await MatrixEmojiVault.open(
        await widget.roomLease.openEmojiVaultBackend(),
      );
      final items = <CustomEmojiItem>[];
      for (final item in session.vault.items) {
        items.add(
          CustomEmojiItem(
            id: item.id,
            loadPreview: () => session.loadPreview(item),
            isAnimated: item.isAnimated,
            mimeType: item.mimeType,
          ),
        );
      }
      if (!mounted) return;
      setState(() {
        emojiVault = session;
        customEmojiItems = items;
      });
      unawaited(_refreshEmojiVault(session));
    } catch (_) {
      if (mounted) setState(() => mediaMessage = '我的表情同步失败，可稍后重试');
    }
  }

  Future<void> _refreshEmojiVault(MatrixEmojiVault session) async {
    try {
      await session.refresh();
      if (!mounted || !identical(emojiVault, session)) return;
      setState(() => customEmojiItems = [
            for (final item in session.vault.items)
              CustomEmojiItem(
                  id: item.id,
                  isAnimated: item.isAnimated,
                  mimeType: item.mimeType,
                  loadPreview: () => session.loadPreview(item)),
          ]);
    } catch (_) {
      // Keep the cached favorites usable when background metadata sync fails.
    }
  }

  Future<void> _loadReminderService() async {
    reminderService = widget.reminderService;
  }

  Future<void> _addMessageToEmoji(RoomMessageViewModel message) async {
    final session = emojiVault;
    final timeline = controller;
    if (session == null || timeline == null) {
      setState(() => mediaMessage = '表情仓库尚未就绪');
      return;
    }
    try {
      final bytes = await timeline.loadAttachment(message.id);
      final item = await session.vault.add(
        bytes,
        mimeType: message.mimeType ?? 'image/png',
      );
      final custom = CustomEmojiItem(
        id: item.id,
        loadPreview: () => session.loadPreview(item),
        isAnimated: item.isAnimated,
        mimeType: item.mimeType,
      );
      if (!mounted) return;
      setState(() {
        customEmojiItems = [
          custom,
          ...customEmojiItems.where((existing) => existing.id != item.id),
        ];
        mediaMessage = '已添加到我的表情';
      });
    } catch (_) {
      if (mounted) setState(() => mediaMessage = '添加表情失败，请重试');
    }
  }

  Future<void> _sendCustomEmoji(CustomEmojiItem item) async {
    if (!await _prepareNewDirectOperation()) return;
    final session = emojiVault;
    final timeline = controller;
    if (session == null || timeline == null) return;
    setState(() => composerPanel = ComposerPanel.none);
    final matrix = widget.roomLease;
    await timeline.sendText(
      '[表情消息]',
      kind: RoomMessageKind.image,
      mimeType: item.mimeType,
      send: (txid) => _enqueueMedia(() async {
        final original =
            session.vault.items.firstWhere((entry) => entry.id == item.id);
        final bytes = await session.loadBytes(original);
        validateGifStructureForSend(bytes);
        roomImagePreviewCache.seed(txid, bytes);
        final result = await _cacheSentImage(
            bytes,
            matrix.sendEncryptedMedia(roomInfo.id, bytes,
                isGifBytes(bytes) ? 'image/gif' : item.mimeType,
                txid: txid,
                filename: item.isAnimated ? '畅聊表情.gif' : '畅聊表情.png'));
        unawaited(session.vault.markRecent(item.id).catchError((_) {}));
        return result;
      }),
    );
  }

  Future<void> _removeCustomEmoji(CustomEmojiItem item) async {
    final session = emojiVault;
    if (session == null) throw StateError('Emoji vault unavailable');
    await session.removeItem(item.id);
    if (mounted) {
      setState(() {
        customEmojiItems =
            customEmojiItems.where((entry) => entry.id != item.id).toList();
      });
    }
  }

  Future<void> _sendNudge(
    RoomMessageViewModel message,
    String targetDisplayName,
  ) async {
    final sender = ownProfile;
    final senderId = roomInfo.currentUserId;
    final sessionEpoch = widget.api.sessionEpoch;
    if (sender == null || senderId == null) return;
    final reservation = NudgeRateLimiter.shared
        .reserve(senderId: senderId, roomId: roomInfo.id);
    if (reservation == null) {
      _showNudgeToast('拍一拍太频繁，请稍后再试');
      return;
    }
    try {
      // The profile service is authoritative for a sender's nudge suffix.
      // Refresh it at send time so a just-saved profile setting is used by
      // already-open conversations as well.
      final latestProfile = await widget.api.loadProfile();
      if (!mounted ||
          widget.roomLease.canceled ||
          widget.api.sessionEpoch != sessionEpoch ||
          roomInfo.currentUserId != senderId) {
        NudgeRateLimiter.shared.release(reservation);
        return;
      }
      if (mounted) {
        setState(() {
          ownProfile = latestProfile;
          nudgeSuffix = latestProfile.nudgeSuffix ?? '';
        });
      }
      await NudgeService(
        backend: widget.roomLease,
        roomId: roomInfo.id,
        senderId: senderId,
        senderDisplayName: sender.nickname,
      ).send(
        targetUserId: message.senderId,
        targetDisplayName: targetDisplayName,
        suffix: message.senderId == senderId
            ? (latestProfile.nudgeSuffix ?? '')
            : (contactsByMatrixId[message.senderId]?.nudgeSuffix ?? ''),
      );
    } catch (_) {
      NudgeRateLimiter.shared.release(reservation);
      _showNudgeToast('拍一拍发送失败，请重试');
    }
  }

  void _showNudgeToast(String message) {
    if (!mounted) return;
    _nudgeToastTimer?.cancel();
    _nudgeToast?.remove();
    final overlay = Overlay.of(context, rootOverlay: true);
    _nudgeToast = OverlayEntry(
      builder: (_) => Positioned(
        left: 24,
        right: 24,
        bottom: 96,
        child: IgnorePointer(
            child: Center(
                child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: WeChatToast(
              key: const Key('room-nudge-toast'),
              message: message,
              semanticType: WeChatToastSemanticType.error),
        ))),
      ),
    );
    overlay.insert(_nudgeToast!);
    _nudgeToastTimer = Timer(const Duration(seconds: 3), () {
      _nudgeToast?.remove();
      _nudgeToast = null;
    });
  }

  Future<void> _showReminderPicker(RoomMessageViewModel message) async {
    final service = reminderService;
    if (service == null) {
      setState(() => mediaMessage = '提醒同步尚未就绪，请稍后重试');
      return;
    }
    var selected = DateTime.now().add(const Duration(hours: 1));
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => Container(
        height: 360,
        color: CupertinoTheme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              SizedBox(
                height: 52,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CupertinoButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Text('取消'),
                    ),
                    const Text(
                      '选择提醒时间',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    CupertinoButton(
                      key: const Key('reminder-confirm'),
                      onPressed: () async {
                        try {
                          await service.create(
                            roomId: roomInfo.id,
                            eventId: message.id,
                            dueAt: selected,
                          );
                          if (!sheetContext.mounted) return;
                          Navigator.pop(sheetContext);
                          if (mounted) setState(() => mediaMessage = '提醒已设置');
                        } catch (_) {
                          if (mounted) {
                            setState(() => mediaMessage = '提醒设置失败，请重试');
                          }
                        }
                      },
                      child: const Text('完成'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.dateAndTime,
                  initialDateTime: selected,
                  minimumDate: DateTime.now(),
                  use24hFormat: true,
                  onDateTimeChanged: (value) => selected = value,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _metadataRefreshScheduled = false;
  void _scheduleRoomMetadataRefresh() {
    if (_metadataRefreshScheduled || _disposing) return;
    _metadataRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metadataRefreshScheduled = false;
      if (!mounted || _disposing || widget.roomLease.canceled) return;
      final next = widget.roomLease.roomInfo;
      var changed = next.name != roomInfo.name ||
          next.canMentionAll != roomInfo.canMentionAll ||
          next.members.length != roomInfo.members.length;
      if (!changed) {
        for (var i = 0; i < next.members.length; i++) {
          final a = next.members[i];
          final b = roomInfo.members[i];
          if (a.id != b.id ||
              a.displayName != b.displayName ||
              a.avatarUri != b.avatarUri ||
              a.isJoined != b.isJoined ||
              a.powerLevel != b.powerLevel) {
            changed = true;
            break;
          }
        }
      }
      roomInfo = next;
      if (changed) setState(() => joinedMemberCount = _joinedMembers.length);
    });
  }

  void _changed() {
    if (_disposing || !mounted) return;
    unawaited(_ingestMentions());
    _applyInitialAnchorIfNeeded();
    _recordGlobalSearchIndex();
    final timeline = controller;
    // Sending switches to the latest window and publishes a local bubble before
    // SDK acknowledgment. Scroll to that bubble even while transport is pending.
    // Read receipts below continue to use the authoritative SDK newest message.
    final latest = timeline != null &&
            !timeline.hasLaterWindow &&
            timeline.messages.isNotEmpty
        ? timeline.messages.last
        : timeline?.newestMessage;
    latestMessageAnchor.update(latest?.stableId,
        outgoing: latest?.isOwn ?? false);
    for (final message in controller?.messages ?? <RoomMessageViewModel>[]) {
      if (message.isRecalled) {
        final key = _posterKeys.remove(message.id);
        if (key != null) unawaited(videoPosterCache.evict(key));
        // 撤回：同时丢弃流水线的来源归属/冷却状态，避免残留影响诊断与重试。
        videoPosterPipeline.forget(message.id);
      }
    }
    _timelineRevision.value++;
    _syncReadReceiptWhileViewing();
  }

  Future<void> _retryMessage(RoomMessageViewModel message) async {
    final timeline = controller;
    if (timeline == null) return;
    try {
      await timeline.retry(message.id);
    } catch (_) {
      _showMediaMessage('重发失败，请稍后再试');
    }
  }

  Future<void> _send() async {
    final text = input.text.trim();
    if (text.isEmpty || controller == null) return;
    // R2 修复：先取得正文/回复关系/收件人的**不可变快照**，再清空输入。
    // （input.clear() 同步触发监听器→applyEdit 移除全部 token→
    // recipientUserIds 已空——旧顺序丢失 m.mentions。）
    final reply = replyingTo;
    final replyExcerpt = replyingTo == null ? null : _selectedReplyExcerpt;
    final mentions = mentionComposer.recipientUserIds();
    // 规格取消场景：发送消息即取消文本选区与菜单（若处于选择模式）。
    MessageTextSelectionSession.dismissActive();
    _programmaticComposerEdit = true;
    try {
      input.clear();
      _lastComposerText = '';
      // R6：clearAfterSend 同时清触发状态（未选联系人的 @兄 残留
      // 不再导致下一条普通输入弹面板）。
      mentionComposer.clearAfterSend();
    } finally {
      _programmaticComposerEdit = false;
    }
    if (mounted) {
      setState(() {
        replyingTo = null;
        _selectedReplyExcerpt = null;
      });
    }
    _saveDraft();
    unawaited(RoomDraftStore.shared.flush(_draftKey));
    mentionDraft.clear();
    await controller!.sendText(
      text,
      replyToEventId: reply?.id,
      replyExcerpt: replyExcerpt,
      send: reply == null && mentions.isEmpty
          ? null
          : (transactionId) async => await widget.roomLease.sendMessageContent({
                'msgtype': 'm.text',
                'body': text,
                if (reply != null)
                  'm.relates_to': {
                    'm.in_reply_to': {'event_id': reply.id},
                  },
                if (replyExcerpt != null)
                  'io.changliao.selected_quote': replyExcerpt,
                if (mentions.isNotEmpty) 'm.mentions': {'user_ids': mentions},
              }, txid: transactionId),
    );
  }

  /// 「拍摄」入口：拍摄成功即**自动加密发送**（不进入“查看照片”页）；
  /// 发送期间优先解码 200px 缩略图作为暂存内容先展示，提升发送体验。
  Future<void> _captureAndSendImage() async {
    if (!await _prepareNewDirectOperation()) return;
    final matrix = widget.roomLease;
    final targetRoomId = roomInfo.id;
    final timeline = controller;
    final service = MediaMessageService(matrix, isGroup: isGroup);
    try {
      final captured = await service.captureToFile();
      if (captured == null ||
          timeline == null ||
          !mounted ||
          _disposing ||
          !identical(widget.roomLease, matrix)) {
        return;
      }
      await timeline.sendText('[图片消息]',
          kind: RoomMessageKind.image,
          mimeType: 'image/jpeg',
          send: (txid) => _enqueueMedia(() async {
                await MediaMessageService.ensureWithinSendLimit(File(captured));
                final bytes = await File(captured).readAsBytes();
                roomImagePreviewCache.seed(txid, bytes);
                final thumbnail = await buildChatImageThumbnail(bytes);
                return _cacheSentImage(
                    bytes,
                    matrix.sendEncryptedMedia(targetRoomId, bytes, 'image/jpeg',
                        txid: txid,
                        thumbnailBytes: thumbnail?.bytes,
                        thumbnailWidth: thumbnail?.width,
                        thumbnailHeight: thumbnail?.height));
              }));
    } catch (_) {
      if (mounted) _showMediaMessage('拍摄失败，请重试');
    } finally {
      await service.dispose();
    }
  }

  Future<void> _sendMedia({required bool image}) async {
    if (!await _prepareNewDirectOperation()) return;
    final matrix = widget.roomLease;
    final targetRoomId = roomInfo.id;
    final factory = widget.mediaSenderFactory;
    if (factory != null) {
      final sender = factory(matrix);
      try {
        if (image) {
          await sender.sendImage(targetRoomId);
        } else {
          await sender.sendFile(targetRoomId);
        }
      } finally {
        await sender.dispose();
      }
      return;
    }
    if (image) {
      await _pickAndSendImages();
      return;
    }
    final timeline = controller;
    if (timeline == null) return;
    final service = MediaMessageService(matrix, isGroup: isGroup);
    try {
      final file = await service.pickFileForSend();
      if (file == null ||
          !mounted ||
          _disposing ||
          !identical(widget.roomLease, matrix)) {
        return;
      }
      await service.validateSelectedFile(file);
      final mime =
          file.mimeType == null || file.mimeType == 'application/octet-stream'
              ? mimeFromFileName(file.name)
              : file.mimeType!;
      if (mime.startsWith('video/')) {
        await matrix.enqueueVideoFile(
          jobId: 'file-video-${DateTime.now().microsecondsSinceEpoch}',
          video: MatrixOutgoingVideoFile(
            id: file.path,
            source: File(file.path),
            filename: file.name,
            body: '[视频消息]',
            deleteSourceWhenDone: false,
          ),
          targetRoomIds: [targetRoomId],
        );
        await timeline.showLatest();
        if (mounted && !_disposing && identical(widget.roomLease, matrix)) {
          _showMediaMessage('正在发送');
        }
        return;
      }
      await timeline.sendText(
        file.name,
        kind: mime.startsWith('image/')
            ? RoomMessageKind.image
            : RoomMessageKind.file,
        mimeType: mime,
        send: (txid) => _enqueueMedia(
          () => service.sendSelectedFile(targetRoomId, file, txid: txid),
        ),
      );
    } on GroupVideoTooLargeException catch (error) {
      if (mounted) _showMediaMessage(error.toString());
    } catch (_) {
      if (mounted) _showMediaMessage('文件选择失败，请重试');
    } finally {
      await service.dispose();
    }
  }

  /// 全屏播放视频消息：磁盘缓存优先（二次打开零下载），
  /// 在途去重防双击双载；播放器直接使用缓存文件。
  /// 对端是否仍是好友（身份缓存权威；群聊不适用此门）。
  bool _peerIsFriend() {
    final selfId = roomInfo.currentUserId;
    final peers =
        roomInfo.members.where((m) => m.id != selfId).toList(growable: false);
    if (peers.length != 1) return true; // 群聊/异常：放行（群权限另有体系）
    // 曾打开的会话但已删除好友：身份缓存查无此人 → 非好友。
    return _identityCache.contactsByMatrixId[peers.first.id] != null;
  }

  /// 单聊对端的业务 userId（拉黑状态以业务 userId 为键；群聊返回 null）。
  String? _peerUserId() {
    final selfId = roomInfo.currentUserId;
    final peers =
        roomInfo.members.where((m) => m.id != selfId).toList(growable: false);
    if (peers.length != 1) return null;
    return _identityCache.contactsByMatrixId[peers.first.id]?.userId;
  }

  /// 规格§八：聊天详情页头像 → APP 自己的好友/用户资料页（禁止打开
  /// Matrix Profile）。好友直开；非好友走业务检索（同一 APP 页面）。
  Future<void> _openPeerProfile(String matrixUserId) {
    final member = _member(matrixUserId);
    return openGroupMemberProfile(
      context,
      api: widget.api,
      lookupByMatrixId: widget.api.lookupUserByMatrixId,
      identityCache: _identityCache,
      contactActions: ContactActions(
        onMessage: widget.onMessage,
        onVoice: widget.onVoice,
        onVideo: widget.onVideo,
      ),
      member: GroupChatMember(
        matrixUserId: matrixUserId,
        displayName: member.displayName,
      ),
      selfMatrixUserId: roomInfo.currentUserId,
      friendContact: _identityCache.contactsByMatrixId[matrixUserId],
      onOpenFriendContact: _openContact,
    );
  }

  Future<void> _openVideoViewer(RoomMessageViewModel message) async {
    final localSent = SentVideoLocalRegistry.shared
        .findByTransactionId(message.transactionId);
    // Phase 2：播放期间 pin 本地播放文件——配额淘汰与 GC 都不得删除
    // 正在播放的对象；路由返回后统一释放。
    final pins = <MediaCachePin>[];
    Future<File> loadPlaybackFile() async {
      final file = localSent ??
          await resolveCachedVideoFile(
            loaderCachesContent: true,
            key: _mediaKey(message.id),
            decrypt: () => _downloadMedia(message.id),
          );
      pins.add(MediaCache.pinPath(file.path));
      return file;
    }

    try {
      await Navigator.of(context, rootNavigator: true).push(
        MotionPageRoute(
          fullscreenDialog: true,
          builder: (_) => VideoViewerPage(
            loadFile: loadPlaybackFile,
            initialDuration: message.videoDuration,
            onForward: () => _forwardMessages([message]),
          ),
        ),
      );
    } finally {
      for (final pin in pins) {
        pin.release();
      }
    }
    // 播放后本地已有该视频文件：为之前拿不到封面的消息补一次生成
    // （「后台生成 poster → 生成后更新缓存」）。
    if (!mounted || message.kind != RoomMessageKind.video) return;
    if (!_posterMissing.contains(message.id)) return;
    setState(() {
      _posterRevisions[message.id] = (_posterRevisions[message.id] ?? 0) + 1;
    });
  }

  /// 视频消息封面帧（Phase 1：**绝不为了封面下载整段视频**）。
  ///
  /// 旧实现：事件没有可用缩略图时会 `resolveCachedVideoFile` 把整段视频
  /// 下载+解密到磁盘再抽帧——首屏慢、流量浪费、低端机卡顿。
  /// 新实现全部交给 [VideoPosterPipeline]：
  /// 内存 → 会话磁盘 → 服务端 poster（小图附件）→ 本机持久封面缓存
  /// → 本地已存在视频文件的抽帧 → 占位图。
  Future<Uint8List?> _loadVideoPoster(String messageId) async {
    if (!mounted) return null;
    // 会话缓存键沿用既有键形状（账号|房间|媒体|版本|规格）。
    _posterKeys.putIfAbsent(
        messageId, () => videoPosterPipeline.keyFor(messageId));
    final outcome = await videoPosterPipeline.resolve(messageId);
    if (!mounted) return null;
    if (outcome.hasPoster) {
      _posterMissing.remove(messageId);
    } else {
      _posterMissing.add(messageId);
    }
    return outcome.bytes;
  }

  /// 服务端已有 poster：消息事件自带的加密缩略图附件（≤480px 小图）。
  ///
  /// SDK 在事件确实没有缩略图时直接返回 null（不产生网络请求）；
  /// 事件不在当前 timeline 窗口时抛 StateError，由流水线降级为占位。
  Future<Uint8List?> _loadServerVideoPoster(String messageId) async {
    final timeline = controller;
    if (timeline == null || !mounted) return null;
    return timeline.loadThumbnail(messageId);
  }

  /// 本机持久封面缓存（复用 MediaCache：账号命名空间 + 内容寻址 + 配额 LRU）。
  Future<Uint8List?> _readCachedVideoPoster(String messageId) async {
    final file = await MediaCache.probeCachedObject(
      roomInfo.id,
      videoPosterCacheRefId(messageId),
      accountId: roomInfo.currentUserId ?? '',
    );
    if (file == null) return null;
    try {
      final bytes = await file.readAsBytes();
      // 探测路径不刷新 mtime；这里按 LRU 语义记一次访问。
      await file.setLastModified(DateTime.now());
      return bytes;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _writeCachedVideoPoster(
      String messageId, Uint8List bytes) async {
    if (bytes.isEmpty) return;
    await MediaCache.store(
      roomInfo.id,
      videoPosterCacheRefId(messageId),
      bytes,
      accountId: roomInfo.currentUserId ?? '',
    );
  }

  /// 本地已存在的视频文件（**只探测，绝不下载**）：
  /// ① 发送方本机产物（相册原片，仅当确实存在）；
  /// ② MediaCache 中已落盘的视频对象（离线缓存 / 此前播放已缓存）。
  Future<File?> _findLocalVideoFile(String messageId) async {
    // O(1) 索引查找：绝不遍历 allMessages（大房间会退化成全量扫描）。
    final transactionId = controller?.findMessage(messageId)?.transactionId;
    final sent =
        SentVideoLocalRegistry.shared.findByTransactionId(transactionId);
    if (sent != null) return sent;
    final trusted = _mediaHashes(messageId);
    // 廉价存在性探测：不重算大文件哈希。
    return MediaCache.probeCachedObject(
      roomInfo.id,
      messageId,
      accountId: roomInfo.currentUserId ?? '',
      contentSha256: trusted?.contentSha256,
    );
  }

  bool _isAnimatedImage(RoomMessageViewModel message) =>
      message.mimeType?.toLowerCase().split(';').first.trim() == 'image/gif' ||
      message.text.toLowerCase().endsWith('.gif') ||
      isGifBytes(
          imageMemoryCache.get(_mediaKey(message.id).cacheId) ?? Uint8List(0));

  TrustedMediaHashes? _mediaHashes(String eventId) =>
      widget.roomLease.leaseForEvent(eventId).mediaHashes(eventId);

  MediaCacheKey _mediaKey(String eventId, {bool thumbnail = false}) =>
      widget.roomLease
          .leaseForEvent(eventId)
          .mediaCacheKey(eventId, thumbnail: thumbnail);

  Future<Uint8List> _downloadMedia(String eventId) =>
      controller!.loadAttachment(eventId);

  MediaCacheKey _previewKey(RoomMessageViewModel message) {
    final hashes = _mediaHashes(message.id);
    return _mediaKey(message.id,
        thumbnail:
            !_isAnimatedImage(message) && hashes?.thumbnailSha256 != null);
  }

  Uint8List? _cachedImagePreview(RoomMessageViewModel message) {
    try {
      if (_mediaHashes(message.id) == null) {
        return roomImagePreviewCache.get(message.stableId);
      }
      return contentMediaMemoryCache.get(_previewKey(message).cacheId);
    } on FormatException {
      return null;
    }
  }

  Future<Uint8List?> _readCachedImagePreview(
    RoomMessageViewModel message,
  ) async {
    if (_mediaHashes(message.id) == null) {
      return roomImagePreviewCache.readCached(message.stableId);
    }
    final key = _previewKey(message);
    final cached = contentMediaMemoryCache.get(key.cacheId);
    if (cached != null) return cached;
    final file = await MediaCache.cached(
      key.roomId,
      key.eventId,
      accountId: key.accountId,
      contentSha256: key.contentSha256,
    );
    if (file == null) return null;
    return loadMediaWithCache(key, file.readAsBytes);
  }

  Future<Uint8List> _loadImagePreview(RoomMessageViewModel message) async {
    // 安全不变量：闪照不得经普通预览/磁盘缓存管线加载（会在气泡与专用
    // 查看器里走独立内存缓存，见 MediaMessageAccessPolicy）。
    _mediaPolicyFor(message).assertOrdinaryMediaAllowed('imagePreview');
    if (_mediaHashes(message.id) != null) {
      final key = _previewKey(message);
      if (key.eventId.startsWith('thumb:')) {
        final bytes = await controller!.loadThumbnail(message.id);
        if (bytes == null) {
          throw const FormatException('Missing declared thumbnail');
        }
        return bytes;
      }
      return controller!.loadAttachment(message.id);
    }
    return roomImagePreviewCache.load(
      message.stableId,
      () => loadChatImagePreview(
        animated: _isAnimatedImage(message),
        loadThumbnail: () => controller!.loadThumbnail(message.id),
        loadOriginal: () => imageMemoryCache.putIfAbsent(
          _mediaKey(message.id).cacheId,
          () => controller!.loadAttachment(message.id),
        ),
      ),
    );
  }

  /// 闪照发送：事件内容带 flash=1；不上传压缩缩略演绎版（接收端
  /// 只见马赛克），也不写入明文预览缓存；本地回显原图走内存缓存。
  Future<void> _sendFlashPhoto(
    GalleryPhoto photo,
    RoomTimelineController timeline,
  ) async {
    final matrix = widget.roomLease;
    setState(() {
      composerPanel = ComposerPanel.none;
      mediaMessage = null;
    });
    await timeline.sendText(
      '[闪照]',
      kind: RoomMessageKind.image,
      mimeType: photo.mimeType,
      isFlashPhoto: true,
      send: (transactionId) {
        return _cacheSentImage(
          null,
          _enqueueMedia(() async {
            final prepared = await prepareGalleryMedia(photo,
                original: true, isGroup: isGroup);
            // 发送端原图仅驻留内存（马赛克渲染与长按查看复用）。
            await imageMemoryCache.putIfAbsent(
              _mediaKey(transactionId).cacheId,
              () async => prepared.bytes,
            );
            return matrix.sendEncryptedMedia(
              roomInfo.id,
              prepared.bytes,
              prepared.mimeType,
              extraContent: const {'flash': '1'},
              txid: transactionId,
              filename: '闪照.jpg',
            );
          }),
        );
      },
    );
  }

  /// 统一图片选择页（微信式九宫格多选）：默认发送压缩图，
  /// "原图"开关打开后逐张发送原图；逐张加密上传。
  Future<void> _pickAndSendImages() async {
    if (!await _prepareNewDirectOperation()) return;
    if (!mounted) return;
    final matrix = widget.roomLease;
    final targetRoomId = roomInfo.id;
    final timeline = controller;
    final result = await Navigator.of(context, rootNavigator: true).push(
      MotionPageRoute(
        builder: (_) => ImagePickerPage(isGroup: isGroup),
      ),
    ) as ({List<GalleryPhoto> photos, bool original, bool flash})?;
    if (result == null ||
        result.photos.isEmpty ||
        timeline == null ||
        !mounted ||
        _disposing ||
        !identical(widget.roomLease, matrix)) {
      return;
    }
    if (result.flash) {
      await _sendFlashPhoto(result.photos.single, timeline);
      return;
    }
    setState(() {
      composerPanel = ComposerPanel.none;
      mediaMessage = null;
    });
    // 大视频发送前警告：相册视频走后台队列自动压缩，压缩结果在转码后
    // 才能确定；超限会在消息上显示红色感叹号。体积明显过大时先征询，
    // 避免“静默发送→失败”的体验。
    for (final photo in result.photos) {
      if (!photo.isVideo) continue;
      var sourceBytes = 0;
      try {
        final source = await photo.localVideoFile?.call();
        sourceBytes = await source?.length() ?? 0;
      } catch (_) {}
      final durationMs = photo.duration?.inMilliseconds ?? 0;
      // 与转码预算同源的粗估：aggressive 档约按 20MB 预算反推码率；
      // 超过 60 秒或源文件超过 200MB 时大概率压缩后仍超限。
      final risky = sourceBytes > 200 * 1024 * 1024 ||
          (durationMs > 60 * 1000 && sourceBytes > 20 * 1024 * 1024);
      if (risky && mounted) {
        final proceed = await showCupertinoDialog<bool>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: const Text('视频体积较大'),
            content: const Text('该视频时长或体积较大，将自动压缩后发送；'
                '\n压缩后仍可能超过 20MB 上限导致发送失败。'
                '\n建议裁剪或选择较短的视频。'),
            actions: [
              CupertinoDialogAction(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('取消')),
              CupertinoDialogAction(
                  isDefaultAction: true,
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('仍要发送')),
            ],
          ),
        );
        if (proceed != true) {
          if (mounted) {
            setState(() => composerPanel = ComposerPanel.none);
          }
          return;
        }
      }
    }
    final sends = <Future<void>>[];
    final galleryVideos = <MatrixOutgoingVideoFileRequest>[];
    for (final photo in result.photos) {
      final videoSource = photo.localVideoFile;
      if (photo.isVideo && videoSource != null) {
        final jobId =
            'gallery-video-${DateTime.now().microsecondsSinceEpoch}-${galleryVideos.length}';
        // 登记本机产物：发送后点开优先本地回读——弱网下大视频回下载
        // 超时是发送方“视频加载失败”的主因（产物保留未删除）。
        unawaited(videoSource().then((file) {
          if (file == null) return;
          SentVideoLocalRegistry.shared.register(jobId: jobId, file: file);
        }).catchError((_) {}));
        galleryVideos.add(MatrixOutgoingVideoFileRequest(
          jobId: jobId,
          video: MatrixOutgoingVideoFile(
            id: photo.id,
            resolveSource: videoSource,
            filename: 'video.mp4',
            body: '[视频消息]',
            deleteSourceWhenDone: false,
          ),
          targetRoomIds: [targetRoomId],
        ));
        continue;
      }
      sends.add(
        timeline.sendText(
          photo.isVideo ? '[视频消息]' : '[图片消息]',
          kind: photo.isVideo ? RoomMessageKind.video : RoomMessageKind.image,
          mimeType: photo.mimeType,
          send: (transactionId) {
            if (!photo.isVideo &&
                photo.mimeType != 'image/gif' &&
                photo.thumbnail.isNotEmpty) {
              roomImagePreviewCache.seed(transactionId, photo.thumbnail);
            }
            return _enqueueMedia(() async {
              final prepared = await prepareGalleryMedia(
                photo,
                original: result.original,
                isGroup: isGroup,
              );
              final bytes = prepared.bytes;
              final mimeType = prepared.mimeType;
              if (!photo.isVideo) {
                roomImagePreviewCache.seed(
                  transactionId,
                  isGifBytes(bytes)
                      ? bytes
                      : photo.thumbnail.isNotEmpty
                          ? photo.thumbnail
                          : bytes,
                );
              }
              // 视频附带时长（毫秒），接收端显示角标。
              final extra = photo.duration == null
                  ? null
                  : {
                      'info': {'duration': photo.duration!.inMilliseconds},
                    };
              // 附带本地生成的压缩演绎版（E2EE 同样保护）：
              // 图片为 ≤800px/≤100KB 缩略图，视频为封面海报帧；
              // 生成失败不阻断发送，接收端自动回退全量加载（兼容旧行为）。
              ({Uint8List bytes, int? width, int? height})? rendition;
              if (photo.isVideo) {
                final poster = await photo.posterBytes?.call();
                if (poster != null && poster.isNotEmpty) {
                  final dims = await decodeImageDimensions(poster);
                  rendition = (
                    bytes: poster,
                    width: dims?.$1,
                    height: dims?.$2,
                  );
                }
              } else {
                final thumbnail = await buildChatImageThumbnail(bytes);
                if (thumbnail != null) {
                  rendition = (
                    bytes: thumbnail.bytes,
                    width: thumbnail.width,
                    height: thumbnail.height,
                  );
                }
              }
              return _cacheSentImage(
                roomImagePreviewCache.get(transactionId),
                matrix.sendEncryptedMedia(
                  roomInfo.id,
                  bytes,
                  mimeType,
                  extraContent: extra,
                  txid: transactionId,
                  thumbnailBytes: rendition?.bytes,
                  thumbnailWidth: rendition?.width,
                  thumbnailHeight: rendition?.height,
                ),
              );
            });
          },
        ),
      );
    }
    if (galleryVideos.isNotEmpty) {
      try {
        await matrix.enqueueVideoFiles(requests: galleryVideos);
        if (mounted && !_disposing && identical(widget.roomLease, matrix)) {
          await timeline.showLatest();
          _showMediaMessage('正在发送');
        }
      } on MatrixOutgoingWorkCapacityException {
        if (mounted && !_disposing && identical(widget.roomLease, matrix)) {
          _showMediaMessage('当前视频任务较多，请稍后重新选择');
        }
      } on StateError {
        if (mounted && !_disposing && identical(widget.roomLease, matrix)) {
          _showMediaMessage('视频暂时无法发送，请重新选择');
        }
      } on ArgumentError {
        if (mounted && !_disposing && identical(widget.roomLease, matrix)) {
          _showMediaMessage('视频暂时无法发送，请重新选择');
        }
      } catch (_) {
        if (mounted && !_disposing && identical(widget.roomLease, matrix)) {
          _showMediaMessage('视频暂时无法发送，请重新选择');
        }
      }
    }
    try {
      await Future.wait(sends);
    } catch (_) {
      if (mounted && !_disposing && identical(widget.roomLease, matrix)) {
        _showMediaMessage('部分媒体发送准备失败，请重试');
      }
    }
  }

  Future<String> _cacheSentImage(
    Uint8List? preview,
    Future<String> sending,
  ) async {
    final eventId = await sending;
    if (preview != null) roomImagePreviewCache.seed(eventId, preview);
    return eventId;
  }

  Future<void> _outgoingMediaQueue = Future<void>.value();
  Future<String> _enqueueMedia(Future<String> Function() send) {
    final task = _outgoingMediaQueue.then((_) async {
      try {
        return await send();
      } on GroupVideoTooLargeException catch (error) {
        if (mounted && !_disposing) _showMediaMessage(error.toString());
        rethrow;
      } on VideoCompressionException catch (error) {
        if (mounted && !_disposing) _showMediaMessage(error.toString());
        rethrow;
      }
    });
    _outgoingMediaQueue =
        task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  /// Camera completion admits the controlled capture before compression. The
  /// account owner continues preparation after this page is left.
  Future<void> _startVideoCapture() async {
    if (!await _prepareNewDirectOperation()) return;
    if (_capturingVideo) return;
    final matrix = widget.roomLease;
    final targetRoomId = roomInfo.id;
    final timeline = controller;
    final service = MediaMessageService(matrix, isGroup: isGroup);
    setState(() => _capturingVideo = true);
    String? capturePath;
    var admitted = false;
    try {
      capturePath = await service.captureVideoToFile();
      if (capturePath == null ||
          !mounted ||
          _disposing ||
          !identical(widget.roomLease, matrix)) {
        return;
      }
      _dismissComposerExtensions();
      final capture = File(capturePath);
      await matrix.enqueueVideoFile(
        jobId: 'capture-video-${DateTime.now().microsecondsSinceEpoch}',
        video: MatrixOutgoingVideoFile(
          id: capturePath,
          source: capture,
          filename: capture.uri.pathSegments.last,
          body: '[视频消息]',
          deleteSourceWhenDone: true,
        ),
        targetRoomIds: [targetRoomId],
      );
      admitted = true;
      // This is a sender-originated item, so return the current room from an
      // anchored older window to latest where its account pending bubble lives.
      await timeline?.showLatest();
      if (mounted && !_disposing && identical(widget.roomLease, matrix)) {
        _showMediaMessage('正在发送');
      }
    } on GroupVideoTooLargeException catch (error) {
      if (mounted && !_disposing) _showMediaMessage(error.toString());
    } on VideoCompressionException catch (error) {
      if (mounted && !_disposing) _showMediaMessage(error.toString());
    } catch (_) {
      if (mounted && !_disposing) _showMediaMessage('视频准备失败，请重试');
    } finally {
      // Covers navigation away while the system camera is still returning.
      try {
        if (!admitted && capturePath != null) {
          final capture = File(capturePath);
          if (await capture.exists()) await capture.delete();
        }
      } finally {
        await service.dispose();
        if (mounted && !_disposing) {
          setState(() {
            _capturingVideo = false;
          });
        }
      }
    }
  }

  void _showMediaMessage(String message) {
    mediaMessageTimer?.cancel();
    setState(() {
      mediaMessage = message;
      mediaMessageVisible = true;
    });
    mediaMessageTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => mediaMessageVisible = false);
      mediaMessageTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) setState(() => mediaMessage = null);
      });
    });
  }

  void _dismissComposerExtensions() {
    FocusManager.instance.primaryFocus?.unfocus();
    if (composerPanel != ComposerPanel.none) {
      setState(() => composerPanel = ComposerPanel.none);
    }
  }

  void _togglePanel(ComposerPanel panel) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      composerPanel = composerPanel == panel ? ComposerPanel.none : panel;
    });
  }

  /// emoji 面板展开时点击输入框：收起面板并聚焦输入框弹出键盘。
  /// 面板收回与键盘弹出同一帧处理，避免相互遮挡与二次跳动；
  /// 点击输入框以外的区域不经过本回调，面板保持原逻辑。
  void _dismissEmojiPanelForInput() {
    if (composerPanel != ComposerPanel.emoji) return;
    setState(() => composerPanel = ComposerPanel.none);
    inputFocusNode.requestFocus();
  }

  void _toggleVoice() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      composerPanel = composerPanel == ComposerPanel.voice
          ? ComposerPanel.none
          : ComposerPanel.voice;
    });
  }

  String get _voicePath =>
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'liuhetong-voice-${DateTime.now().microsecondsSinceEpoch}.m4a';

  Future<void> _onVoiceStart() async {
    if (callAudioActivity.value) {
      _showMediaMessage('通话中暂时不能录制语音');
      throw StateError('Call owns audio');
    }
    _startingVoice = true;
    _voiceStartCancelled = false;
    if (!await _prepareNewDirectOperation() ||
        _voiceStartCancelled ||
        !mounted ||
        _disposing) {
      _startingVoice = false;
      return;
    }
    final service = MediaMessageService(
      widget.roomLease,
    );
    try {
      await _voicePlayback?.stopAll();
      await service.startVoiceRecording(_voicePath);
      if (!mounted ||
          _disposing ||
          _voiceStartCancelled ||
          callAudioActivity.value) {
        await service.cancelVoiceRecording();
        throw StateError('Recording interrupted');
      }
    } catch (_) {
      _startingVoice = false;
      await service.dispose();
      // 麦克风不可用是语音无声的常见根因：用对话框强提示，避免用户
      // 只看到一闪而过的 toast 而以为“按住说话没有反应”。
      if (mounted && !callAudioActivity.value && !_disposing) {
        unawaited(showCupertinoDialog<void>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: const Text('无法访问麦克风'),
            content: const Text('请在系统设置中允许畅聊使用麦克风，然后重新按住说话。'),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('知道了'),
              ),
            ],
          ),
        ));
      }
      rethrow;
    }
    voiceService = service;
    _startingVoice = false;
    _voiceStartedAt = DateTime.now();
    // 并行开启语音识别：松手“转文字”时取回识别文本（不可用时静默降级）。
    unawaited(voiceTranscriber.start());
    _voiceElapsed = Duration.zero;
    _voiceTicker?.cancel();
    _voiceTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _voiceElapsed = DateTime.now().difference(_voiceStartedAt!);
      });
    });
    // 微信语义：最长 60 秒，到点自动停止并按正常松开发送。
    _voiceMaxTimer = Timer(const Duration(seconds: 60), () {
      unawaited(_finishVoice(send: true));
    });
  }

  Future<void> _onVoiceStop(Duration elapsed) => _finishVoice(send: true);

  bool _startingVoice = false;
  bool _voiceStartCancelled = false;
  bool get _canPlayVoice =>
      !callAudioActivity.value && !_startingVoice && voiceService == null;

  void _handleCallAudioActivity() {
    if (!callAudioActivity.value || _disposing) return;
    if (_startingVoice) _voiceStartCancelled = true;
    unawaited(_voicePlayback?.stopAll().catchError((Object _) {}));
    if (voiceService != null) {
      unawaited(_finishVoice(send: false).catchError((Object _) {}));
    }
  }

  Future<void> _toggleVoiceMessage(RoomMessageViewModel message) async {
    if (!_canPlayVoice) {
      _showMediaMessage('通话或录音中暂时不能播放语音');
      return;
    }
    await voicePlayback.toggle(message);
    if (mounted && !_disposing && voicePlayback.hasFailed(message.id)) {
      _showMediaMessage('语音播放失败，点击语音重试');
    }
  }

  Future<void> _onVoiceCancel(VoiceArmedTarget target) async {
    if (target != VoiceArmedTarget.text) {
      await _finishVoice(send: false);
      return;
    }
    final service = voiceService;
    voiceService = null;
    final elapsed =
        DateTime.now().difference(_voiceStartedAt ?? DateTime.now());
    _clearVoiceOverlay();
    if (service == null) return;
    final recognized = voiceTranscriber.stop();
    try {
      final path = await service.stopVoiceRecordingForPreview();
      final text = (await recognized).trim();
      if (!mounted) return;
      if (text.isNotEmpty) {
        unawaited(service.deleteVoiceFile(path));
        await controller?.sendText(text);
      } else if (elapsed >= const Duration(seconds: 1)) {
        await _sendVoicePath(service, path, elapsed);
      } else {
        await service.deleteVoiceFile(path);
      }
    } catch (_) {
      if (mounted) _showMediaMessage('语音处理失败，请重试');
    } finally {
      await service.dispose();
    }
  }

  void _clearVoiceOverlay() {
    _cancelVoiceTimers();
    if (!mounted || _disposing) return;
    setState(() {
      _voiceElapsed = Duration.zero;
      voiceRecording.discard();
    });
  }

  Future<void> _sendVoicePath(
      MediaMessageService service, String path, Duration elapsed) async {
    await controller?.sendText(
      '[语音消息]',
      kind: RoomMessageKind.voice,
      mimeType: 'audio/aac',
      voiceDuration: elapsed,
      send: (txid) => _enqueueMedia(() async {
        final eventId = await service.sendVoicePreview(roomInfo.id, path,
            duration: elapsed, txid: txid);
        await service.deleteVoiceFile(path);
        return eventId;
      }),
    );
  }

  void _cancelVoiceTimers() {
    _voiceMaxTimer?.cancel();
    _voiceMaxTimer = null;
    _voiceTicker?.cancel();
    _voiceTicker = null;
  }

  Future<void> _finishVoice({required bool send}) async {
    final service = voiceService;
    voiceService = null;
    final elapsed = voiceRecording.duration ??
        DateTime.now().difference(_voiceStartedAt ?? DateTime.now());
    _clearVoiceOverlay();
    unawaited(voiceTranscriber.stop());
    if (service == null) return;
    try {
      if (send) {
        final path = await service.stopVoiceRecordingForPreview();
        if (elapsed >= const Duration(seconds: 1) && mounted) {
          await _sendVoicePath(service, path, elapsed);
        } else {
          await service.deleteVoiceFile(path);
        }
      } else {
        await service.cancelVoiceRecording();
      }
    } catch (_) {
      if (mounted) _showMediaMessage('语音处理失败，请重试');
    } finally {
      await service.dispose();
    }
  }

  Future<void> _handleMoreAction(ChatMoreAction action) async {
    setState(() => composerPanel = ComposerPanel.none);
    switch (action) {
      case ChatMoreAction.image:
        await _sendMedia(image: true);
      case ChatMoreAction.camera:
        await _captureAndSendImage();
      case ChatMoreAction.file:
        await _sendMedia(image: false);
      case ChatMoreAction.redPacket:
        await _showRedPacket();
      case ChatMoreAction.transfer:
        await _showTransfer();
      case ChatMoreAction.voiceCall:
        if (peer != null) await widget.onVoice?.call(peer!);
      case ChatMoreAction.videoCall:
        if (peer != null) await widget.onVideo?.call(peer!);
    }
  }

  Future<void> _showRedPacket() async {
    final apiEpoch = widget.api.sessionEpoch;
    final timeline = controller;
    if (timeline == null) return;
    if (!isGroup && peer == null) {
      await _showError('好友资料尚未加载，暂时无法发送定向红包');
      return;
    }
    int? groupMemberCount;
    if (isGroup) {
      try {
        groupMemberCount = await _refreshJoinedMemberCountForRedPacket();
      } catch (_) {
        if (mounted) await _showError('无法确认群成员人数，请稍后重试');
        return;
      }
    }
    if (!mounted ||
        widget.roomLease.canceled ||
        widget.api.sessionEpoch != apiEpoch) {
      return;
    }
    List<ChatRoomMember> members() => chatRoomMembersFor(
          members: _joinedMembers,
          currentUserId: roomInfo.currentUserId,
          contactsByMatrixId: _identityCache.contactsByMatrixId,
        );
    final payment = await _preparePayment();
    if (payment == null) return;
    if (!mounted ||
        widget.roomLease.canceled ||
        widget.api.sessionEpoch != apiEpoch) {
      payment.clear();
      return;
    }
    final redPacketController = ChatRedPacketController(
      business: BusinessChatRedPacketGateway(widget.api, payment: payment),
      references: TimelineRedPacketReferenceGateway(timeline),
      roomId: isGroup ? roomInfo.id : null,
      recipientId: isGroup ? null : peer!.userId,
      recipientMatrixId: isGroup ? null : peer!.matrixUserId,
      joinedMemberCount: groupMemberCount,
      refreshJoinedMemberCount: isGroup
          ? () async {
              if (!mounted ||
                  widget.roomLease.canceled ||
                  widget.api.sessionEpoch != apiEpoch) {
                throw StateError('群成员状态已失效');
              }
              return _refreshJoinedMemberCountForRedPacket();
            }
          : null,
    );
    try {
      await Navigator.push<void>(
        context,
        MotionPageRoute(
          builder: (pageContext) => ListenableBuilder(
            listenable: _identityCache,
            builder: (context, child) => ChatRedPacketSheet(
              controller: redPacketController,
              isGroup: isGroup,
              support: BusinessChatRedPacketSupport(widget.api),
              members: members(),
              // 非好友群成员没有本地业务身份，必须提供实时查询入口，
              // 否则选择后只能弹「无法确认红包账号」。
              resolveBusinessUser:
                  isGroup ? widget.api.lookupUserByMatrixId : null,
              avatarMedia: widget.roomLease,
              onSent: () => Navigator.pop(pageContext),
            ),
          ),
        ),
      );
    } finally {
      redPacketController.dispose();
      payment.clear();
    }
  }

  Future<void> _showTransfer() async {
    final timeline = controller;
    if (timeline == null) return;
    // Direct chats preselect the peer; group chats and chats without a
    // loaded profile require picking a specific user inside the sheet.
    final hasPeer = !isGroup && peer != null;
    final payment = await _preparePayment();
    if (payment == null || !mounted) return;
    // 群聊收款人必须实时来自当前房间成员；加载失败时降级为空列表，
    // 由弹层提示“群成员尚未加载”，绝不回退到通讯录（否则会出现非群成员）。
    var groupMembers = const <GroupMemberIdentity>[];
    if (isGroup) {
      try {
        groupMembers = await _liveGroupMemberIdentities();
      } catch (_) {
        groupMembers = const <GroupMemberIdentity>[];
      }
      if (!mounted) {
        payment.clear();
        return;
      }
    }
    final transferController = ChatTransferController(
      business: BusinessChatTransferGateway(widget.api, payment: payment),
      references: TimelineChatTransferReferenceGateway(timeline),
    );
    await Navigator.push<void>(
      context,
      MotionPageRoute(
        builder: (pageContext) => ChatTransferSheet(
          controller: transferController,
          isGroup: isGroup,
          peerId: hasPeer ? peer!.userId : null,
          peerName: hasPeer ? peer!.displayName : null,
          peerAvatarUrl: hasPeer ? peer!.avatarUrl : null,
          peerMatrixUserId: hasPeer ? peer!.matrixUserId : null,
          balanceSource: BusinessChatTransferBalanceSource(widget.api),
          groupMembers: isGroup ? groupMembers : null,
          resolveBusinessUser: isGroup ? widget.api.lookupUserByMatrixId : null,
          avatarMedia: widget.roomLease,
          // 私聊对端资料未就绪时才允许从通讯录选择；群聊永不使用通讯录。
          contactsSource:
              isGroup ? null : BusinessChatTransferContactsSource(widget.api),
          onSent: () => Navigator.pop(pageContext),
        ),
      ),
    );
    transferController.dispose();
    payment.clear();
  }

  void _insertEmoji(String selected) {
    final selection = input.selection;
    final start = selection.isValid ? selection.start : input.text.length;
    final end = selection.isValid ? selection.end : input.text.length;
    input.value = TextEditingValue(
      text: input.text.replaceRange(start, end, selected),
      selection: TextSelection.collapsed(offset: start + selected.length),
    );
  }

  Future<void> _showError(String message) => showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('操作失败'),
          content: Text(message),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      );

  Future<void> _openContact(ContactDetails contact) => Navigator.push(
        context,
        MotionPageRoute(
          builder: (_) => ContactProfilePage(
            api: widget.api,
            identityCache: _identityCache,
            initialContact: contact,
            onMessage: widget.onMessage,
            onVoice: widget.onVoice,
            onVideo: widget.onVideo,
            onContactUpdated: (updated) =>
                _identityCache.applyUpdatedContact(updated.toSummary()),
            onContactDeleted: _identityCache.removeContact,
          ),
        ),
      );

  Future<void> _openConversationDetails() async {
    if (isGroup) {
      final infoController = GroupChatInfoController(
        widget.roomLease.openGroupChatInfoGateway(),
        // BUG1：添加成员与建群共用服务端授权自动入群（操作者校验 +
        // invite 配对 + auto_allow 分流在服务端完成）。
        serverAutoJoin: (roomId, inviteeUserIds) async {
          try {
            final response = await widget.api.requestServerGroupAutoJoin(
              roomId: roomId,
              inviteeUserIds: inviteeUserIds,
            );
            return GroupAutoJoinOutcome.fromJson(response);
          } catch (_) {
            return null; // 邀请已成立；自动加入失败留给对方确认。
          }
        },
      )..bindMembershipChanges(
          widget.roomLease.membershipChanges,
          roomId: roomInfo.id,
        );
      final contacts = await widget.api.listContacts();
      if (!mounted) return;
      final contactsById = {
        for (final contact in contacts)
          contact.matrixUserId: contact.toDetails(),
      };
      await Navigator.push<void>(
        context,
        MotionPageRoute(
          builder: (_) => GroupChatInfoPage(
            avatarMedia: widget.roomLease,
            api: widget.api,
            controller: infoController,
            identityCache: _identityCache,
            onAddMember: () => _openGroupMemberPicker(infoController),
            onSearchHistory: () => _trackAction(_openHistorySearch),
            onClearLocalHistory: () => _trackAction(_clearLocalHistory),
            onMemberTap: (member) => openGroupMemberProfile(
              context,
              api: widget.api,
              lookupByMatrixId: widget.api.lookupUserByMatrixId,
              identityCache: _identityCache,
              contactActions: ContactActions(
                onMessage: widget.onMessage,
                onVoice: widget.onVoice,
                onVideo: widget.onVideo,
              ),
              member: member,
              selfMatrixUserId: roomInfo.currentUserId,
              friendContact: contactsById[member.matrixUserId],
              onOpenFriendContact: _openContact,
            ),
            onLeft: () {
              Navigator.pop(context);
              Navigator.pop(context);
            },
          ),
        ),
      );
      infoController.dispose();
      return;
    }
    MatrixRoomMemberSnapshot? member;
    for (final participant in roomInfo.members) {
      if (participant.id != roomInfo.currentUserId) {
        member = participant;
        break;
      }
    }
    final contact = peer;
    final peerId = contact?.matrixUserId ?? member?.id;
    if (peerId == null) return;
    final peerName = contact?.displayName ?? member?.displayName ?? peerId;
    final avatarUrl = contact?.avatarUrl ?? member?.avatarUri?.toString();
    await Navigator.push<void>(
      context,
      MotionPageRoute(
        builder: (_) => DirectChatInfoPage(
          // 规格§八：头像点击 → APP 好友资料页（非 Matrix Profile）。
          onTapPerson: (matrixUserId) =>
              unawaited(_openPeerProfile(matrixUserId)),

          peerName: peerName,
          peerId: peerId,
          avatarMedia: widget.roomLease,
          peerAvatarUrl: avatarUrl,
          preference: roomInfo.preference,
          // BUG-16：聊天信息页的「添加」携带对端账号进入发起群聊。
          onAddMember: () {
            final withPeer = widget.onCreateGroupWithPeer;
            if (withPeer != null) {
              withPeer(peer?.matrixUserId ?? roomInfo.directPeerId);
            } else {
              widget.onCreateGroup();
            }
          },
          onSearchHistory: () => _trackAction(_openHistorySearch),
          onClearLocalHistory: () => _trackAction(_clearLocalHistory),
          onPreferenceChanged: (preference) =>
              widget.roomLease.updateConversationPreference(preference),
        ),
      ),
    );
  }

  Future<void> _openGroupMemberPicker(
    GroupChatInfoController infoController,
  ) async {
    try {
      final contacts = await widget.api.listContacts();
      if (!mounted) return;
      final existing = infoController.state.snapshot?.members
              .map((member) => member.matrixUserId)
              .toSet() ??
          <String>{};
      await Navigator.push<void>(
        context,
        MotionPageRoute(
          builder: (_) => GroupMemberPickerPage(
            contacts: contacts,
            identityCache: _identityCache,
            existingMemberIds: existing,
            onInvite: (matrixUserId, businessUserId) => infoController
                .invite(matrixUserId, businessUserId: businessUserId),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('无法添加群成员'),
          content: const Text('通讯录加载失败，请检查网络后重试。'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    }
  }

  void _openHistorySearch() {
    _cancelPendingTimelineWindowShift();
    final roomRoute = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    void returnToRoom() {
      if (roomRoute != null) navigator.popUntil((route) => route == roomRoute);
    }

    // R5 修复：改用新 ChatSearchPage（默认空态+组合筛选+拼音成员+
    // 安全高亮+稳定分页），替换旧 GroupChatHistorySearchPage。
    var searchOpen = true;
    var searchGeneration = 0;
    var dateLookupGeneration = 0;
    RoomHistoryDayLocation? resolvedDateLocation;
    final messagesById = <String, RoomMessageViewModel>{};
    List<ChatSearchMessage> currentSearchMessages() {
      final allMessages =
          controller?.allMessages ?? const <RoomMessageViewModel>[];
      final messages = (hiddenEvents?.visibleItems(
                roomInfo.id,
                allMessages,
                eventId: (message) => message.id,
                eventTimestamp: (message) => message.timestamp,
              ) ??
              allMessages)
          .where((message) => !message.isRecalled)
          .toList();
      messagesById.addAll({
        for (final message in messages) message.id: message,
      });
      // 转换为搜索模型（含媒体分类/正文可见文本/时间线序号）。
      // R6：普通文本含 HTTP(S) URL → link 分类（此前漏检）。
      return <ChatSearchMessage>[
        for (final message in messages)
          ChatSearchMessage(
            eventId: message.id,
            senderId: message.senderId,
            senderDisplayName: MemberDirectoryEntry(
              userId: message.senderId,
              remark: contactsByMatrixId[message.senderId]?.remark,
              nickname: contactsByMatrixId[message.senderId]?.nickname ??
                  _member(message.senderId).displayName,
              username: contactsByMatrixId[message.senderId]?.username,
            ).displayName,
            timestamp: message.timestamp.toLocal(),
            timelineOrder: message.timestamp.millisecondsSinceEpoch,
            visibleText: message.text,
            isFlashPhoto: message.isFlashPhoto,
            displayText: switch (message.kind) {
              RoomMessageKind.image =>
                message.mimeType?.startsWith('video/') == true
                    ? '[视频消息]'
                    : '[图片消息]',
              RoomMessageKind.video => '[视频消息]',
              RoomMessageKind.voice => '[语音消息]',
              RoomMessageKind.file => '[文件消息]',
              RoomMessageKind.call => '[通话消息]',
              RoomMessageKind.redPacket => '[红包消息]',
              RoomMessageKind.transfer => '[转账消息]',
              _ => message.text,
            },
            mediaCategory: _ordinarySearchMediaAllowed(message)
                ? switch (message.kind) {
                    RoomMessageKind.video => ChatSearchMediaCategory.imageVideo,
                    RoomMessageKind.image
                        when message.mimeType?.startsWith('video/') == true =>
                      ChatSearchMediaCategory.imageVideo,
                    RoomMessageKind.image => ChatSearchMediaCategory.imageVideo,
                    RoomMessageKind.file => ChatSearchMediaCategory.file,
                    RoomMessageKind.text
                        when RegExp(
                          'https?://[^\\\\s<>"]+',
                          caseSensitive: false,
                        ).hasMatch(message.text) =>
                      ChatSearchMediaCategory.link,
                    _ => null,
                  }
                : null,
            hasMedia: _ordinarySearchMediaAllowed(message) &&
                message.kind != RoomMessageKind.text,
            isVideo: message.kind == RoomMessageKind.video ||
                message.mimeType?.startsWith('video/') == true,
            duration: message.videoDuration,
          ),
      ]..sort((a, b) => b.timelineOrder.compareTo(a.timelineOrder));
    }

    // 群聊成员目录（统一拼音排序/过滤服务——R5/R12）。
    List<MemberDirectoryEntry> memberEntries() => <MemberDirectoryEntry>[
          for (final member in _joinedMembers)
            MemberDirectoryEntry(
              userId: member.id,
              remark: contactsByMatrixId[member.id]?.remark,
              nickname:
                  contactsByMatrixId[member.id]?.nickname ?? member.displayName,
              username: contactsByMatrixId[member.id]?.username ??
                  localPart(member.id),
            ),
        ];
    // Task A：月历日期 metadata 来自 RoomHistoryDayIndex（只读日期状态），
    // 不再从时间线正文投影；最早月份缺失时保持 null，绝不伪造 1970。
    final earliestMonth = controller?.earliestMonth;
    final latestMonth = CalendarMonth.of(DateTime.now());

    Navigator.push<void>(
      context,
      MotionPageRoute(
        builder: (_) => ChatSearchPage(
          isGroup: isGroup,
          identityChanges: _identityCache,
          senderDisplayName: (id) => _identityCache
              .resolveIdentity(
                matrixUserId: id,
                displayName: _member(id).displayName,
              )
              .displayName,
          search: (filters, {cursor, limit = 50}) async {
            final generation = ++searchGeneration;
            while (mounted && searchOpen && generation == searchGeneration) {
              final matched =
                  currentSearchMessages().where(filters.matches).toList();
              final start = cursor == null
                  ? 0
                  : matched.indexWhere((m) => m.eventId == cursor.eventId) + 1;
              if (matched.length >= start + limit ||
                  (controller?.historyExhausted ?? true)) {
                return matched.sublist(
                  start,
                  (start + limit).clamp(0, matched.length),
                );
              }
              final last = widget.roomLease.oldestTimelineEventId;
              final token = widget.roomLease.historyToken;
              await _loadEarlier();
              if (last == widget.roomLease.oldestTimelineEventId &&
                  token == widget.roomLease.historyToken) {
                return matched.sublist(
                    start, (start + limit).clamp(0, matched.length));
              }
            }
            return const <ChatSearchMessage>[];
          },
          // Task A：月历只读日期 metadata（有界月查询），正文/媒体不参与。
          earliestMonth: earliestMonth,
          latestMonth: latestMonth,
          loadCalendarMonth: (month) async {
            final load = controller;
            if (load == null || !searchOpen) {
              return RoomHistoryMonthDays(month: month);
            }
            return load.loadMonthDays(month);
          },
          onCancelCalendarMonthLookup: () => controller?.cancelMonthLookup(),
          onCalendarClosed: () => controller?.cancelPendingDateLookup(),
          onSearchInvalidated: () => searchGeneration++,
          memberEntries: memberEntries(),
          liveMemberEntries: memberEntries,
          memberAvatarBuilder: (context, entry) {
            final identity = _identityCache.resolveIdentity(
                matrixUserId: entry.userId, displayName: entry.displayName);
            return MatrixUserAvatar(
              avatarMedia: widget.roomLease,
              nickname: identity.displayName,
              fallbackSeed: identity.cacheKey,
              matrixAvatarUri: identity.avatarIsKnown
                  ? null
                  : _member(entry.userId).avatarUri,
              fallbackAvatarUrl: identity.avatarUrl,
              diagnosticSource: 'search-member-picker',
              size: 36,
            );
          },
          mediaThumbnailBuilder: (context, message) {
            // 安全不变量：普通媒体网格永远不得触碰闪照 loader
            // （闪照在搜索投影里已无 media 分类/hasMedia=false）。
            if (!MediaMessageAccessPolicy.forMessage(
                    isFlashPhoto: message.isFlashPhoto)
                .includeInSearchMedia) {
              throw StateError(
                  'Flash photo must not use ordinary search media grid');
            }
            return FutureBuilder<Uint8List?>(
              future: message.isVideo
                  ? _loadVideoPoster(message.eventId)
                  : _loadImagePreview(messagesById[message.eventId]!),
              builder: (context, snapshot) {
                final bytes = snapshot.data;
                if (bytes != null) {
                  return Image(
                    image: boundedChatImageProvider(bytes, maxEdge: 360),
                    fit: BoxFit.contain,
                  );
                }
                return Center(
                  child: snapshot.connectionState == ConnectionState.waiting
                      ? const CupertinoActivityIndicator()
                      : const Icon(
                          CupertinoIcons.photo,
                          color: WeChatColors.textTertiary,
                        ),
                );
              },
            );
          },
          onOpenMedia: (eventId) {
            final message = messagesById[eventId];
            if (message == null) return;
            if (message.kind == RoomMessageKind.video ||
                message.mimeType?.startsWith('video/') == true) {
              unawaited(_openVideoViewer(message));
            } else {
              unawaited(
                  _trackAction(() => _openImageViewerWithForward(message)));
            }
          },
          onJumpToMessage: (eventId) {
            returnToRoom();
            unawaited(_scrollToMessage(eventId));
          },
          onJumpToDate: (date) {
            final location = resolvedDateLocation;
            if (location == null || location.day != date) return;
            returnToRoom();
            unawaited(_scrollToMessage(location.eventId));
          },
          onDateLookup: (date) async {
            final lookup = controller;
            final generation = ++dateLookupGeneration;
            if (lookup == null || !searchOpen) {
              return CalendarDateLookupResult.incomplete;
            }
            // Task A：月索引已经给出该日 anchor 时直接采用，不再重复访问
            // timestamp_to_event（anchor 来自本机已解密的可见事件）。
            final anchor = lookup.anchorForDay(date);
            if (anchor != null) {
              resolvedDateLocation =
                  RoomHistoryDayLocation(eventId: anchor, day: date);
              return CalendarDateLookupResult.located;
            }
            try {
              final location = await lookup.locateDay(date);
              if (!mounted ||
                  !searchOpen ||
                  generation != dateLookupGeneration ||
                  !identical(lookup, controller)) {
                throw const RoomHistoryLookupCancelled();
              }
              if (location == null) {
                return CalendarDateLookupResult.confirmedEmpty;
              }
              resolvedDateLocation = location;
              return CalendarDateLookupResult.located;
            } on RoomHistoryLookupIncomplete {
              if (mounted && searchOpen && generation == dateLookupGeneration) {
                return CalendarDateLookupResult.incomplete;
              }
              throw const RoomHistoryLookupCancelled();
            } on RoomHistoryLookupCancelled {
              // A newer day, calendar close, lease change, or dispose won.
              // The controller has already discarded its partial context.
              rethrow;
            }
          },
          onCancelDateLookup: () {
            dateLookupGeneration++;
            controller?.cancelPendingDateLookup();
          },
        ),
      ),
    ).whenComplete(() {
      searchOpen = false;
      dateLookupGeneration++;
      controller?.cancelPendingDateLookup();
      searchGeneration++;
    });
  }

  /// 清空聊天记录（**软隐藏语义**）。
  ///
  /// 只写本机历史清除截止时间（cutoff）：Matrix 本地库里的事件**仍然存在**，
  /// 重新同步后可能再次出现。因此这里**绝不能**清理闪照 tombstone——否则
  /// 旧闪照会重新变成「未查看」并可再次打开（fail-open）。
  /// tombstone 的真实清理点是本地加密库被整体删除（
  /// `MatrixSdkE2eeClient.clearLocalChatData`）。
  Future<void> _clearLocalHistory() async {
    final store = hiddenEvents;
    if (store == null) return;
    final messages = controller?.allMessages ?? const <RoomMessageViewModel>[];
    var cutoff = DateTime.now();
    for (final message in messages) {
      if (message.timestamp.isAfter(cutoff)) cutoff = message.timestamp;
    }
    // 走「清空聊天记录」契约：只写本机历史清除截止时间。若误用
    // MatrixConversationMutation.delete 的删除信号，会话会从消息列表消失。
    await widget.roomLease.clearLocalHistory(
      messageIds: messages.map((message) => message.id),
      cutoff: cutoff,
    );
    for (final id
        in unreadMentions?.pendingEventIdsNewestFirst() ?? <String>[]) {
      unreadMentions?.onRedacted(id);
    }
    await widget.roomLease.saveMentions();
    controller?.setHiddenFilter(hiddenEvents?.readFilter(roomInfo.id));
    // 清空本机记录后，之前为引用卡片解析出来的窗口外原消息也必须失效。
    controller?.clearResolvedReplyTargets();
    replyResolver?.clear();
    await controller?.refresh();
    if (mounted) setState(() {});
  }

  Future<bool> _scrollToMessage(String eventId) async {
    if (_locatingMessage) return false;
    _cancelPendingTimelineWindowShift();
    final generation = _timelineScrollGeneration;
    _locatingMessage = true;
    var found = false;
    try {
      while (mounted) {
        if (await controller?.openAnchor(eventId) ?? false) {
          break;
        }
        final oldest = widget.roomLease.oldestTimelineEventId;
        final token = widget.roomLease.historyToken;
        await _loadEarlier();
        if (!mounted ||
            generation != _timelineScrollGeneration ||
            (controller?.historyExhausted ?? true)) {
          break;
        }
        if (oldest == widget.roomLease.oldestTimelineEventId &&
            token == widget.roomLease.historyToken) {
          break;
        }
      }
      if (!mounted) return false;
      await WidgetsBinding.instance.endOfFrame;
      final all = controller?.messages ?? const <RoomMessageViewModel>[];
      final visible = hiddenEvents?.visibleItems(
            roomInfo.id,
            all,
            eventId: (message) => message.id,
            eventTimestamp: (message) => message.timestamp,
          ) ??
          all;
      found = await revealLazyMessage(
        controller: messageScrollController,
        eventIds: visible.reversed.map((message) => message.id).toList(),
        messageKeys: messageKeys,
        eventId: eventId,
        isMounted: () => mounted,
        canContinue: () =>
            mounted &&
            generation == _timelineScrollGeneration &&
            !_scrollInteractionActive(),
      );
    } finally {
      _locatingMessage = false;
    }
    if (!found) {
      // A new drag, route transition or another locator invalidates this
      // request. It is cancellation, not a user-visible "not found" result.
      if (!mounted ||
          generation != _timelineScrollGeneration ||
          _scrollInteractionActive()) {
        return false;
      }
      if (mounted) _showMediaMessage('未找到该消息，请稍后重试');
      return false;
    }
    if (!mounted) return false;
    setState(() => highlightedMessageId = eventId);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted && highlightedMessageId == eventId) {
      setState(() => highlightedMessageId = null);
    }
    return true;
  }

  /// 规格 #4：点击引用跳转到被引用消息；成功后屏幕右下方出现
  /// “回到引用位置”弹窗（样式与 @提醒弹窗一致），点击弹窗返回
  /// 引用发起消息并高亮。再次引用跳转会替换弹窗目标。
  Future<void> _jumpFromQuote(RoomMessageViewModel message) async {
    final target = message.replyToEventId;
    if (target == null) return;
    final found = await _scrollToMessage(target);
    if (!mounted || !found) return;
    setState(() => quoteReturnMessageId = message.id);
  }

  Future<void> _returnToQuoteOrigin() async {
    final origin = quoteReturnMessageId;
    if (origin == null) return;
    setState(() => quoteReturnMessageId = null);
    await _scrollToMessage(origin);
  }

  String _displayName(String matrixUserId, bool own) {
    return _identityCache
        .resolveIdentity(
          matrixUserId: matrixUserId,
          username: own ? ownProfile?.username : null,
          displayName: own
              ? (ownProfile?.nickname ?? '我')
              : _member(matrixUserId).displayName,
        )
        .displayName;
  }

  Widget _avatar(RoomMessageViewModel message) {
    final member = _member(message.senderId);
    final identity = _identityCache.resolveIdentity(
      matrixUserId: message.senderId,
      username: message.isOwn ? ownProfile?.username : null,
      displayName: member.displayName,
      avatarUrl: message.isOwn ? ownProfile?.avatarUrl : null,
    );
    return MatrixUserAvatar(
      avatarMedia: widget.roomLease,
      diagnosticSource: 'room-message',
      nickname: _displayName(message.senderId, message.isOwn),
      fallbackSeed: identity.cacheKey,
      matrixAvatarUri: identity.avatarIsKnown ? null : member.avatarUri,
      fallbackAvatarUrl: identity.avatarUrl,
      size: WeChatDimensions.messageAvatar,
    );
  }

  /// 闪照气泡：马赛克 + 闪电角标；未销毁时可打开查看页，销毁后仅提示。
  Widget _flashPhotoBubble(RoomMessageViewModel message) {
    final viewed = _flashViewed?.isViewed(message.id) ?? false;
    return GestureDetector(
      onTap: () => _openFlashViewer(message),
      child: FlashPhotoBubble(
        loadOriginal: () => imageMemoryCache.putIfAbsent(
          _mediaKey(message.id).cacheId,
          () => controller!.loadAttachment(message.id),
        ),
        viewed: viewed,
      ),
    );
  }

  Future<void> _openFlashViewer(RoomMessageViewModel message) async {
    final store = _flashViewed;
    if (store == null) return;
    if (store.isViewed(message.id)) {
      _showMediaMessage('闪照已销毁');
      return;
    }
    await Navigator.of(context, rootNavigator: true).push(
      MotionPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => FlashPhotoViewerPage(
          loadOriginal: () => imageMemoryCache.putIfAbsent(
            _mediaKey(message.id).cacheId,
            () => controller!.loadAttachment(message.id),
          ),
          onDestroyed: () {
            // 带上房间维度：将来「某房间本地历史被永久清除」时可以只清该房间。
            store.markViewed(message.id, roomId: roomInfo.id);
            if (mounted) setState(() {});
          },
        ),
      ),
    );
  }

  /// R7：打开全屏图片查看器（含转发/下载操作）。
  Future<void> _openImageViewerWithForward(RoomMessageViewModel message) async {
    // 第二层保护：即使将来搜索/气泡过滤回归，闪照也绝不能进入普通查看器
    // 或普通原图 loader（只允许专用安全查看器 FlashPhotoViewerPage）。
    if (!_mediaPolicyFor(message).canUseOrdinaryViewer) {
      _showMediaMessage('闪照仅可在闪照查看器中打开');
      return;
    }
    try {
      final images = _galleryImages();
      if (!mounted || !images.any((image) => image.id == message.id)) return;
      await Navigator.of(context, rootNavigator: true).push(
        MotionPageRoute(
          builder: (_) => RoomImageGalleryPage(
            images: images,
            initialId: message.id,
            sourceScope: (
              roomInfo.homeserver,
              roomInfo.currentUserId,
              roomInfo.id,
            ),
            loadEarlier: _earlierGalleryImages,
            onForwardEdited: _forwardEditedImage,
            onFavorite: _favoriteEditedImage,
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      _showMediaMessage('图片加载失败，请重试');
    }
  }

  /// R7：打开全屏图片查看器（ContainImageBubble 的点击动作）。
  Future<void> _openImageViewer(RoomMessageViewModel message) =>
      _openImageViewerWithForward(message);

  /// 媒体安全策略（闪照不属于普通媒体资产；集中规则见
  /// [MediaMessageAccessPolicy]，禁止在各处散落 isFlashPhoto 判断）。
  MediaMessageAccessPolicy _mediaPolicyFor(RoomMessageViewModel message) =>
      MediaMessageAccessPolicy.forMessage(isFlashPhoto: message.isFlashPhoto);

  /// 普通「图片与视频」历史搜索是否允许收录该消息。
  bool _ordinarySearchMediaAllowed(RoomMessageViewModel message) =>
      _mediaPolicyFor(message).includeInSearchMedia;

  List<RoomGalleryImage> _galleryImages() {
    final all = controller?.allMessages ?? const <RoomMessageViewModel>[];
    final visible = hiddenEvents?.visibleItems(
          roomInfo.id,
          all,
          eventId: (message) => message.id,
          eventTimestamp: (message) => message.timestamp,
        ) ??
        all;
    return [
      // 安全不变量（含历史分页与预取）：闪照永远不进入普通 Gallery，
      // 投影规则集中在 ordinaryGalleryMessages。
      for (final message in ordinaryGalleryMessages(visible))
        RoomGalleryImage(
          id: message.id,
          sourceIdentity: _previewKey(message).identity,
          loadPreview: () {
            _mediaPolicyFor(message)
                .assertOrdinaryMediaAllowed('gallery.preview');
            return _loadImagePreview(message);
          },
          loadOriginal: () {
            _mediaPolicyFor(message)
                .assertOrdinaryMediaAllowed('gallery.original');
            return withMediaLoadPriority(MediaLoadPriority.interactive,
                () => controller!.loadAttachment(message.id));
          },
          originalSize: message.attachmentSize,
          onForward: () {
            _mediaPolicyFor(message)
                .assertOrdinaryMediaAllowed('gallery.forward');
            return _forwardMessages([message]);
          },
        ),
    ];
  }

  Future<List<RoomGalleryImage>> _earlierGalleryImages() async {
    final initial = _galleryImages();
    final boundary = initial.firstOrNull?.id;
    final known = initial.map((image) => image.id).toSet();
    while (mounted && !(controller?.historyExhausted ?? true)) {
      final token = widget.roomLease.historyToken;
      final oldest = widget.roomLease.oldestTimelineEventId;
      await _loadEarlier();
      if (!mounted) return const [];
      final added = _galleryImages()
          .takeWhile((image) => image.id != boundary)
          .where((image) => !known.contains(image.id))
          .toList();
      if (added.isNotEmpty) return added;
      if (token == widget.roomLease.historyToken &&
          oldest == widget.roomLease.oldestTimelineEventId) {
        if (!(controller?.historyExhausted ?? true)) {
          throw StateError('History did not advance');
        }
        break;
      }
    }
    return const [];
  }

  Future<void> _favoriteEditedImage(Uint8List bytes) async {
    final session = emojiVault;
    if (session == null) throw StateError('收藏服务尚未就绪');
    final item = await session.vault.add(bytes, mimeType: 'image/png');
    if (!mounted) return;
    setState(
      () => customEmojiItems = [
        CustomEmojiItem(
          id: item.id,
          loadPreview: () => session.loadPreview(item),
          isAnimated: false,
          mimeType: item.mimeType,
        ),
        ...customEmojiItems.where((existing) => existing.id != item.id),
      ],
    );
  }

  Future<bool> _forwardEditedImage(Future<Uint8List> Function() export) async {
    final matrix = widget.roomLease;
    final destinations = await matrix.forwardingDestinations();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || _disposing || !identical(widget.roomLease, matrix)) {
      return false;
    }
    final recent = RecentForwardStore(prefs);
    final transaction = 'image-edit-${DateTime.now().microsecondsSinceEpoch}';
    // 选择器先开（无导出等待）；PNG 编码挪到确认后的发送态内完成。
    return await Navigator.of(context, rootNavigator: true).push<bool>(
          MotionPageRoute(
            builder: (_) => ChatForwardPickerPage(
              contentPreview: '[编辑图片]',
              candidates: [
                for (final room in destinations)
                  ChatForwardCandidate(
                    roomId: room.id,
                    title: _forwardTitleFor(room),
                    avatar: _forwardRoomAvatar(room),
                    isGroup: !room.isDirect,
                    memberCount: room.memberCount,
                  ),
              ],
              recentRoomIds: recent.load(),
              onForward: (ids) async {
                final bytes = await export();
                final job = await matrix.enqueuePreparedMedia(
                  jobId: transaction,
                  media: MatrixOutgoingPreparedMedia(
                    id: transaction,
                    bytes: bytes,
                    mimeType: 'image/png',
                    filename: '编辑图片.png',
                    body: '[编辑图片]',
                  ),
                  targetRoomIds: ids,
                );
                _trackForwardJobs(matrix, [job]);
                unawaited(recent.record(ids).catchError((Object _) {}));
              },
            ),
          ),
        ) ??
        false;
  }

  /// 转发入队后持续汇报：全部送达提示『已转发』，失败提示重试；
  /// 避免确认后 5 秒级静默（下载/加密/上传均在后台队列）。
  void _trackForwardJobs(
    MatrixEncryptedMediaGateway matrix,
    List<MatrixOutgoingWorkJob> jobs,
  ) {
    if (jobs.isEmpty) return;
    final progress = (matrix as MatrixOutgoingProgressView).outgoingProgress;
    var announced = false;
    void check() {
      if (announced || !mounted || _disposing) return;
      var hasFailed = false;
      var allTerminal = true;
      for (final job in jobs) {
        for (final item in job.items) {
          final state = item.state;
          if (state == MatrixOutgoingWorkState.failed) hasFailed = true;
          if (state != MatrixOutgoingWorkState.sent &&
              state != MatrixOutgoingWorkState.failed &&
              state != MatrixOutgoingWorkState.canceled) {
            allTerminal = false;
          }
        }
      }
      if (!allTerminal) return;
      announced = true;
      progress.removeListener(check);
      if (!mounted || _disposing) return;
      _showMediaMessage(hasFailed ? '转发失败，请稍后重试' : '已转发');
    }

    progress.addListener(check);
    check();
  }

  /// 群聊里转账收款人 / 专属红包指定成员的**本机**展示名。
  ///
  /// 优先级：当前账号的联系人备注 → 该联系人昵称 → 会话内 Matrix 显示名。
  /// 备注是隐私，只从本人本机联系人投影读取；消息内容只携带账号标识，
  /// 绝不写入或读取他人备注。
  String? _financeCounterpartyName(String? matrixUserId) {
    final id = matrixUserId?.trim() ?? '';
    if (id.isEmpty) return null;
    final contact = contactsByMatrixId[id];
    return counterpartyDisplayName(
      remark: contact?.remark,
      nickname: contact?.nickname,
      roomDisplayName: _member(id).displayName,
    );
  }

  Widget _messageContent(RoomMessageViewModel message) =>
      switch (message.kind) {
        // R7 修复：图片气泡改用 ContainImageBubble——按解码实际宽高
        // contain 适配（不再固定 200x150 cover 裁切）。
        RoomMessageKind.image => message.isFlashPhoto
            ? _flashPhotoBubble(message)
            : LayoutBuilder(
                builder: (context, constraints) => ContainImageBubble(
                  key: ValueKey('image-${message.stableId}'),
                  sourceIdentity: (
                    message.stableId,
                    _previewKey(message).identity
                  ),
                  initialBytes: _cachedImagePreview(message),
                  loadCached: () => _readCachedImagePreview(message),
                  load: () => _loadImagePreview(message),
                  isScrolling: messageListScrolling,
                  deferLoading:
                      message.deliveryState == RoomDeliveryState.sending &&
                          message.id == message.stableId,
                  sourceSize: _imageSourceSize(message),
                  availableWidth: constraints.maxWidth,
                  availableHeight: MediaQuery.of(context).size.height,
                  onTap: () => _openImageViewer(message),
                ),
              ),
        RoomMessageKind.file => WeChatAttachmentTile(
            name: message.text,
            progress: 1,
            showProgress: false,
          ),
        RoomMessageKind.voice => WeChatVoiceBubble(
            duration: message.voiceDuration,
            state: voicePlayback.isLoading(message.id)
                ? VoicePlaybackState.loading
                : voicePlayback.hasFailed(message.id)
                    ? VoicePlaybackState.failed
                    : voicePlayback.isPlaying(message.id)
                        ? VoicePlaybackState.playing
                        : voicePlayback.isPaused(message.id)
                            ? VoicePlaybackState.paused
                            : VoicePlaybackState.idle,
            onTap: () => unawaited(_toggleVoiceMessage(message)),
            playback: voicePlayback,
            messageId: message.id,
          ),
        RoomMessageKind.redPacket => message.packetId == null
            ? WeChatRedPacketCard(
                greeting: message.greeting ?? '恭喜发财',
                state: RedPacketVisualState.available,
                labelOverride: '状态未知',
                onTap: null,
              )
            : FinanceMessageEntry(
                key: ValueKey(
                    'finance:red-packet:${message.packetId}:${message.id}'),
                store: _financeCardStore,
                api: widget.api,
                kind: FinanceCardKind.redPacket,
                id: message.packetId!,
                greeting: message.greeting ?? '恭喜发财，大吉大利',
                amount: '--',
                isOwn: message.isOwn,
                senderName: _senderDisplayName(message),
                senderAvatar: _avatar(message),
                identityCache: _identityCache,
                redPacketMode: message.redPacketMode,
                packetOwnerMatrixId: message.senderId,
                sendClaimNotice: ({required String packetId,
                        required String ownerMatrixId}) =>
                    widget.roomLease.sendRedPacketClaimNotice(
                        packetId: packetId, ownerMatrixId: ownerMatrixId),
                restrictedRecipientName: _financeCounterpartyName(
                    message.redPacketRecipientMatrixId),
              ),
        RoomMessageKind.transfer => message.transferId == null
            ? WeChatTransferCard(
                amount: message.transferAmount ?? '--',
                state: TransferCardState.pending,
                isOwn: message.isOwn,
                labelOverride: '状态未知',
                onTap: null,
              )
            : FinanceMessageEntry(
                key: ValueKey(
                    'finance:transfer:${message.transferId}:${message.id}'),
                store: _financeCardStore,
                api: widget.api,
                kind: FinanceCardKind.transfer,
                id: message.transferId!,
                greeting: message.greeting ?? '',
                amount: message.transferAmount ?? '--',
                isOwn: message.isOwn,
                senderName: _senderDisplayName(message),
                senderAvatar: _avatar(message),
                identityCache: _identityCache,
                restrictedRecipientName:
                    _financeCounterpartyName(message.transferReceiverMatrixId),
              ),
        RoomMessageKind.system => Text(
            message.text,
            style: const TextStyle(
              color: WeChatColors.textSecondary,
              fontSize: 13,
            ),
          ),
        RoomMessageKind.video => VideoMessageCard(
            duration: message.videoDuration,
            posterLoader: () => _loadVideoPoster(message.id),
            onOpen: () => unawaited(_openVideoViewer(message)),
          ),
        RoomMessageKind.call => WeChatCallBubble(
            video: message.callVideo,
            connected: message.callConnected,
            duration: message.callDuration,
            // BUG-14：点击通话摘要直接按原类型回拨；无对端资料
            // （群聊/资料未加载）时不动作。
            onRedial: peer == null
                ? null
                : () {
                    // BUG-14 真机回归修订：拨打是异步的，立即给出可见反馈。
                    _showMediaMessage(
                        message.callVideo ? '正在发起视频通话…' : '正在发起语音通话…');
                    if (message.callVideo) {
                      unawaited(
                          widget.onVideo?.call(peer!) ?? Future<void>.value());
                    } else {
                      unawaited(
                          widget.onVoice?.call(peer!) ?? Future<void>.value());
                    }
                  },
          ),
        RoomMessageKind.text => KeyedSubtree(
            key: _messageTextKeys.putIfAbsent(message.stableId, GlobalKey.new),
            child: EmojiText(message.text)),
      };

  String _formatTime(DateTime timestamp) {
    final local = timestamp.toLocal();
    final now = DateTime.now();
    final time = '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return time;
    }
    if (local.year == now.year) return '${local.month}月${local.day}日 $time';
    return '${local.year}年${local.month}月${local.day}日 $time';
  }

  String _nudgeNoticeText(RoomMessageViewModel message) {
    final nudge = message.nudge;
    if (nudge == null) return message.text;
    MatrixRoomMemberSnapshot? member(String userId) {
      for (final participant in roomInfo.members) {
        if (participant.id == userId) return participant;
      }
      return null;
    }

    return formatNudgeNotice(
      viewerId: roomInfo.currentUserId ?? '',
      senderId: nudge.senderId,
      senderName: nudge.senderName,
      targetUserId: nudge.targetUserId,
      targetName: nudge.targetName,
      suffix: nudge.suffix,
      viewerRemarkForTarget:
          contactsByMatrixId[nudge.targetUserId]?.displayName,
      targetLiveName: member(nudge.targetUserId)?.displayName,
      senderLiveName: member(nudge.senderId)?.displayName,
    );
  }

  String _senderDisplayName(RoomMessageViewModel message) {
    MatrixRoomMemberSnapshot? member;
    for (final participant in roomInfo.members) {
      if (participant.id == message.senderId) {
        member = participant;
        break;
      }
    }
    // 联系人投影属于当前账号；自己的备注只在本机呈现，不写入消息。
    return _identityCache
        .resolveIdentity(
          matrixUserId: message.senderId,
          displayName: member?.displayName,
        )
        .displayName;
  }

  Future<void> _openMessageSender(RoomMessageViewModel message) =>
      _openPeerProfile(message.senderId);

  // Public identity only: mention and nudge payloads reach other participants.
  String _publicSenderName(RoomMessageViewModel message) =>
      resolveMessageSenderDisplayName(
        senderId: message.senderId,
        contactDisplayName:
            contactsByMatrixId[message.senderId]?.primaryDisplayName,
        matrixDisplayName: _member(message.senderId).displayName,
      );

  Widget _messageRow(RoomMessageViewModel message, DateTime? previousTime) {
    PerformanceMetrics.instance.increment(PerformanceCounter.messageRowBuild);
    final displayName = _senderDisplayName(message);
    final publicDisplayName = _publicSenderName(message);
    if (message.isRecalled) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: message.isOwn
              ? Wrap(
                  children: [
                    const Text(
                      '你撤回了一条消息 ',
                      style: TextStyle(
                        color: WeChatColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    if (recalledDrafts.containsKey(message.id))
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        minimumSize: Size.zero,
                        onPressed: () => setState(() {
                          input.text = recalledDrafts[message.id] ?? '';
                          input.selection = TextSelection.collapsed(
                            offset: input.text.length,
                          );
                        }),
                        child: Text(
                          '重新编辑',
                          style: TextStyle(
                            color: WeChatColors.resolve(
                              context,
                              WeChatColors.socialLink,
                            ),
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                )
              : Text(
                  isGroup ? '$displayName 撤回了一条消息' : '对方撤回了一条消息',
                  style: const TextStyle(
                    color: WeChatColors.textSecondary,
                    fontSize: 13,
                  ),
                ),
        ),
      );
    }
    final replied = message.replyToEventId == null
        ? null
        : controller?.findMessage(message.replyToEventId!);
    // 纯动效表情消息：按微信习惯去气泡，放大渲染动画表情。
    final animatedEmojis = message.kind == RoomMessageKind.text
        ? fluentEmojisInMessage(message.text)
        : const <FluentEmoji>[];
    final isAnimatedEmojiMessage = animatedEmojis.isNotEmpty;
    final isImageMessage = message.kind == RoomMessageKind.image;
    void appendMentionDraft() {
      if (!isGroup) return;
      // 规格#3：头像长按快速 @——经统一模型登记 token；R3 修复：
      // 走 _setComposerText（不走监听器差分，防同次编辑二次应用导致
      // token 失效）。
      final caret = mentionComposer.appendAtEnd(
        displayName: publicDisplayName,
        userId: message.senderId,
      );
      _setComposerText(mentionComposer.text, caret);
    }

    // 即时反馈语义：本地/发送中的消息视觉上等同已发出（无转圈/半透明，
    // 不增加加载感知）；网络原因的失败与终局失败同样显示红色感叹号
    // （2026-09-19 用户修订：未发出必须及时警告，点击立即重发），区别在
    // waitingNetwork 会在网络恢复后自动重发，failed 仅点击重试。
    final deliveryState = switch (message.deliveryState) {
      RoomDeliveryState.local ||
      RoomDeliveryState.sending ||
      RoomDeliveryState.sent =>
        MessageDeliveryState.sent,
      RoomDeliveryState.waitingNetwork => MessageDeliveryState.waitingNetwork,
      RoomDeliveryState.failed => MessageDeliveryState.failed,
    };
    final body = Column(
      children: [
        if (shouldShowMessageTimeSeparator(previousTime, message.timestamp))
          Padding(
            key: ValueKey('message-time-${message.id}'),
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              _formatTime(message.timestamp),
              style: const TextStyle(
                color: WeChatColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        if (message.kind == RoomMessageKind.system)
          WeChatNudgeNotice(text: _nudgeNoticeText(message))
        else if (isAnimatedEmojiMessage)
          // 纯动效表情（超级表情）：微信式无气泡大图渲染，但与普通消息
          // 同布局展示头像与昵称/备注，消息来源可识别，长按可操作。
          SuperEmojiMessage(
            bubbleKey:
                menuAnchorKeys.putIfAbsent(message.stableId, GlobalKey.new),
            key: ValueKey('animated-emoji-${message.stableId}'),
            emojis: animatedEmojis,
            direction: message.isOwn
                ? MessageDirection.outgoing
                : MessageDirection.incoming,
            state: deliveryState,
            onRetry: () => _trackAction(() => _retryMessage(message)),
            senderName: message.isOwn ? null : displayName,
            avatar: _avatar(message),
            onAvatarTap: () => _openMessageSender(message),
            onAvatarDoubleTap: () =>
                _trackAction(() => _sendNudge(message, publicDisplayName)),
            onAvatarLongPress: appendMentionDraft,
            onLongPress: () => unawaited(_showMessageActions(
                message, menuLinks.putIfAbsent(message.id, () => LayerLink()))),
          )
        else if (message.kind == RoomMessageKind.video)
          // 微信式视频消息：无气泡媒体卡（缩略图+播放按钮+时长），
          // 点击全屏播放；头像/昵称与图片消息一致。
          WeChatMessageBubble(
            key: ValueKey('video-message-${message.stableId}'),
            bubbleKey:
                menuAnchorKeys.putIfAbsent(message.stableId, GlobalKey.new),
            decorateContent: false,
            content: VideoMessageCard(
              posterIdentity: message.id,
              posterRevision: _posterRevisions[message.id] ?? 0,
              duration: message.videoDuration,
              posterLoader: () => _loadVideoPoster(message.id),
              onOpen: () => unawaited(_openVideoViewer(message)),
            ),
            senderBadge: message.isOwn ? null : _senderBadge(message),
            senderName: message.isOwn ? null : displayName,
            avatar: _avatar(message),
            onAvatarTap: () => _openMessageSender(message),
            onAvatarDoubleTap: () =>
                _trackAction(() => _sendNudge(message, publicDisplayName)),
            onAvatarLongPress: appendMentionDraft,
            onLongPress: () => unawaited(_showMessageActions(
                message, menuLinks.putIfAbsent(message.id, () => LayerLink()))),
            direction: message.isOwn
                ? MessageDirection.outgoing
                : MessageDirection.incoming,
            state: deliveryState,
            onRetry: () =>
                unawaited(_trackAction(() => _retryMessage(message))),
          )
        else if (isImageMessage && message.isFlashPhoto)
          // 闪照：马赛克无气泡媒体卡；长按菜单不含转发（能力过滤）。
          WeChatMessageBubble(
            key: ValueKey('flash-message-${message.stableId}'),
            bubbleKey:
                menuAnchorKeys.putIfAbsent(message.stableId, GlobalKey.new),
            decorateContent: false,
            content: _flashPhotoBubble(message),
            senderBadge: message.isOwn ? null : _senderBadge(message),
            senderName: message.isOwn ? null : displayName,
            avatar: _avatar(message),
            onAvatarTap: () => _openMessageSender(message),
            onAvatarDoubleTap: () =>
                _trackAction(() => _sendNudge(message, publicDisplayName)),
            onAvatarLongPress: appendMentionDraft,
            onLongPress: () => unawaited(_showMessageActions(
                message, menuLinks.putIfAbsent(message.id, () => LayerLink()))),
            direction: message.isOwn
                ? MessageDirection.outgoing
                : MessageDirection.incoming,
            state: deliveryState,
            onRetry: () =>
                unawaited(_trackAction(() => _retryMessage(message))),
          )
        else if (isImageMessage)
          // 微信式图片消息（R7 修复：ContainImageBubble 替换
          // EncryptedImageMessage——按解码实际宽高 contain 完整适配，
          // 不再固定 200x150 cover 裁切）。缩略图优先逻辑保留。
          WeChatMessageBubble(
            key: ValueKey('image-message-${message.stableId}'),
            decorateContent: false,
            content: LayoutBuilder(
              builder: (context, constraints) {
                return ContainImageBubble(
                  bubbleKey: menuAnchorKeys.putIfAbsent(
                    message.stableId,
                    GlobalKey.new,
                  ),
                  key: ValueKey('image-${message.stableId}'),
                  sourceIdentity: (
                    message.stableId,
                    _previewKey(message).identity
                  ),
                  initialBytes: _cachedImagePreview(message),
                  loadCached: () => _readCachedImagePreview(message),
                  isScrolling: messageListScrolling,
                  deferLoading:
                      message.deliveryState == RoomDeliveryState.sending &&
                          message.id == message.stableId,
                  sourceSize: _imageSourceSize(message),
                  load: () => _loadImagePreview(message),
                  availableWidth: constraints.maxWidth,
                  availableHeight: MediaQuery.of(context).size.height,
                  onTap: () =>
                      _trackAction(() => _openImageViewerWithForward(message)),
                );
              },
            ),
            senderName: message.isOwn ? null : displayName,
            senderBadge: message.isOwn ? null : _senderBadge(message),
            avatar: _avatar(message),
            onAvatarTap: () => _openMessageSender(message),
            onAvatarDoubleTap: () =>
                _trackAction(() => _sendNudge(message, publicDisplayName)),
            onAvatarLongPress: appendMentionDraft,
            onLongPress: () => unawaited(_showMessageActions(
                message, menuLinks.putIfAbsent(message.id, () => LayerLink()))),
            direction: message.isOwn
                ? MessageDirection.outgoing
                : MessageDirection.incoming,
            state: deliveryState,
            onRetry: () =>
                unawaited(_trackAction(() => _retryMessage(message))),
          )
        else
          WeChatMessageBubble(
            content: _messageContent(message),
            bubbleKey:
                menuAnchorKeys.putIfAbsent(message.stableId, GlobalKey.new),
            onRetry: () =>
                unawaited(_trackAction(() => _retryMessage(message))),
            decorateContent: messageBubbleIsDecorated(message.kind),
            senderName: message.isOwn ? null : displayName,
            senderBadge: message.isOwn ? null : _senderBadge(message),
            avatar: _avatar(message),
            onAvatarTap: () => _openMessageSender(message),
            onAvatarDoubleTap: () =>
                _trackAction(() => _sendNudge(message, publicDisplayName)),
            onAvatarLongPress: appendMentionDraft,
            onLongPress: () => unawaited(_showMessageActions(
                message, menuLinks.putIfAbsent(message.id, () => LayerLink()))),
            direction: message.isOwn
                ? MessageDirection.outgoing
                : MessageDirection.incoming,
            state: deliveryState,
          ),
        if (message.replyToEventId != null)
          Align(
            alignment:
                message.isOwn ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(
                left: message.isOwn ? 0 : WeChatDimensions.messageAvatar + 8,
                right: message.isOwn ? WeChatDimensions.messageAvatar + 8 : 0,
              ),
              child: QuotePreviewCard(
                message: replied,
                excerpt: message.replyExcerpt,
                targetEventId: message.replyToEventId!,
                resolution: _replyResolution(message.replyToEventId!),
                displayName: replied == null
                    ? '引用消息'
                    : _displayName(replied.senderId, replied.isOwn),
                onTap: () => unawaited(_jumpFromQuote(message)),
                // 失败态点击重试走状态机（清掉终局结果再发一次请求），
                // 而不是直接调用底层查询（那会被终局缓存挡住）。
                onRetry: () => unawaited(
                    replyResolver?.retry(message.replyToEventId!) ??
                        Future.value()),
              ),
            ),
          ),
      ],
    );
    final linked = CompositedTransformTarget(
      link: menuLinks.putIfAbsent(message.id, () => LayerLink()),
      child: body,
    );
    if (!selection.active) return linked;
    final selected = selection.selectedIds.contains(message.id);
    return Row(
      children: [
        CupertinoButton(
          key: ValueKey('message-select-${message.id}'),
          minimumSize: const Size.square(44),
          padding: EdgeInsets.zero,
          onPressed: () => setState(() => selection.toggle(message.id)),
          child: Icon(
            selected
                ? CupertinoIcons.checkmark_circle_fill
                : CupertinoIcons.circle,
            color: selected
                ? WeChatColors.brandPrimary
                : WeChatColors.textSecondary,
          ),
        ),
        Expanded(child: linked),
      ],
    );
  }

  MessageContentKind _contentKind(RoomMessageViewModel message) =>
      switch (message.kind) {
        RoomMessageKind.image => message.mimeType == 'image/gif'
            ? MessageContentKind.gif
            : MessageContentKind.image,
        RoomMessageKind.video => MessageContentKind.video,
        RoomMessageKind.file => MessageContentKind.file,
        RoomMessageKind.voice => MessageContentKind.voice,
        RoomMessageKind.call => MessageContentKind.call,
        RoomMessageKind.redPacket => MessageContentKind.redPacket,
        RoomMessageKind.transfer => MessageContentKind.transfer,
        RoomMessageKind.system => MessageContentKind.system,
        RoomMessageKind.text => MessageContentKind.text,
      };

  /// 长按消息气泡：立即触觉震动 + 气泡正上方锚定快捷菜单
  /// （复制第一位；严禁屏幕底部全局弹层）。
  Future<void> _showMessageActions(
    RoomMessageViewModel message,
    LayerLink anchor,
  ) async {
    MessageTextSelectionSession.dismissActive();
    unawaited(HapticFeedback.mediumImpact());
    // Opening a local menu must not wait for network time. Recall is checked
    // again against server time by _handleMessageAction before submission.
    final menuNow = DateTime.now();
    if (!mounted) return;
    final actions = MessageActionPolicy.actionsFor(
      MessageCapabilities(
        kind: _contentKind(message),
        isSent: message.deliveryState == RoomDeliveryState.sent,
        isOwn: message.isOwn,
        sentAt: message.timestamp,
        serverNow: menuNow,
        isFlashPhoto: message.isFlashPhoto,
      ),
    );
    if (message.kind == RoomMessageKind.voice &&
        message.deliveryState == RoomDeliveryState.sent) {
      actions.add(
        voicePlayback.earpiece
            ? MessageAction.voiceSpeaker
            : MessageAction.voiceEarpiece,
      );
    }
    if (actions.isEmpty) return;
    dismissActionMenu();
    final isOwn = message.isOwn;
    final overlay = Overlay.of(context, rootOverlay: true);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    final messageBox =
        menuAnchorKeys[message.stableId]?.currentContext?.findRenderObject();
    if (overlayBox == null ||
        messageBox is! RenderBox ||
        !messageBox.attached) {
      return;
    }
    final position = messageBox.localToGlobal(
      Offset.zero,
      ancestor: overlayBox,
    );
    final anchorRect = position & messageBox.size;
    if (message.kind == RoomMessageKind.text &&
        message.deliveryState == RoomDeliveryState.sent) {
      MessageTextSelectionSession.show(
        roomContext: context,
        text: message.text,
        textKey: _messageTextKeys.putIfAbsent(message.stableId, GlobalKey.new),
        messageRect: anchorRect,
        isOwn: isOwn,
        fullActions: actions,
        onAction: (action, selectedText) => unawaited(_trackAction(
          () =>
              _handleMessageAction(message, action, overrideText: selectedText),
        )),
        onDismissed: dismissActionMenu,
      );
      return;
    }
    actionMenuEntry = OverlayEntry(
      builder: (overlayContext) {
        final media = MediaQuery.of(overlayContext);
        final placement = MessageMenuPlacement.calculate(
          anchor: anchorRect,
          viewport: Rect.fromLTRB(
              8,
              media.padding.top + 8,
              overlayBox.size.width - 8,
              overlayBox.size.height -
                  media.viewInsets.bottom -
                  media.padding.bottom -
                  8),
          menuSize: Size(272, actions.length > 4 ? 128 : 72),
          outgoing: isOwn,
        );
        return Stack(children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: dismissActionMenu,
              child: const ColoredBox(color: Color(0x1A000000)),
            ),
          ),
          Positioned.fromRect(
            rect: placement.rect,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: MediaQuery.disableAnimationsOf(overlayContext)
                  ? Duration.zero
                  : const Duration(milliseconds: 120),
              builder: (_, value, child) => Opacity(
                  opacity: value,
                  child:
                      Transform.scale(scale: .96 + .04 * value, child: child)),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: MessageBubbleMenu(
                    arrowAtTop: placement.arrowAtTop,
                    arrowX: placement.arrowX,
                    actions: actions,
                    onSelected: (action) {
                      dismissActionMenu();
                      MessageTextSelectionSession.dismissActive();
                      unawaited(_trackAction(
                          () => _handleMessageAction(message, action)));
                    },
                  ),
                ),
              ),
            ),
          ),
        ]);
      },
    );
    overlay.insert(actionMenuEntry!);
  }

  void dismissActionMenu() {
    actionMenuEntry?.remove();
    actionMenuEntry = null;
  }

  /// 局部选择模式下的“引用/转发”以选中文字为操作对象：
  /// 构造仅文字替换的消息视图副本（事件 ID 不变，供引用关联）。
  RoomMessageViewModel _withSelectedText(
      RoomMessageViewModel message, String selectedText) {
    return RoomMessageViewModel(
      id: message.id,
      senderId: message.senderId,
      text: selectedText,
      isOwn: message.isOwn,
      deliveryState: message.deliveryState,
      timestamp: message.timestamp,
      kind: RoomMessageKind.text,
    );
  }

  Future<void> _handleMessageAction(
    RoomMessageViewModel message,
    MessageAction action, {
    String? overrideText,
  }) async {
    if (message.deliveryState != RoomDeliveryState.sent &&
        action != MessageAction.copy) {
      return;
    }
    switch (action) {
      case MessageAction.voiceEarpiece:
      case MessageAction.voiceSpeaker:
        if (!_canPlayVoice) {
          _showMediaMessage('通话或录音中暂时不能切换语音播放方式');
          return;
        }
        await voicePlayback.setEarpiece(action == MessageAction.voiceEarpiece);
        if (mounted && !_disposing) {
          _showMediaMessage(
            voicePlayback.hasFailed(message.id)
                ? '播放方式切换失败，请重试'
                : voicePlayback.earpiece
                    ? '已切换为听筒播放'
                    : '已切换为扬声器播放',
          );
        }
      case MessageAction.copy:
        // 规格 #2：导出纯文本时按表情映射表把 emoji 转为 [表情名称]；
        // 整条复制与局部选择复制共用此路径。
        final copyText = emojiToShortcodes(overrideText ?? message.text);
        await Clipboard.setData(ClipboardData(text: copyText));
        if (mounted) _showMediaMessage('已复制');
      case MessageAction.selectAll:
        // 仅文本选择模式可达：会话内部已恢复整条选择，这里无需动作。
        break;
      case MessageAction.deleteLocal:
        if (hiddenEvents == null) return;
        await hiddenEvents!.hide(roomInfo.id, message.id);
        unreadMentions?.onRedacted(message.id);
        await widget.roomLease.saveMentions();
        controller?.setHiddenFilter(hiddenEvents?.readFilter(roomInfo.id));
        await controller?.refresh();
        if (mounted) setState(() {});
      case MessageAction.multiSelect:
        setState(() => selection.startWith(message.id));
      case MessageAction.forward:
        // 局部选择：转发内容保持精确的选中文字；仅复制才转短代码。
        await _forwardMessages([
          message,
        ], selectedTextOverride: overrideText);
      case MessageAction.reply:
        // 局部选择：引用以选中文字为引用片段（事件 ID 保持关联原消息）。
        setState(() {
          replyingTo = overrideText != null
              ? _withSelectedText(message, overrideText)
              : message;
          _selectedReplyExcerpt = overrideText;
        });
      case MessageAction.recall:
        final sourceLease = widget.roomLease.leaseForEvent(message.id);
        final interaction = roomInfo.currentUserId == null
            ? null
            : MessageInteractionService(
                backend: sourceLease,
                roomId: sourceLease.roomId,
                currentUserId: roomInfo.currentUserId!);
        final serverNow = await sourceLease.serverNow();
        if (interaction == null || serverNow == null) return;
        recalledDrafts[message.id] = message.text;
        await interaction.recall(
          MessageInteractionEvent(
            id: message.id,
            senderId: message.senderId,
            originServerTs: message.timestamp,
          ),
          serverNow: serverNow,
        );
        await controller?.refresh();
      case MessageAction.addToEmoji:
        await _addMessageToEmoji(message);
      case MessageAction.reminder:
        await _showReminderPicker(message);
    }
  }

  /// 群聊中发送者的头衔徽标（QQ 式）：群主橙红、管理员蓝；
  /// 私聊/非群成员返回 null。powerLevel：群主 ≥100、管理员 ≥50。
  Widget? _senderBadge(RoomMessageViewModel message) {
    if (!isGroup) return null;
    try {
      final member = _member(message.senderId);
      final level = member.powerLevel;
      if (level >= 100) {
        return _RoleBadge(label: '群主', color: const Color(0xFFF59A23));
      }
      if (level >= 50) {
        return _RoleBadge(label: '管理员', color: const Color(0xFF3E8BFF));
      }
    } catch (_) {
      // 成员不在内存缓存时无头衔，不影响消息展示。
    }
    return null;
  }

  bool _isForwardable(String eventId, List<RoomMessageViewModel> messages) {
    final message = controller?.findMessage(eventId);
    return message != null &&
        !message.isRecalled &&
        MessageActionPolicy.isForwardable(_contentKind(message));
  }

  Future<void> _deleteSelection() async {
    final store = hiddenEvents;
    if (store == null) return;
    for (final eventId in selection.selectedIds) {
      await store.hide(roomInfo.id, eventId);
      unreadMentions?.onRedacted(eventId);
    }
    await widget.roomLease.saveMentions();
    if (!mounted) return;
    controller?.setHiddenFilter(hiddenEvents?.readFilter(roomInfo.id));
    await controller?.refresh();
    if (mounted) setState(selection.exit);
  }

  /// 转发：独立“选择聊天”页选择接收对象，再确认发送。
  /// 多选复制（规格 #2）：按时间线顺序合并所选文本消息，
  /// emoji 按表情映射表转 [表情名称] 纯文本后写入剪贴板。
  Future<void> _copySelectedMessages() async {
    final all = controller?.messages ?? const <RoomMessageViewModel>[];
    final copied = [
      for (final message in all)
        if (selection.selectedIds.contains(message.id) &&
            message.kind == RoomMessageKind.text &&
            !message.isRecalled)
          emojiToShortcodes(message.text),
    ];
    if (copied.isEmpty) {
      if (mounted) _showMediaMessage('所选内容中没有可复制的文字');
      return;
    }
    await Clipboard.setData(ClipboardData(text: copied.join('\n')));
    if (mounted) _showMediaMessage('已复制 ${copied.length} 条文字');
  }

  Future<void> _forwardMessages(
    List<RoomMessageViewModel> messages, {
    String? selectedTextOverride,
  }) async {
    if (messages.isEmpty) return;
    final matrix = widget.roomLease;
    if (_disposing) return;
    if (messages.any((message) => message.isFlashPhoto)) {
      if (mounted) _showMediaMessage('闪照不支持转发');
      return;
    }
    late final List<MatrixOutgoingForwardMessage> frozen;
    try {
      frozen = <MatrixOutgoingForwardMessage>[
        for (var index = 0; index < messages.length; index++)
          matrix.leaseForEvent(messages[index].id).snapshotForwardSource(
                messages[index].id,
                selectedPlainText: selectedTextOverride != null && index == 0
                    ? selectedTextOverride
                    : null,
              ),
      ];
    } on StateError {
      if (mounted && !_disposing && identical(widget.roomLease, matrix)) {
        _showMediaMessage('该消息暂时无法转发，请稍后重试');
      }
      return;
    } on ArgumentError {
      if (mounted && !_disposing && identical(widget.roomLease, matrix)) {
        _showMediaMessage('该消息暂时无法转发，请稍后重试');
      }
      return;
    }
    if (selectedTextOverride != null && messages.length != 1) {
      throw ArgumentError('A selected range must belong to one message');
    }
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || _disposing || !identical(widget.roomLease, matrix)) {
      return;
    }
    final store = RecentForwardStore(prefs);
    final recentIds = store.load();
    final destinations = await matrix.forwardingDestinations();
    if (!mounted || _disposing || !identical(widget.roomLease, matrix)) {
      return;
    }
    List<ChatForwardCandidate> candidates() => <ChatForwardCandidate>[
          for (final room in destinations)
            ChatForwardCandidate(
              roomId: room.id,
              title: _forwardTitleFor(room),
              avatar: _forwardRoomAvatar(room),
              isGroup: !room.isDirect,
              memberCount: room.memberCount,
            ),
        ];
    if (candidates().isEmpty) {
      if (mounted) setState(() => mediaMessage = '没有可用的端到端加密会话');
      return;
    }
    final batchId = 'forward-${DateTime.now().microsecondsSinceEpoch}';
    final forwarded =
        await Navigator.of(context, rootNavigator: true).push<bool>(
      MotionPageRoute<bool>(
        builder: (_) => ListenableBuilder(
          listenable: _identityCache,
          builder: (context, child) => ChatForwardPickerPage(
            identityChanges: _identityCache,
            resolveCandidates: candidates,
            candidates: candidates(),
            contentPreview: selectedTextOverride ??
                messages
                    .map(
                      (message) => switch (message.kind) {
                        RoomMessageKind.image => '[图片]',
                        RoomMessageKind.video => '[视频]',
                        RoomMessageKind.voice => '[语音]',
                        RoomMessageKind.file => '[文件] ${message.text}',
                        _ => message.text,
                      },
                    )
                    .join('\n'),
            recentRoomIds: [
              for (final id in recentIds)
                if (destinations.any((room) => room.id == id)) id,
            ],
            onForward: (roomIds) async {
              final jobs = await matrix.enqueueForward(
                batchId: batchId,
                messages: frozen,
                targetRoomIds: roomIds,
              );
              _trackForwardJobs(matrix, jobs);
              unawaited(store.record(roomIds).catchError((Object _) {}));
            },
          ),
        ),
      ),
    );
    if (!mounted ||
        _disposing ||
        !identical(widget.roomLease, matrix) ||
        forwarded != true) {
      return;
    }
    setState(() {
      mediaMessage = '正在发送';
      selection.exit();
    });
  }

  String _forwardTitleFor(MatrixForwardDestinationSnapshot room) {
    final peer = room.directPeerId;
    if (peer != null) {
      return _identityCache
          .resolveIdentity(matrixUserId: peer, displayName: room.displayName)
          .displayName;
    }
    return room.displayName;
  }

  Widget _forwardRoomAvatar(MatrixForwardDestinationSnapshot room) {
    Widget avatar(String id, String name, Uri? uri) {
      final identity =
          _identityCache.resolveIdentity(matrixUserId: id, displayName: name);
      return MatrixUserAvatar(
          avatarMedia: widget.roomLease,
          nickname: identity.displayName,
          fallbackSeed: identity.cacheKey,
          matrixAvatarUri: identity.avatarIsKnown ? null : uri,
          fallbackAvatarUrl: identity.avatarUrl,
          size: 52);
    }

    if (room.isDirect || room.avatarUri != null || room.members.isEmpty) {
      return avatar(room.isDirect ? (room.directPeerId ?? room.id) : room.id,
          room.displayName, room.avatarUri);
    }
    return GroupAvatarMosaic(size: 52, avatars: [
      for (final member in room.members.take(9))
        avatar(member.id, member.displayName, member.avatarUri),
    ]);
  }

  /// 正式的房间导航契约：全局搜索/深链可携带 anchorEventId 打开房间，
  /// 进入后定位并高亮该消息（不使用全局变量或 SharedPreferences 传参）。
  bool _initialAnchorApplied = false;

  void _applyInitialAnchorIfNeeded() {
    final anchor = widget.navigationRequests?.value.anchorEventId ??
        widget.initialAnchorEventId;
    if (_initialAnchorApplied || anchor == null || anchor.isEmpty) return;
    final timeline = controller;
    if (timeline == null || timeline.messages.isEmpty) return;
    _initialAnchorApplied = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_navigateToLogicalAnchor(
          anchor,
          widget.navigationRequests?.value.anchorRoomId ??
              widget.initialAnchorRoomId));
    });
  }

  /// 把本机已解密、用户可见的消息投影进全局搜索索引（device-side only：
  /// 不落盘、不上传；闪照/撤回/空白正文永不进入）。
  ///
  /// Task B：写入账号维度的 [LocalMessageSearchRepository]（默认**合并**，
  /// 不再按房间覆盖式截断），因此回填来的更早历史不会被当前时间线丢掉。
  /// E1：搜索索引**增量**投影——旧实现在每次时间线变化时把房间全部
  /// 消息重建进索引（O(N log N) 分配+排序，UI 线程执行）。活跃群聊里
  /// 每条新消息都触发一遍，低端机在键盘输入时直接卡死数秒。现在只为
  /// 新出现的消息构建条目，突发合并为一次提交（400ms 去抖），撤回联动删除。
  void _recordGlobalSearchIndex() {
    final timeline = controller;
    if (timeline == null) return;
    final seenIds = <String>[];
    final indexableIds = <String>{};
    final recalledIds = <String>{};
    final freshById = <String, RoomMessageViewModel>{};
    for (final message in timeline.allMessages) {
      seenIds.add(message.stableId);
      if (message.isRecalled) {
        recalledIds.add(message.stableId);
        continue;
      }
      if (message.isFlashPhoto ||
          message.isSdkLocalEcho ||
          message.text.trim().isEmpty) {
        continue;
      }
      indexableIds.add(message.stableId);
      if (!freshById.containsKey(message.stableId)) {
        freshById[message.stableId] = message;
      }
    }
    final observation = _searchIndexScheduler.observe(
      seenIds: seenIds,
      indexableIds: indexableIds,
      recalledIds: recalledIds,
    );
    if (observation.toIndex.isEmpty && observation.toRemove.isEmpty) return;
    final fresh = [
      for (final id in observation.toIndex)
        if (freshById[id] case final RoomMessageViewModel message)
          LocalSearchMessage(
            eventId: message.id,
            senderId: message.senderId,
            senderName: _senderDisplayName(message),
            timestamp: message.timestamp,
            body: message.text,
            roomId: (_logicalTimeline is RoomEventSourceCapability
                    ? (_logicalTimeline as RoomEventSourceCapability)
                        .sourceRoomId(message.id)
                    : null) ??
                roomInfo.id,
            roomName: roomInfo.name,
            isGroup: isGroup,
            senderIsSelf: message.isOwn,
            roomAvatarSeed: roomInfo.id,
            isFlashPhoto: message.isFlashPhoto,
          ),
    ];
    final removed = List<String>.of(observation.toRemove);
    _searchIndexDebounce?.cancel();
    _searchIndexDebounce = Timer(const Duration(milliseconds: 400), () {
      if (_disposing) return;
      if (fresh.isNotEmpty) {
        LocalMessageSearchRepository.shared.recordRoomMessages(fresh);
      }
      if (removed.isNotEmpty) {
        LocalMessageSearchRepository.shared.removeMessages(removed);
      }
    });
  }

  @override
  void dispose() {
    callAudioActivity.removeListener(_handleCallAudioActivity);
    _disposing = true;
    dismissActionMenu();
    // 切换会话/退出会话页：取消文本选择弹层（根 Overlay 不随页面销毁）。
    MessageTextSelectionSession.dismissActive();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(RoomDraftStore.shared.flush(_draftKey));
    latestMessageAnchor.dispose();
    messageListScrolling.dispose();
    roomImagePreviewCache.dispose();
    imageMemoryCache.dispose();
    thumbnailMemoryCache.dispose();
    unawaited(videoPosterCache
        .clearAll()
        .whenComplete(_posterDisk.dispose)
        .catchError((Object _) {}));
    _identityCache.removeListener(_identityChanged);
    _nudgeToastTimer?.cancel();
    _nudgeToast?.remove();
    _supportTimer?.cancel();
    _supportIdentities.dispose();
    final playback = _voicePlayback;
    if (playback != null) {
      unawaited(_trackMatrixOperation(
          playback.stopAll().whenComplete(playback.dispose)));
    }
    unawaited(_trackMatrixOperation(_onVoiceCancel(VoiceArmedTarget.cancel)));
    _timelineRevision.dispose();
    _mentionRevision.dispose();
    replyResolver?.dispose();
    replyResolver = null;
    _observedTimelineScrollPosition?.isScrollingNotifier
        .removeListener(_onTimelineScrollActivityChanged);
    widget.navigationRequests?.removeListener(_onNavigationRequest);
    controller?.removeListener(_changed);
    _observedOutbox?.removeListener(_outboxChanged);
    _observedOutbox = null;
    controller?.dispose();
    final outboxSender = _outboxSender;
    if (outboxSender != null) {
      OutboxRoomSenderRegistry.shared.unregister(outboxSender);
      _outboxSender = null;
    }
    mediaMessageTimer?.cancel();
    _voiceMaxTimer?.cancel();
    _voiceTicker?.cancel();
    _readReceiptDebounce?.cancel();
    _mentionVisibilityTimer?.cancel();
    RoomMentionStore.shared.removeListener(_mentionStateChanged);
    final service = voiceService;
    if (service != null) unawaited(_trackMatrixOperation(service.dispose()));
    inputFocusNode.dispose();
    input.dispose();
    messageScrollController.removeListener(_onMessageScroll);
    _searchIndexDebounce?.cancel();
    ConversationReadState.shared().setRoomOpen(roomInfo.id, open: false);
    messageScrollController.dispose();
    super.dispose();
    _disposed.complete();
  }

  Timer? _readReceiptDebounce;
  String? _readReceiptTargetId;
  bool _readReceiptDirty = false;
  bool _readReceiptInFlight = false;
  int _readReceiptFailures = 0;

  bool get _canSyncReadReceipt =>
      mounted &&
      !_disposing &&
      !widget.roomLease.canceled &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState ==
              AppLifecycleState.resumed) &&
      ConversationReadState.shared().isRoomOpen(roomInfo.id);

  /// Local viewing state is independent of the SDK's server acknowledgement.
  void _syncReadReceiptWhileViewing({bool immediate = false}) {
    if (!_canSyncReadReceipt) return;
    if (_logicalTimeline is RoomVisibleReadCapability) {
      _immediateVisibleReceipt = _immediateVisibleReceipt || immediate;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _observeVisibleReadReceipts());
      return;
    }
    final newest = controller?.newestMessage;
    if (newest == null) return;
    ConversationReadState.shared().markCleared(roomInfo.id, eventId: newest.id);
    if (_readReceiptTargetId == newest.id) return;
    _readReceiptTargetId = newest.id;
    _readReceiptDirty = true;
    if (immediate) {
      unawaited(_trackMatrixOperation(_sendReadReceipt()));
    } else {
      _scheduleReadReceipt(const Duration(milliseconds: 800));
    }
  }

  void _scheduleReadReceipt(Duration delay) {
    if (!_canSyncReadReceipt || _readReceiptInFlight) return;
    _readReceiptDebounce?.cancel();
    _readReceiptDebounce = Timer(delay, () {
      if (!_canSyncReadReceipt || !_readReceiptDirty) return;
      unawaited(_trackMatrixOperation(_sendReadReceipt()));
    });
  }

  Future<void> _sendReadReceipt() async {
    if (!_canSyncReadReceipt || _readReceiptInFlight) return;
    final timeline = controller;
    if (timeline == null) return;
    _readReceiptInFlight = true;
    _readReceiptDirty = false;
    try {
      final capability = _logicalTimeline;
      if (capability is RoomVisibleReadCapability) {
        final ids = Set<String>.of(_visibleReadIds);
        await (capability as RoomVisibleReadCapability).markReadVisible(ids);
        _visibleReadIds.removeAll(ids);
        _acknowledgedVisibleIds.addAll(ids);
        while (_acknowledgedVisibleIds.length > 2048) {
          _acknowledgedVisibleIds.remove(_acknowledgedVisibleIds.first);
        }
      } else {
        await timeline.markRead();
      }
      _readReceiptFailures = 0;
    } catch (_) {
      // Preserve the pending receipt for retry; only the Matrix SDK may advance
      // server read markers. Offline failure never invalidates cached content.
      _readReceiptDirty = true;
      _readReceiptFailures = (_readReceiptFailures + 1).clamp(1, 6);
    } finally {
      _readReceiptInFlight = false;
      if (_readReceiptDirty) {
        _scheduleReadReceipt(_readReceiptFailures == 0
            ? const Duration(milliseconds: 800)
            : Duration(seconds: 5 * _readReceiptFailures));
      }
    }
  }

  /// 上滑接近顶部（reverse 列表像素增大方向）→ 自动加载更早历史。
  /// 加载中的幂等/耗尽判定由 [RoomTimelineController.loadHistory] 负责。
  void _onMessageScroll() {
    if (_shiftingWindow || _locatingMessage) return;
    if (!messageScrollController.hasClients) return;
    final position = messageScrollController.position;
    _observeTimelineScrollActivity(position);
    final previousOffset = _lastTimelineScrollOffset ?? 0;
    final offset = position.pixels;
    _lastTimelineScrollOffset = offset;
    final towardEarlier = offset > previousOffset + .5;
    final towardLater = offset < previousOffset - .5;
    if (offset > 80) {
      controller?.pinWindow();
    }
    _observeVisibleMentions();
    if (towardLater && position.extentBefore < 120) {
      // This listener precedes ScrollNotification for a user drag. Record
      // the direction before starting the request, otherwise that matching
      // notification would invalidate the request's own generation.
      _setTimelineScrollDirection(earlier: false);
      if (controller?.hasLaterWindow ?? false) {
        _queueWindowShift(earlier: false);
        unawaited(_applyPendingWindowShift());
      } else {
        unawaited(_prefetchFutureHistory());
      }
      return;
    }
    if (towardEarlier) unawaited(_prefetchHistory());
  }

  void _observeMessageScrollActivityIfAttached() {
    if (messageScrollController.hasClients) {
      _observeTimelineScrollActivity(messageScrollController.position);
    }
  }

  bool _shiftingWindow = false;
  bool? _timelineScrollTowardEarlier;
  bool _scrollInteractionActive() =>
      _userTimelineDragActive ||
      (messageScrollController.hasClients &&
          messageScrollController.position.isScrollingNotifier.value);

  void _observeTimelineScrollActivity(ScrollPosition position) {
    if (identical(_observedTimelineScrollPosition, position)) return;
    _observedTimelineScrollPosition?.isScrollingNotifier
        .removeListener(_onTimelineScrollActivityChanged);
    _observedTimelineScrollPosition = position;
    position.isScrollingNotifier.addListener(_onTimelineScrollActivityChanged);
  }

  void _onTimelineScrollActivityChanged() {
    if (!_scrollInteractionActive()) {
      unawaited(_applyPendingWindowShift());
    }
  }

  void _queueWindowShift({required bool earlier}) {
    _pendingEarlierWindow = earlier;
  }

  void _cancelPendingTimelineWindowShift({bool clearDirection = true}) {
    _pendingEarlierWindow = null;
    if (clearDirection) _timelineScrollTowardEarlier = null;
    _timelineScrollGeneration++;
  }

  void _setTimelineScrollDirection({required bool earlier}) {
    if (_timelineScrollTowardEarlier == earlier) return;
    _timelineScrollTowardEarlier = earlier;
    _cancelPendingTimelineWindowShift(clearDirection: false);
  }

  Future<void> _applyPendingWindowShift() async {
    if (_shiftingWindow ||
        _scrollInteractionActive() ||
        !mounted ||
        !messageScrollController.hasClients ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final earlier = _pendingEarlierWindow;
    if (earlier == null) return;
    final position = messageScrollController.position;
    final atRequestedEdge = earlier
        ? position.extentAfter <= position.viewportDimension * 2
        : position.extentBefore < 120;
    final hasWindow = earlier
        ? controller?.hasEarlierWindow ?? false
        : controller?.hasLaterWindow ?? false;
    if (!atRequestedEdge || !hasWindow) {
      _pendingEarlierWindow = null;
      return;
    }
    _pendingEarlierWindow = null;
    await _shiftWindow(earlier
        ? () => controller!.showEarlierWindow()
        : () => controller!.showLaterWindow());
  }

  Future<void> _shiftWindow(Future<void> Function() shift) async {
    if (_shiftingWindow || !mounted) return;
    _shiftingWindow = true;
    final generation = _timelineScrollGeneration;
    final anchor =
        TimelineScrollAnchor.capture(messageKeys, _timelineViewportKey);
    try {
      await shift();
      if (!mounted) return;
      _timelineRevision.value++;
      if (anchor != null) {
        await anchor.restore(
            controller: messageScrollController,
            keys: messageKeys,
            eventIds: _visibleMessages().reversed.map((m) => m.id).toList(),
            isMounted: () => mounted && !_disposing,
            canRestore: () =>
                generation == _timelineScrollGeneration &&
                !_scrollInteractionActive());
      }
    } finally {
      _shiftingWindow = false;
      _lastTimelineScrollOffset = messageScrollController.hasClients
          ? messageScrollController.offset
          : null;
    }
  }

  Future<void> _showLatestWindow() async {
    _cancelPendingTimelineWindowShift();
    await controller?.showLatest();
    if (!mounted) return;
    _timelineRevision.value++;
    await WidgetsBinding.instance.endOfFrame;
    if (mounted && messageScrollController.hasClients) {
      messageScrollController.jumpTo(0);
    }
  }

  Future<void>? _historyRequest;
  Future<void> _loadEarlier() => _historyRequest ??= () async {
        try {
          await controller?.loadHistory();
        } finally {
          _historyRequest = null;
        }
      }();

  Future<void>? _prefetchRequest;
  Future<void> _prefetchHistory() =>
      _prefetchRequest ??= _prefetchHistoryOnce().whenComplete(
        () => _prefetchRequest = null,
      );

  Future<void>? _futureHistoryRequest;
  Future<void> _prefetchFutureHistory() =>
      _futureHistoryRequest ??= _prefetchFutureHistoryOnce().whenComplete(
        () => _futureHistoryRequest = null,
      );

  Future<void> _prefetchFutureHistoryOnce() async {
    final currentController = controller;
    if (!mounted ||
        _locatingMessage ||
        _shiftingWindow ||
        currentController == null ||
        !messageScrollController.hasClients ||
        !currentController.hasFutureHistory ||
        messageScrollController.position.extentBefore >= 120 ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final generation = _timelineScrollGeneration;
    try {
      // A forward page can append newer rows before this user gesture ends.
      // Pin first so refresh preserves the visible window until the guarded
      // deferred shift runs after drag/ballistic motion has settled.
      currentController.pinWindow();
      await currentController.loadFutureHistory();
    } catch (_) {
      return;
    }
    if (!mounted ||
        generation != _timelineScrollGeneration ||
        !identical(currentController, controller) ||
        ModalRoute.of(context)?.isCurrent != true ||
        !(currentController.hasLaterWindow)) {
      return;
    }
    _queueWindowShift(earlier: false);
    await _applyPendingWindowShift();
  }

  Future<void> _prefetchHistoryOnce() async {
    if (!mounted ||
        _locatingMessage ||
        _shiftingWindow ||
        !messageScrollController.hasClients ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final metrics = messageScrollController.position;
    if (!metrics.hasContentDimensions ||
        metrics.extentAfter > metrics.viewportDimension * 2) {
      return;
    }
    if (!(controller?.hasEarlierWindow ?? false)) {
      final generation = _timelineScrollGeneration;
      final currentController = controller;
      final oldest = widget.roomLease.oldestTimelineEventId;
      final token = widget.roomLease.historyToken;
      try {
        await _loadEarlier();
      } catch (_) {
        return;
      }
      if (!mounted ||
          generation != _timelineScrollGeneration ||
          !identical(currentController, controller) ||
          ModalRoute.of(context)?.isCurrent != true ||
          (oldest == widget.roomLease.oldestTimelineEventId &&
              token == widget.roomLease.historyToken)) {
        return;
      }
    }
    if (controller?.hasEarlierWindow ?? false) {
      _queueWindowShift(earlier: true);
      await _applyPendingWindowShift();
    }
  }

  void _requestWindowForUserScrollDelta(double delta) {
    if (!messageScrollController.hasClients || delta == 0) return;
    final position = messageScrollController.position;
    if (delta < 0) {
      // Any deliberate move back toward newer history supersedes an older
      // prefetch, even when this update is not yet at the newer edge.
      _setTimelineScrollDirection(earlier: false);
      if (position.extentBefore < 120) {
        if (controller?.hasLaterWindow ?? false) {
          _queueWindowShift(earlier: false);
          unawaited(_applyPendingWindowShift());
        } else {
          unawaited(_prefetchFutureHistory());
        }
      }
      return;
    }
    if (delta > 0 && position.extentAfter <= position.viewportDimension * 2) {
      _setTimelineScrollDirection(earlier: true);
      unawaited(_prefetchHistory());
    }
  }

  Size? _imageSourceSize(RoomMessageViewModel message) {
    final width = message.imageWidth;
    final height = message.imageHeight;
    return width != null && height != null && width > 0 && height > 0
        ? Size(width.toDouble(), height.toDouble())
        : null;
  }

  bool _onTimelineScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification) {
      MessageTextSelectionSession.dismissActive();
      messageListScrolling.value = true;
      if (notification.dragDetails != null) {
        _observeMessageScrollActivityIfAttached();
        _userTimelineDragActive = true;
        _timelineScrollGeneration++;
      }
    }
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      _observeMessageScrollActivityIfAttached();
      if (!_userTimelineDragActive) {
        _userTimelineDragActive = true;
        _timelineScrollGeneration++;
      }
      _requestWindowForUserScrollDelta(notification.dragDetails!.delta.dy);
    }
    if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      _observeMessageScrollActivityIfAttached();
      if (!_userTimelineDragActive) {
        _userTimelineDragActive = true;
        _timelineScrollGeneration++;
      }
      _requestWindowForUserScrollDelta(notification.dragDetails!.delta.dy);
    }
    if (notification is ScrollEndNotification) {
      messageListScrolling.value = false;
      if (_userTimelineDragActive) {
        _userTimelineDragActive = false;
        unawaited(_applyPendingWindowShift());
      }
    }
    return false;
  }

  final _timelineRevision = ValueNotifier<int>(0);

  /// 引用原消息的加载状态机（单飞 + 3 秒超时 + 终局缓存 + 点击重试）。
  ///
  /// 与 `controller.findMessage` 的分工：本机 timeline 命中的引用直接渲染；
  /// 窗口外的引用（例如引用了 1000 条以前的消息）在这里按 event_id 解析，
  /// 成功写入 `MessageTimelineCache`，失败落到可重试的明确状态——绝不留下
  /// 永久的「原消息加载中」。
  ReplyMessageResolver? replyResolver;

  /// 本轮已排队的引用解析扫描，避免每帧重复排队。
  bool _replySweepScheduled = false;
  final _visibleIndex = <String, int>{};
  final _rowCache = <String,
      (
    RoomMessageViewModel,
    DateTime?,
    RoomMessageViewModel?,
    ReplyMessageStatus,
    Widget
  )>{};

  List<RoomMessageViewModel> _visibleMessages() {
    final all = controller?.messages ?? const <RoomMessageViewModel>[];
    final messages = hiddenEvents?.visibleItems(roomInfo.id, all,
            eventId: (m) => m.id, eventTimestamp: (m) => m.timestamp) ??
        all;
    _visibleIndex.clear();
    for (var i = 0; i < messages.length; i++) {
      _visibleIndex[messages[i].stableId] = i;
    }
    final ids = {for (final m in messages) m.id};
    _rowCache.removeWhere((id, _) => !_visibleIndex.containsKey(id));
    _stableMessageKeys.removeWhere((id, _) => !_visibleIndex.containsKey(id));
    messageKeys.removeWhere((id, _) => !ids.contains(id));
    _scheduleReplyResolutionSweep(messages);
    return messages;
  }

  /// 当前引用的加载状态：本机 timeline 命中即成功，否则取状态机结果。
  ReplyMessageResolution _replyResolution(String targetEventId) {
    final local = controller?.findMessage(targetEventId);
    if (local != null) return ReplyMessageResolution.resolved(local);
    return replyResolver?.stateOf(targetEventId) ??
        const ReplyMessageResolution.loading();
  }

  void _replyResolutionChanged() {
    if (!mounted || _disposing) return;
    _timelineRevision.value++;
  }

  /// 为可见消息中尚未命中的引用目标排队一次解析（每帧最多一批）。
  ///
  /// 扫描在 build 期间只做只读判定，真正的请求放到帧后执行，避免在
  /// build 中触发 `_timelineRevision` 变更。
  void _scheduleReplyResolutionSweep(List<RoomMessageViewModel> messages) {
    final resolver = replyResolver;
    if (resolver == null || _replySweepScheduled || _disposing) return;
    final pending = <String>[];
    final seen = <String>{};
    for (final message in messages) {
      final target = message.replyToEventId;
      if (target == null || !seen.add(target)) continue;
      if (controller?.findMessage(target) != null) continue;
      final state = resolver.stateOf(target);
      if (state != null && state.isSettled) continue;
      pending.add(target);
    }
    if (pending.isEmpty) return;
    _replySweepScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _replySweepScheduled = false;
      if (!mounted || _disposing) return;
      for (final target in pending) {
        unawaited(resolver.resolve(target));
      }
    });
  }

  Widget _cachedMessageRow(RoomMessageViewModel message, DateTime? previous) {
    final reply = message.replyToEventId == null
        ? null
        : controller?.findMessage(message.replyToEventId!);
    final resolution = message.replyToEventId == null
        ? const ReplyMessageResolution.loading()
        : _replyResolution(message.replyToEventId!);
    final cached = _rowCache[message.stableId];
    final sameReply = cached?.$3 == null
        ? reply == null
        : reply != null && cached!.$3!.samePresentation(reply);
    if (cached != null &&
        identical(cached.$1, message) &&
        cached.$2 == previous &&
        cached.$4 == resolution.status &&
        sameReply) {
      return cached.$5;
    }
    final row = Padding(
        key: ValueKey(message.stableId),
        padding: const EdgeInsets.only(bottom: WeChatSpacing.sm),
        child: KeyedSubtree(
            key: messageKeys[message.id] =
                _stableMessageKeys.putIfAbsent(message.stableId, GlobalKey.new),
            child: Stack(clipBehavior: Clip.none, children: [
              // 规格 #3：高亮背景从屏幕左缘覆盖到右缘（负偏移抵消列表
              // 水平内边距），上下各外扩 4pt——正好到相邻气泡 8pt 间隙的
              // 中线，不会覆盖相邻消息；闪烁后归零，不残留。
              Positioned(
                left: -WeChatSpacing.md,
                right: -WeChatSpacing.md,
                top: -4,
                bottom: -4,
                child: IgnorePointer(
                  child: MessageHighlightPulse(
                    active: highlightedMessageId == message.id,
                    child: DecoratedBox(
                        decoration: BoxDecoration(
                            color: highlightedMessageId == message.id
                                ? WeChatColors.resolve(
                                    context, WeChatColors.divider)
                                : const Color(0x00000000))),
                  ),
                ),
              ),
              _messageRow(message, previous),
            ])));
    _rowCache[message.stableId] =
        (message, previous, reply, resolution.status, row);
    return row;
  }

  Widget _buildTimeline() {
    final messages = _visibleMessages();
    final list = GestureDetector(
      key: _timelineViewportKey,
      behavior: HitTestBehavior.translucent,
      onTap: _dismissComposerExtensions,
      child: loading
          ? const Center(child: CupertinoActivityIndicator())
          : errorMessage != null
              ? Center(child: Text(errorMessage!))
              : messages.isEmpty
                  ? const SizedBox.expand()
                  : NotificationListener<ScrollNotification>(
                      onNotification: _onTimelineScrollNotification,
                      child: ListView.builder(
                        controller: messageScrollController,
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: WeChatSpacing.md,
                          vertical: WeChatSpacing.sm,
                        ),
                        // 顶部状态行（视觉上的最上方）：加载历史中
                        // 显示 loading，历史取尽显示"没有更多了"。
                        itemCount: messages.length,
                        findChildIndexCallback: (key) {
                          if (key is! ValueKey<String>) {
                            return null;
                          }
                          final index = _visibleIndex[key.value];
                          return index == null
                              ? null
                              : messages.length - index - 1;
                        },
                        itemBuilder: (_, reverseIndex) {
                          final index = messages.length - reverseIndex - 1;
                          final message = messages[index];
                          final previous = index == 0
                              ? controller?.previousTimestamp(message.id)
                              : messages[index - 1].timestamp;
                          return _cachedMessageRow(message, previous);
                        },
                      ),
                    ),
    );
    return Stack(children: [
      Positioned.fill(child: list),
      // 规格 #4：“回到引用位置”弹窗——屏幕右下方、输入框之上，
      // 样式与 @提醒弹窗（MentionBannerButton）完全一致。
      if (quoteReturnMessageId != null)
        Positioned(
          right: 12,
          bottom: 76,
          child: QuoteReturnBannerButton(
            key: const Key('quote-return-banner-button'),
            onTap: () => unawaited(_returnToQuoteOrigin()),
          ),
        ),
      if ((controller?.hasLaterWindow ?? false) ||
          (controller?.isViewingHistoryContext ?? false))
        Positioned(
            right: 12,
            bottom: 12,
            child: ModernActionButton(
                key: const Key('timeline-return-latest'),
                onPressed: _showLatestWindow,
                icon: CupertinoIcons.arrow_down_to_line,
                label: '回到最新消息')),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    // Non-timeline state (identity, selection, theme, highlighting) refreshes
    // row presentation. SDK updates rebuild only the local timeline subtree.
    _rowCache.clear();
    final allMessages = controller?.messages ?? const <RoomMessageViewModel>[];
    final messages = hiddenEvents?.visibleItems(
          roomInfo.id,
          allMessages,
          eventId: (message) => message.id,
          eventTimestamp: (message) => message.timestamp,
        ) ??
        allMessages;
    return WeChatPageScaffold.navigation(
      backgroundColor: WeChatColors.pageBackground(context),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.navigationBackground(context),
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: peer == null ? null : () => _openContact(peer!),
          child: WeChatNavTitle(
            _navigationTitle,
            supportIdentities: isGroup ? null : _supportIdentities,
            matrixUserId:
                isGroup ? null : (roomInfo.directPeerId ?? peer?.matrixUserId),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoButton(
              key: const Key('chat-details'),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              onPressed: () => _trackAction(_openConversationDetails),
              child: const Icon(ChangliaoIcons.more, size: 22),
            ),
          ],
        ),
      ),
      child: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                if (isGroup)
                  GroupAnnouncementBanner(service: announcementService),
                Expanded(
                  child: ValueListenableBuilder<int>(
                    valueListenable: _timelineRevision,
                    builder: (_, __, ___) => _buildTimeline(),
                  ),
                ),
                if (mediaMessage != null)
                  AnimatedOpacity(
                    opacity: mediaMessageVisible ? 1 : 0,
                    duration: const Duration(milliseconds: 500),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      color: WeChatColors.navigationBackground(context),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(mediaMessage!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (replyingTo != null && !selection.active)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    color: CupertinoTheme.of(context).barBackgroundColor,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '引用：${replyingTo!.text}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: WeChatColors.textSecondary,
                            ),
                          ),
                        ),
                        CupertinoButton(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size.square(36),
                          onPressed: () => setState(() {
                            replyingTo = null;
                            _selectedReplyExcerpt = null;
                          }),
                          child: const Icon(CupertinoIcons.xmark, size: 18),
                        ),
                      ],
                    ),
                  ),
                if (selection.active)
                  MessageSelectionBar(
                    count: selection.selectedIds.length,
                    canForward: selection.canForward(
                      (eventId) => _isForwardable(eventId, messages),
                    ),
                    onForward: () => _forwardMessages([
                      for (final id in selection.selectedIds)
                        if (controller?.findMessage(id)
                            case final RoomMessageViewModel message)
                          message,
                    ]),
                    onCopy: () => unawaited(_copySelectedMessages()),
                    onDelete: _deleteSelection,
                    onCancel: () => setState(selection.exit),
                  )
                else ...[
                  // BUG-35：视频发送工作胶囊（转码百分比/上传中/失败可重试），
                  // 覆盖相册与拍摄两条路径；进度由后台协调器驱动。
                  ListenableBuilder(
                      listenable: (widget.roomLease
                              as MatrixOutgoingProgressView)
                          .outgoingProgress,
                      builder: (context, _) {
                        final summary = (widget.roomLease
                                as MatrixOutgoingVideoWorkView)
                            .videoWorkSummaryForRoom(roomInfo.id);
                        if (!summary.busy && summary.failed == 0) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          key: const Key('video-automatic-compression-progress'),
                          padding: const EdgeInsets.all(8),
                          child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const CupertinoActivityIndicator(radius: 7),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(summary.label,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: CupertinoColors.systemGrey))),
                              ]),
                        );
                      }),
                  if (widget.readOnly)
                    const Padding(
                      key: Key('room-read-only-notice'),
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Center(
                        child: Text('该消息来自历史会话，仅可查看',
                            style: TextStyle(
                                fontSize: 13,
                                color: CupertinoColors.systemGrey)),
                      ),
                    )
                  else
                    ChatComposerBar(
                      controller: input,
                      focusNode: inputFocusNode,
                      panel: composerPanel,
                      onMore: () => _togglePanel(ComposerPanel.more),
                      onVoice: _toggleVoice,
                      onEmoji: () => _togglePanel(ComposerPanel.emoji),
                      onSend: () => _trackAction(_send),
                      onSubmitted: (_) => _send(),
                      voiceField: WeChatHoldToTalk(
                        controller: voiceRecording,
                        onStart: () => _trackAction(_onVoiceStart),
                        onStop: (target) =>
                            _trackAction(() => _onVoiceStop(target)),
                        onCancel: (target) =>
                            _trackAction(() => _onVoiceCancel(target)),
                      ),
                      onInputTap: _dismissEmojiPanelForInput,
                    ),
                  if (composerPanel == ComposerPanel.more)
                    TapRegion(
                      // 点击面板内不收起；面板外（输入框/消息列表等）任何
                      // 按下即收起，且不拦截该次点击的原有交互（TapRegion
                      // 不消费事件：输入框仍聚焦、列表仍可滚动/选择）。
                      groupId: chatComposerPanelGroupId,
                      onTapOutside: (_) => _dismissComposerExtensions(),
                      child: ChatMorePanel(
                        onSelected: (action) =>
                            _trackAction(() => _handleMoreAction(action)),
                        onCameraLongPress: () =>
                            _trackAction(_startVideoCapture),
                        onTools: () => _togglePanel(ComposerPanel.tools),
                      ),
                    ),
                  if (composerPanel == ComposerPanel.tools)
                    TapRegion(
                      groupId: chatComposerPanelGroupId,
                      onTapOutside: (_) => _dismissComposerExtensions(),
                      child: ChatToolsPanel(
                        onToolSelected: (tool) {
                          _dismissComposerExtensions();
                          tool.onTap();
                        },
                      ),
                    ),
                  if (composerPanel == ComposerPanel.emoji)
                    TapRegion(
                      groupId: chatComposerPanelGroupId,
                      onTapOutside: (_) => _dismissComposerExtensions(),
                      child: SizedBox(
                        height: 280,
                        child: ChatEmojiPanel(
                          onEmojiSelected: _insertEmoji,
                          customItems: customEmojiItems,
                          onCustomSelected: (item) =>
                              _trackAction(() => _sendCustomEmoji(item)),
                          onCustomRemoved: (item) =>
                              _trackAction(() => _removeCustomEmoji(item)),
                        ),
                      ),
                    ),
                  if (composerPanel == ComposerPanel.mention)
                    WeChatMentionPanel(
                      options: _mentionMembers(),
                      avatarBuilder: (context, option) {
                        final identity = _identityCache.resolveIdentity(
                            matrixUserId: option.id,
                            displayName: option.primaryName);
                        return MatrixUserAvatar(
                          avatarMedia: widget.roomLease,
                          nickname: identity.displayName,
                          fallbackSeed: identity.cacheKey,
                          matrixAvatarUri: identity.avatarIsKnown
                              ? null
                              : _member(option.id).avatarUri,
                          fallbackAvatarUrl: identity.avatarUrl,
                          diagnosticSource: 'mention-member-picker',
                          size: 36,
                        );
                      },
                      canMentionAll: _canMentionAll,
                      onSelect: _insertMention,
                    ),
                ],
              ],
            ),
            // 覆盖层常驻挂载、由控制器监听驱动显隐：
            // 按下瞬间 start() 通知监听器，同帧渲染，不等录音启动回调，
            // 也不依赖本组件因其他原因 setState。
            Positioned.fill(
              child: ListenableBuilder(
                listenable: voiceRecording,
                builder: (context, _) {
                  final state = voiceRecording.state;
                  final visible = state == VoiceRecordingState.recording ||
                      state == VoiceRecordingState.cancelArmed ||
                      state == VoiceRecordingState.textArmed ||
                      state == VoiceRecordingState.sendArmed;
                  return visible
                      ? VoiceRecordingOverlay(
                          controller: voiceRecording,
                          elapsed: _voiceElapsed,
                        )
                      : const SizedBox.shrink();
                },
              ),
            ),
            if (isGroup)
              Positioned(
                  top: 4,
                  right: 8,
                  child: ValueListenableBuilder<int>(
                      valueListenable: _mentionRevision,
                      builder: (_, __, ___) =>
                          unreadMentions?.hasPending ?? false
                              ? MentionBannerButton(onTap: () {
                                  final target = unreadMentions?.nextJumpTarget;
                                  if (target != null) {
                                    unawaited(_scrollToMessage(target));
                                  }
                                })
                              : const SizedBox.shrink())),
          ],
        ),
      ),
    );
  }
}

/// 群成员头衔徽标（QQ 式）：群主橙红、管理员蓝，圆角小标签。
final class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            height: 1.2,
            color: CupertinoColors.white,
          ),
        ),
      );
}

/// 把持久化 outbox 行交回**当前打开的房间会话**发送。
///
/// 调度器只在房间已打开时拿到这个句柄；页面销毁/租约取消后 [canSend] 为
/// false，注册表按"没有句柄"处理，行继续留在 outbox 等下次进入会话。
final class _RoomOutboxSender implements OutboxSender {
  _RoomOutboxSender(this._page);

  final _RoomPageState _page;

  @override
  String get roomId => _page.roomInfo.id;

  @override
  bool get canSend =>
      !_page.widget.readOnly &&
      _page.mounted &&
      !_page._disposing &&
      !_page.widget.roomLease.canceled &&
      _page.controller != null;

  @override
  Future<String> send(OutboxMessage message) async {
    final controller = _page.controller;
    if (controller == null) {
      throw StateError('Room timeline is not ready');
    }
    final eventId =
        await controller.sendText(message.content, outboxRow: message);
    if (eventId == null || eventId.isEmpty) {
      throw StateError('Matrix event was not accepted');
    }
    return eventId;
  }
}
