// 会话聊天页（RoomPage）：私聊与群聊共用的消息时间线与交互。
// 自 matrix_home_page.dart 拆分（巨石文件治理）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/business_api_client.dart';
import '../../core/local_notification_scheduler.dart';
import '../contacts/contact_models.dart';
import '../contacts/add_friend_profile_page.dart';
import '../contacts/contacts_page.dart';
import '../profile/profile_controller.dart';
import '../redpacket/red_packet_claim_dialog.dart';
import '../../ui/chat/chat_composer_bar.dart';
import '../../ui/chat/wechat_composer.dart' show chatComposerPanelGroupId;
import '../../ui/chat/chat_composer_state.dart';
import '../../ui/chat/chat_emoji_panel.dart';
import '../../ui/chat/chat_more_panel.dart';
import 'package:flutter/services.dart';

import '../../ui/chat/message_action.dart';
import '../../ui/chat/message_bubble_menu.dart';
import '../../ui/chat/chat_forward_picker_page.dart';
import 'recent_forward_store.dart';
import 'media_thumbnail.dart';
import 'package:video_compress/video_compress.dart';
import 'video_send_stage.dart';
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
import '../../ui/components/wechat_nav_title.dart';
import '../../ui/finance/wechat_red_packet_card.dart';
import '../../ui/finance/wechat_transfer_card.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../transfer/chat_transfer_adapters.dart';
import '../transfer/chat_transfer_controller.dart';
import '../transfer/chat_transfer_detail_sheet.dart';
import '../transfer/chat_transfer_sheet.dart';
import 'matrix_e2ee_client.dart';
import 'image_picker_page.dart';
import 'voice_recording_controller.dart';
import 'voice_playback_controller.dart' hide VoicePlaybackState;
import 'voice_transcriber.dart';
import '../../ui/chat/wechat_hold_to_talk.dart';
import '../../ui/chat/voice_recording_overlay.dart';
import '../../features/emoji/fluent_emoji_catalog.dart';
import '../../ui/chat/emoji_text.dart';
import '../../ui/chat/encrypted_media_view.dart';
import '../../ui/chat/super_emoji_message.dart';
import '../statistics/statistics_room_scope.dart';
import '../statistics/statistics_tool.dart';
import 'media_cache.dart';
import 'matrix_user_avatar.dart';
import 'profile_repository.dart';
import 'matrix_room_timeline_adapter.dart';
import 'chat_red_packet_adapters.dart';
import 'chat_red_packet_controller.dart';
import 'chat_red_packet_sheet.dart';
import 'group_chat_info_controller.dart';
import 'group_chat_info_page.dart';
import 'conversation_preferences.dart';
import 'conversation_presentation.dart';
import 'conversation_read_state.dart';
import 'direct_chat_info_page.dart';
import 'chat_history_search.dart';
import 'matrix_emoji_vault.dart';
import 'matrix_control_rooms.dart';
import 'matrix_message_reminder_backend.dart';
import 'media_message_service.dart';
import 'message_reminder_service.dart';
import 'message_interaction_service.dart';
import 'nudge_service.dart';
import 'local_hidden_events.dart';
import 'room_timeline_controller.dart';

class RoomPage extends StatefulWidget {
  const RoomPage({
    super.key,
    this.voiceTranscriber,
    required this.api,
    required this.roomName,
    required this.room,
    this.initialContact,
    required this.onCreateGroup,
    this.reminderService,
    this.onVoice,
    this.onVideo,
    this.initialIdentityCache,
  });

  final BusinessApiClient api;
  final String roomName;
  final Room room;
  final ContactDetails? initialContact;
  final VoidCallback onCreateGroup;
  final MessageReminderService? reminderService;
  final ContactAction? onVoice;
  final ContactAction? onVideo;
  final ProfileRepository? initialIdentityCache;

  /// 语音转文字实现（可注入；默认系统语音识别）。
  final VoiceTranscriber? voiceTranscriber;

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
      CupertinoPageRoute(
        builder: (_) => AddFriendProfilePage(
          api: api,
          userId: profile['user_id']?.toString() ?? '',
          username: profile['username']?.toString() ?? member.matrixUserId,
          nickname: (profile['nickname']?.toString() ?? '').isNotEmpty
              ? profile['nickname'].toString()
              : member.displayName,
          relationshipState:
              profile['relationship_state']?.toString() ?? 'NONE',
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

class _RoomPageState extends State<RoomPage> {
  final input = TextEditingController();
  final inputFocusNode = FocusNode();
  final messageScrollController = ScrollController();
  late final VoicePlaybackController voicePlayback = VoicePlaybackController(
    // 语音附件经本地缓存：首次解密下载，重播直接读缓存（无重复网络）。
    loadAttachment: (eventId) => loadMediaWithCache(
      MediaCacheKey(roomId: widget.room.id, eventId: eventId),
      () => controller!.loadAttachment(eventId),
    ),
  );
  final messageKeys = <String, GlobalKey>{};
  final recalledDrafts = <String, String>{};
  final selection = MessageSelectionController();
  // 会话级图片内存缓存：滚动往复时同步命中，杜绝重复解密与布局抖动。
  final imageMemoryCache = MediaMemoryCache();

  // 缩略图独立缓存（键前缀 thumb:）：消息气泡优先渲染发送端压缩演绎版，
  // 与全量原图缓存互不挤占。
  final thumbnailMemoryCache = MediaMemoryCache();
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
  Timeline? roomTimeline;
  LocalHiddenEvents? hiddenEvents;
  final mentionDraft = MentionDraft();
  final menuLinks = <String, LayerLink>{};
  OverlayEntry? actionMenuEntry;
  RoomMessageViewModel? replyingTo;
  MatrixEmojiVault? emojiVault;
  List<CustomEmojiItem> customEmojiItems = const [];
  MessageReminderService? reminderService;
  String nudgeSuffix = '';
  Map<String, ContactDetails> contactsByMatrixId = const {};
  ProfileData? ownProfile;
  late final ProfileRepository _identityCache =
      widget.initialIdentityCache ?? ProfileRepository(widget.api);
  ContactDetails? peer;
  bool loading = true;
  bool mediaBusy = false;

  // 「拍摄」长按录像（需求 2）：待确认发送的视频与其压缩进度。
  ({String path, int originalBytes})? pendingVideoSend;

  /// 视频发送阶段（转码→加密→上传→发送事件；转码有真实进度，
  /// 其余阶段按 SDK 上传伪事件状态显示）。
  VideoSendState videoSend = const VideoSendState();
  ComposerPanel composerPanel = ComposerPanel.none;
  String? errorMessage;
  String? mediaMessage;
  Timer? mediaMessageTimer;
  bool mediaMessageVisible = false;

  /// 「拍摄」自动发送时的暂存缩略图（200px），随发送横幅一并展示。
  Uint8List? mediaThumbBytes;
  late int joinedMemberCount;
  int? readAnnouncementVersion;
  String? highlightedMessageId;

  bool get isGroup => !widget.room.isDirectChat;

  @override
  void initState() {
    super.initState();
    peer = widget.initialContact;
    joinedMemberCount = orderedJoinedMembers(widget.room).length;
    ownProfile = _identityCache.profile;
    contactsByMatrixId = _identityCache.contactsByMatrixId;
    _identityCache.addListener(_identityChanged);
    input.addListener(_handleComposerChanged);
    // 上滑接近顶部时自动加载更早的历史消息（顶部有加载/结束提示）。
    messageScrollController.addListener(_onMessageScroll);
    // 未读状态机（BUG 5）：本房间进入"查看中"，收到新消息不计未读。
    ConversationReadState.shared().setRoomOpen(widget.room.id, open: true);
    unawaited(_identityCache.preload().catchError((_) {}));
    unawaited(_refreshJoinedMemberCount());
    unawaited(_loadAnnouncementReadState());
    // 聊天工具：幂等注册「统计助手」并登记本会话到作用域栈
    ensureStatisticsToolRegistered();
    StatisticsRoomScope.enter(widget.room.id);
    _load();
  }

  /// WeChat opens the 「选择提醒的人」 panel when a group message ends with a
  /// freshly typed "@" and closes it again as soon as the text moves on.
  void _handleComposerChanged() {
    final shouldShow = isGroup && input.text.endsWith('@');
    if (mounted && shouldShow != (composerPanel == ComposerPanel.mention)) {
      setState(() {
        composerPanel = shouldShow ? ComposerPanel.mention : ComposerPanel.none;
      });
    }
  }

  List<MentionOption> _mentionMembers() {
    final selfId = widget.room.client.userID;
    final options = <MentionOption>[];
    for (final member in orderedJoinedMembers(widget.room)) {
      if (member.id == selfId) continue;
      final nickname = member.calcDisplayname();
      final remark = contactsByMatrixId[member.id]?.remark?.trim() ?? '';
      options.add(MentionOption(
        id: member.id,
        primaryName: remark.isNotEmpty ? remark : nickname,
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
    final myId = widget.room.client.userID;
    if (myId == null) return false;
    final settings =
        widget.room.roomAccountData[groupChatAccountDataType]?.content ??
            const {};
    if (settings['owner_id']?.toString() == myId) return true;
    if (widget.room.getState(EventTypes.RoomCreate)?.senderId == myId) {
      return true;
    }
    final adminIds = settings['admin_ids'];
    return adminIds is List && adminIds.contains(myId);
  }

  void _insertMention(MentionOption option) {
    final selfId = widget.room.client.userID;
    final value = option.isAll
        ? mentionDraft.appendAll(
            input.text,
            userIds: [
              for (final member in orderedJoinedMembers(widget.room))
                if (member.id != selfId) member.id,
            ],
          )
        : mentionDraft.append(
            input.text,
            displayName: option.primaryName,
            userId: option.id,
          );
    setState(() {
      input
        ..text = value
        ..selection = TextSelection.collapsed(offset: value.length);
      composerPanel = ComposerPanel.none;
    });
  }

  Future<void> _refreshJoinedMemberCount() async {
    if (!isGroup) return;
    try {
      await widget.room.requestParticipants([Membership.join]);
      final count = orderedJoinedMembers(widget.room).length;
      if (mounted) setState(() => joinedMemberCount = count);
    } catch (_) {
      // Preserve the synchronized local count if a transient member request
      // fails; the next room sync refreshes the title.
    }
  }

  String get _navigationTitle => isGroup
      ? groupRoomNavigationTitle(widget.room.name, joinedMemberCount)
      : directRoomNavigationTitle(
          peerMatrixUserId: widget.room.directChatMatrixID,
          contactsByMatrixId: contactsByMatrixId,
          fallbackRoomName: widget.roomName,
        );

  void _identityChanged() {
    if (!mounted) return;
    final mapped = _identityCache.contactsByMatrixId;
    setState(() {
      contactsByMatrixId = mapped;
      ownProfile = _identityCache.profile ?? ownProfile;
      final peerId = widget.room.directChatMatrixID;
      if (peerId != null) peer = mapped[peerId] ?? peer;
    });
  }

  int get _announcementVersion =>
      widget.room.roomAccountData[groupChatAccountDataType]
          ?.content['announcement_version'] as int? ??
      0;

  String get _announcement => isGroup ? widget.room.topic.trim() : '';

  bool get _showAnnouncement =>
      _announcement.isNotEmpty &&
      _announcementVersion > readAnnouncementVersion!;

  Future<void> _loadAnnouncementReadState() async {
    final preferences = await SharedPreferences.getInstance();
    final version =
        preferences.getInt('announcement-read:${widget.room.id}') ?? 0;
    if (mounted) setState(() => readAnnouncementVersion = version);
  }

  Future<void> _openAnnouncement() async {
    final version = _announcementVersion;
    await Navigator.push<void>(
      context,
      CupertinoPageRoute(
        builder: (_) => GroupAnnouncementPage(
          title: _navigationTitle,
          announcement: _announcement,
        ),
      ),
    );
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt('announcement-read:${widget.room.id}', version);
    if (mounted) setState(() => readAnnouncementVersion = version);
  }

  Future<void> _load() async {
    try {
      final accountId = widget.room.client.userID;
      if (accountId == null) throw StateError('Matrix 账号尚未登录');
      hiddenEvents = SharedPreferencesLocalHiddenEvents(
        preferences: await SharedPreferences.getInstance(),
        accountId: accountId,
      );
      final timeline =
          // Timeline 分页策略（优化 4）：初始窗口直读 Matrix 本地 DB
          // （不等待服务器）；历史分页 requestHistory 默认 30 条/页
          // （Room.defaultHistoryCount，处于 30~50 规范区间），
          // 由上滑接近顶部时按页追加（见 _onMessageScroll）。
          await widget.room.getTimeline(onUpdate: () => controller?.refresh());
      if (!mounted) {
        timeline.cancelSubscriptions();
        return;
      }
      controller = RoomTimelineController(
        MatrixRoomTimelineAdapter(widget.room, timeline),
      )..addListener(_changed);
      roomTimeline = timeline;
      setState(() => loading = false);
      await controller!.markRead();
      ConversationReadState.shared().markCleared(
        widget.room.id,
        eventId:
            controller!.messages.isEmpty ? null : controller!.messages.first.id,
      );
      await _loadEmojiVault();
      await _loadReminderService();
      await _loadIdentities();
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          errorMessage = '会话加载失败，请检查网络后重试';
        });
      }
    }
  }

  Future<void> _loadIdentities() async {
    try {
      await _identityCache.preload();
      final contacts = _identityCache.contacts;
      final profile = _identityCache.profile;
      final mapped = _identityCache.contactsByMatrixId;
      final participantIds = widget.room
          .getParticipants()
          .map((participant) => participant.id)
          .where((id) => id != widget.room.client.userID)
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
        MatrixSdkEmojiVaultBackend(widget.room.client),
      );
      final items = <CustomEmojiItem>[];
      for (final item in session.vault.items) {
        items.add(
          CustomEmojiItem(
            id: item.id,
            bytes: await session.loadBytes(item),
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
    } catch (_) {
      if (mounted) setState(() => mediaMessage = '我的表情同步失败，可稍后重试');
    }
  }

  Future<void> _loadReminderService() async {
    try {
      final provided = widget.reminderService;
      final MessageReminderService service;
      if (provided != null) {
        service = provided;
      } else {
        final backend =
            await MatrixMessageReminderBackend.open(widget.room.client);
        service = MessageReminderService(
          backend: backend,
          scheduler: FlutterLocalNotificationScheduler(),
        );
        await service.applyIncoming(await backend.load());
      }
      reminderService = service;
    } catch (_) {
      // Chat remains available; choosing reminder will surface a retry state.
    }
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
        bytes: bytes,
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
    try {
      await widget.room.sendFileEvent(
        MatrixFile.fromMimeType(
          bytes: item.bytes,
          name: item.isAnimated ? '畅聊表情.gif' : '畅聊表情.png',
          mimeType: item.mimeType,
        ),
      );
      await emojiVault?.vault.markRecent(item.id);
      if (mounted) setState(() => composerPanel = ComposerPanel.none);
    } catch (_) {
      if (mounted) setState(() => mediaMessage = '表情发送失败，请重试');
    }
  }

  Future<void> _sendNudge(
    RoomMessageViewModel message,
    String targetDisplayName,
  ) async {
    final sender = ownProfile;
    final senderId = widget.room.client.userID;
    if (sender == null || senderId == null) return;
    try {
      // The profile service is authoritative for a sender's nudge suffix.
      // Refresh it at send time so a just-saved profile setting is used by
      // already-open conversations as well.
      final latestProfile = await widget.api.loadProfile();
      if (mounted) {
        setState(() {
          ownProfile = latestProfile;
          nudgeSuffix = latestProfile.nudgeSuffix ?? '';
        });
      }
      await NudgeService(
        backend: MatrixNudgeBackend(widget.room.client),
        roomId: widget.room.id,
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
      if (mounted) setState(() => mediaMessage = '拍一拍发送失败，请重试');
    }
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
                            roomId: widget.room.id,
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

  void _changed() {
    if (mounted) setState(() {});
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
    input.clear();
    final interaction = _interaction;
    final reply = replyingTo;
    final mentions = mentionDraft.activeUserIds(text);
    if (interaction != null && reply != null) {
      await interaction.reply(
        reply.id,
        text,
        mentionedUserIds: mentions,
      );
      setState(() => replyingTo = null);
    } else if (interaction != null && mentions.isNotEmpty) {
      await interaction.sendMention(text, mentions);
    } else {
      await controller!.sendText(text);
    }
    mentionDraft.clear();
  }

  MessageInteractionService? get _interaction {
    final timeline = roomTimeline;
    final userId = widget.room.client.userID;
    if (timeline == null || userId == null) return null;
    return MessageInteractionService(
      backend: MatrixMessageInteractionBackend(
        client: widget.room.client,
        timeline: timeline,
      ),
      roomId: widget.room.id,
      currentUserId: userId,
    );
  }

  Future<DateTime?> _serverNow() async {
    final homeserver = widget.room.client.homeserver;
    if (homeserver == null) return null;
    try {
      return await MatrixServerClock(
        homeserver: homeserver,
        httpClient: widget.room.client.httpClient,
      ).now();
    } catch (_) {
      return null;
    }
  }

  /// 可转发的加密会话（房间 id → 展示名），供图片查看器“转发”使用。
  List<({String roomId, String title})> get _imageForwardTargets => [
        for (final room in widget.room.client.rooms)
          if (room.id != widget.room.id && room.encrypted)
            (
              roomId: room.id,
              title: room.getLocalizedDisplayname(),
            ),
      ];

  /// 「拍摄」入口：拍摄成功即**自动加密发送**（不进入“查看照片”页）；
  /// 发送期间优先解码 200px 缩略图作为暂存内容先展示，提升发送体验。
  Future<void> _captureAndSendImage() async {
    if (mediaBusy) return;
    final matrix = MatrixSdkE2eeClient(
      widget.room.client,
      homeserver: widget.room.client.homeserver!,
    );
    final service = MediaMessageService(matrix);
    final captured = await service.captureToFile();
    if (captured == null) return; // 用户取消拍摄
    if (!mounted) return;
    setState(() {
      mediaBusy = true;
      mediaMessageVisible = true;
      mediaMessage = '正在加密发送图片…';
      mediaThumbBytes = null;
    });
    // 缩略图优先：解码即展示为暂存内容，发送不等待缩略图。
    unawaited(service.captureThumbnail(captured).then((thumb) {
      if (thumb == null || !mounted || !mediaBusy) return;
      setState(() => mediaThumbBytes = thumb);
    }));
    try {
      final bytes = await File(captured).readAsBytes();
      // 发送附带 ≤800px/≤100KB 加密缩略图（E2EE 同样保护缩略图），
      // 接收端可立即渲染预览；失败不阻断发送。
      final thumbnail = await buildChatImageThumbnail(bytes);
      await matrix.sendEncryptedMedia(widget.room.id, bytes, 'image/jpeg',
          thumbnailBytes: thumbnail?.bytes,
          thumbnailWidth: thumbnail?.width,
          thumbnailHeight: thumbnail?.height);
      if (mounted) _showMediaMessage('图片已发送');
    } catch (_) {
      if (mounted) setState(() => mediaMessage = '图片发送失败，请重试');
    } finally {
      await service.dispose();
      if (mounted) {
        controller?.refresh();
        setState(() {
          mediaBusy = false;
          mediaThumbBytes = null;
        });
      }
    }
  }

  Future<void> _sendMedia({required bool image}) async {
    if (mediaBusy) return;
    if (image) {
      await _pickAndSendImages();
      return;
    }
    final service = MediaMessageService(
      MatrixSdkE2eeClient(
        widget.room.client,
        homeserver: widget.room.client.homeserver!,
      ),
    );
    setState(() {
      mediaBusy = true;
      mediaMessage = '正在加密发送文件…';
    });
    try {
      // 大文件加密上传耗时较长：设置超时上限，避免无限停留在发送态。
      await service
          .sendFile(widget.room.id)
          .timeout(const Duration(minutes: 5));
      if (mounted) _showMediaMessage('文件已发送');
    } on TimeoutException {
      if (mounted) {
        setState(() => mediaMessage = '文件发送超时，请检查网络后重试');
      }
    } catch (_) {
      if (mounted) {
        setState(() => mediaMessage = '文件发送失败，请重试');
      }
    } finally {
      await service.dispose();
      // 主动刷新时间线：让刚发出的事件即时落位，避免“一直在发送”观感。
      if (mounted) controller?.refresh();
      if (mounted) setState(() => mediaBusy = false);
    }
  }

  /// 全屏播放视频消息：下载解密后写临时文件交给播放器。
  Future<void> _openVideoViewer(RoomMessageViewModel message) async {
    await Navigator.of(context, rootNavigator: true).push(
      CupertinoPageRoute(
        fullscreenDialog: true,
        builder: (_) => VideoViewerPage(
          loadBytes: () => controller!.loadAttachment(message.id),
          initialDuration: message.videoDuration,
        ),
      ),
    );
  }

  /// 视频消息封面帧（发送端附带的加密海报缩略图）：
  /// 经缩略图内存缓存避免反复下载；无缩略图（旧消息）返回 null 走
  /// 占位底——绝不为封面帧下载整段视频（内存/流量代价不成比例）。
  Future<Uint8List?> _loadVideoPoster(String messageId) =>
      thumbnailMemoryCache.putIfAbsent(
        'thumb:$messageId',
        () async {
          final poster = await controller!.loadThumbnail(messageId);
          if (poster != null) return poster;
          // 失败不入缓存（putIfAbsent 出错即丢弃），卡片回退占位底。
          throw StateError('video message has no poster thumbnail');
        },
      );

  /// 统一图片选择页（微信式九宫格多选）：默认发送压缩图，
  /// "原图"开关打开后逐张发送原图；逐张加密上传。
  Future<void> _pickAndSendImages() async {
    final matrix = MatrixSdkE2eeClient(
      widget.room.client,
      homeserver: widget.room.client.homeserver!,
    );
    final result = await Navigator.of(context, rootNavigator: true).push(
      CupertinoPageRoute(
        builder: (_) => ImagePickerPage(),
      ),
    ) as ({List<GalleryPhoto> photos, bool original})?;
    if (result == null || result.photos.isEmpty) return;
    setState(() {
      mediaBusy = true;
      mediaMessage = '正在加密发送…';
    });
    try {
      final total = result.photos.length;
      var sent = 0;
      for (final photo in result.photos) {
        sent++;
        if (mounted) {
          setState(() => mediaMessage =
              result.photos.length > 1 ? '正在加密发送 $sent/$total…' : '正在加密发送…');
        }
        final bytes = await (result.original
            ? photo.originalBytes()
            : photo.compressedBytes());
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
        await matrix.sendEncryptedMedia(widget.room.id, bytes, photo.mimeType,
            extraContent: extra,
            thumbnailBytes: rendition?.bytes,
            thumbnailWidth: rendition?.width,
            thumbnailHeight: rendition?.height);
      }
      if (mounted) _showMediaMessage('图片已发送');
    } catch (_) {
      if (mounted) {
        setState(() => mediaMessage = '图片发送失败，请重试');
      }
    } finally {
      // 主动刷新时间线，让发出的事件即时落位。
      if (mounted) controller?.refresh();
      if (mounted) setState(() => mediaBusy = false);
    }
  }

  /// 待发视频预览条（发送区域上方）：封面 + 体积 + 压缩进度 + 取消/发送。
  Widget _pendingVideoSendBar() {
    final pending = pendingVideoSend!;
    final dark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    return Container(
      key: const Key('pending-video-bar'),
      margin: const EdgeInsets.fromLTRB(
          WeChatSpacing.md, WeChatSpacing.sm, WeChatSpacing.md, 0),
      padding: const EdgeInsets.all(WeChatSpacing.sm),
      decoration: BoxDecoration(
        color: dark ? WeChatColors.darkElevated : WeChatColors.lightElevated,
        borderRadius: BorderRadius.circular(WeChatRadius.dialog),
      ),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(WeChatRadius.control),
          child: SizedBox(
            width: 56,
            height: 56,
            child: FutureBuilder<Uint8List?>(
              future: _pendingVideoPoster(pending.path),
              builder: (context, snapshot) {
                final poster = snapshot.data;
                if (poster != null) {
                  return Image.memory(poster,
                      fit: BoxFit.cover, gaplessPlayback: true);
                }
                return const ColoredBox(
                  color: CupertinoColors.black,
                  child: Center(
                      child: Icon(CupertinoIcons.videocam_fill,
                          size: 22, color: CupertinoColors.systemGrey)),
                );
              },
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('视频 ${formatBytes(pending.originalBytes)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14)),
              const SizedBox(height: 4),
              if (videoSend.busy)
                Row(children: [
                  const CupertinoActivityIndicator(radius: 7),
                  const SizedBox(width: 6),
                  Text(
                    videoSend.label,
                    key: const Key('pending-video-progress'),
                    style: const TextStyle(
                        fontSize: 12, color: WeChatColors.textSecondary),
                  ),
                ])
              else
                Text(VideoSendState().label,
                    style: const TextStyle(
                        fontSize: 12, color: WeChatColors.textSecondary)),
            ],
          ),
        ),
        CupertinoButton(
          key: const Key('pending-video-cancel'),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          onPressed: videoSend.busy ? null : _cancelPendingVideo,
          child: const Text('取消', style: TextStyle(fontSize: 14)),
        ),
        CupertinoButton(
          key: const Key('pending-video-send'),
          color: WeChatColors.brandPrimary,
          borderRadius: BorderRadius.circular(WeChatRadius.control),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          onPressed: videoSend.busy ? null : _sendPendingVideo,
          child: const Text('发送',
              style: TextStyle(fontSize: 14, color: CupertinoColors.white)),
        ),
      ]),
    );
  }

  /// 「拍摄」长按（需求 2）：调起系统相机录像；完成后视频自动带回
  /// 发送区域，用户确认后再压缩并发送，无需从相册/文件中二次选择。
  Future<void> _startVideoCapture() async {
    final matrix = MatrixSdkE2eeClient(
      widget.room.client,
      homeserver: widget.room.client.homeserver!,
    );
    final service = MediaMessageService(matrix);
    try {
      final path = await service.captureVideoToFile();
      if (path == null || !mounted) return; // 用户取消
      final size = await File(path).length();
      _dismissComposerExtensions();
      setState(() {
        pendingVideoSend = (path: path, originalBytes: size);
        videoSend = const VideoSendState();
      });
    } catch (_) {
      if (mounted) _showMediaMessage('录像启动失败，请重试');
    } finally {
      await service.dispose();
    }
  }

  void _cancelPendingVideo() {
    if (videoSend.busy) {
      // 可取消边界=转码开始前与发送结束（见 docs/VIDEO_SEND_PIPELINE.md）。
      return;
    }
    setState(() => pendingVideoSend = null);
  }

  /// 确认发送待发视频：先压缩（进度提示，480p 策略与相册一致），
  /// 再加密上传并附带封面帧与时长。
  Future<void> _sendPendingVideo() async {
    final pending = pendingVideoSend;
    if (pending == null || videoSend.busy) return;
    final matrix = MatrixSdkE2eeClient(
      widget.room.client,
      homeserver: widget.room.client.homeserver!,
    );
    setState(() => videoSend = const VideoSendState(
          phase: VideoSendPhase.transcoding,
        ));
    try {
      final rendition = await transcodeForChat(
        File(pending.path),
        onProgress: (progress) {
          if (mounted) {
            setState(() => videoSend = videoSend.copyWith(progress: progress));
          }
        },
      );
      if (!rendition.usedCompressed &&
          await rendition.file.length() > maxOriginalVideoBytes) {
        if (mounted) _showMediaMessage('视频过大且压缩失败，无法发送');
        return;
      }
      if (rendition.fallbackNotice != null && mounted) {
        _showMediaMessage(rendition.fallbackNotice!);
      }
      final bytes = await rendition.file.readAsBytes();
      // 封面帧（发送端压缩演绎版，接收端免下载整段视频即可渲染）。
      ({Uint8List bytes, int? width, int? height})? poster;
      try {
        final frame = await VideoCompress.getByteThumbnail(
          rendition.file.path,
          quality: 60,
          position: 200,
        );
        if (frame != null && frame.isNotEmpty) {
          final dims = await decodeImageDimensions(frame);
          poster = (bytes: frame, width: dims?.$1, height: dims?.$2);
        }
      } catch (_) {
        poster = null; // 封面生成失败不阻断发送
      }
      final durationMs = rendition.durationMs ?? 0;
      // 加密/上传/发送事件阶段：SDK 把细分状态写在上传伪事件
      // （fileSendingStatusKey），轮询驱动 UI（此前整体折叠成"发送中"）。
      setState(() => videoSend = const VideoSendState(
            phase: VideoSendPhase.encrypting,
          ));
      final timeline = controller?.adapter is MatrixRoomTimelineAdapter
          ? (controller!.adapter as MatrixRoomTimelineAdapter).timeline
          : null;
      Timer? phasePoller;
      if (timeline != null) {
        phasePoller = Timer.periodic(const Duration(milliseconds: 300), (_) {
          final phase = videoUploadPhaseFromTimeline(timeline.events);
          if (phase != null && mounted && videoSend.phase != phase) {
            setState(() => videoSend = VideoSendState(phase: phase));
          }
        });
      }
      try {
        await matrix.sendEncryptedMedia(
          widget.room.id,
          bytes,
          'video/mp4',
          extraContent: durationMs <= 0
              ? null
              : {
                  'info': {'duration': durationMs},
                },
          thumbnailBytes: poster?.bytes,
          thumbnailWidth: poster?.width,
          thumbnailHeight: poster?.height,
        );
      } finally {
        phasePoller?.cancel();
      }
      if (mounted) _showMediaMessage('视频已发送');
      if (mounted) {
        setState(() {
          pendingVideoSend = null;
          videoSend = const VideoSendState();
        });
      }
    } catch (_) {
      // 失败保留待发条目，用户可直接重试。
      if (mounted) {
        setState(() => videoSend = const VideoSendState());
        _showMediaMessage('视频发送失败，请重试');
      }
    } finally {
      if (mounted) unawaited(controller?.refresh());
    }
  }

  /// 待发视频封面帧（缓存于缩略图内存缓存，键前缀 vcap:）。
  Future<Uint8List?> _pendingVideoPoster(String path) async {
    try {
      final frame = await VideoCompress.getByteThumbnail(
        path,
        quality: 55,
        position: 200,
      );
      return frame == null || frame.isEmpty ? null : frame;
    } catch (_) {
      return null;
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
    final service = MediaMessageService(
      MatrixSdkE2eeClient(
        widget.room.client,
        homeserver: widget.room.client.homeserver!,
      ),
    );
    try {
      await service.startVoiceRecording(_voicePath);
    } catch (_) {
      // 麦克风不可用是语音无声的常见根因：用对话框强提示，避免用户
      // 只看到一闪而过的 toast 而以为“按住说话没有反应”。
      if (mounted) {
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

  Future<void> _onVoiceCancel(VoiceArmedTarget target) async {
    if (target != VoiceArmedTarget.text) {
      await _finishVoice(send: false);
      return;
    }
    // 转文字：等待识别结果落地（识别器内部有界等待），随后：
    // 识别成功→发送文字；识别失败/为空→降级发送原语音。
    // 任何情况下都不丢弃录音，也不再提示“未能识别…已取消/停止发送”。
    final recognized = await voiceTranscriber.stop();
    _cancelVoiceTimers();
    final service = voiceService;
    voiceService = null;
    if (service == null) return;
    final elapsed =
        DateTime.now().difference(_voiceStartedAt ?? DateTime.now());
    String? path;
    try {
      path = await service.stopVoiceRecordingForPreview();
    } catch (_) {
      path = null;
    }
    final text = recognized.trim();
    if (text.isNotEmpty) {
      if (path != null) unawaited(service.deleteVoiceFile(path));
      try {
        await controller?.sendText(text);
        if (mounted) _showMediaMessage('语音已转为文字发送');
      } catch (_) {
        _showMediaMessage('转文字发送失败，请重试');
      }
    } else if (path != null && elapsed >= const Duration(seconds: 1)) {
      try {
        await service.sendVoicePreview(widget.room.id, path, duration: elapsed);
        if (mounted) _showMediaMessage('未识别到文字，已发送原语音');
      } catch (_) {
        _showMediaMessage('语音发送失败，请重试');
      }
    } else if (path != null) {
      await service.deleteVoiceFile(path);
    }
    if (!mounted) return;
    setState(() {
      _voiceElapsed = Duration.zero;
      voiceRecording.discard();
    });
  }

  void _cancelVoiceTimers() {
    _voiceMaxTimer?.cancel();
    _voiceMaxTimer = null;
    _voiceTicker?.cancel();
    _voiceTicker = null;
  }

  Future<void> _finishVoice({required bool send}) async {
    _cancelVoiceTimers();
    final service = voiceService;
    voiceService = null;
    if (service == null) return;
    if (send) {
      try {
        final path = await service.stopVoiceRecordingForPreview();
        final elapsed = voiceRecording.duration ??
            DateTime.now().difference(_voiceStartedAt ?? DateTime.now());
        if (elapsed >= const Duration(seconds: 1)) {
          await service.sendVoicePreview(widget.room.id, path,
              duration: elapsed);
        } else {
          await service.cancelVoiceRecording();
        }
      } catch (_) {
        _showMediaMessage('语音发送失败，请重试');
      }
    } else {
      await service.cancelVoiceRecording();
    }
    if (!mounted) return;
    setState(() {
      _voiceElapsed = Duration.zero;
      voiceRecording.discard();
    });
  }

  Future<void> _handleMoreAction(ChatMoreAction action) async {
    setState(() => composerPanel = ComposerPanel.none);
    switch (action) {
      case ChatMoreAction.image:
        await _pickAndSendImages();
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
    final timeline = controller;
    if (timeline == null) return;
    if (!isGroup && peer == null) {
      await _showError('好友资料尚未加载，暂时无法发送定向红包');
      return;
    }
    final members = <ChatRoomMember>[
      for (final participant in widget.room.getParticipants())
        if (participant.id != widget.room.client.userID)
          ChatRoomMember(
            participant.id,
            contactsByMatrixId[participant.id]?.displayName ??
                participant.calcDisplayname(),
          ),
    ];
    final redPacketController = ChatRedPacketController(
      business: BusinessChatRedPacketGateway(widget.api),
      references: TimelineRedPacketReferenceGateway(timeline),
      roomId: isGroup ? widget.room.id : null,
      recipientId: isGroup ? null : peer!.userId,
    );
    await Navigator.push<void>(
      context,
      CupertinoPageRoute(
        builder: (pageContext) => ChatRedPacketSheet(
          controller: redPacketController,
          isGroup: isGroup,
          support: BusinessChatRedPacketSupport(widget.api),
          members: members,
          onSent: () => Navigator.pop(pageContext),
        ),
      ),
    );
    redPacketController.dispose();
  }

  Future<void> _showTransfer() async {
    final timeline = controller;
    if (timeline == null) return;
    // Direct chats preselect the peer; group chats and chats without a
    // loaded profile require picking a specific user inside the sheet.
    final hasPeer = !isGroup && peer != null;
    final transferController = ChatTransferController(
      business: BusinessChatTransferGateway(widget.api),
      references: TimelineChatTransferReferenceGateway(timeline),
    );
    await Navigator.push<void>(
      context,
      CupertinoPageRoute(
        builder: (pageContext) => ChatTransferSheet(
          controller: transferController,
          peerId: hasPeer ? peer!.userId : null,
          peerName: hasPeer ? peer!.displayName : null,
          peerAvatarUrl: hasPeer ? peer!.avatarUrl : null,
          balanceSource: BusinessChatTransferBalanceSource(widget.api),
          contactsSource: BusinessChatTransferContactsSource(widget.api),
          onSent: () => Navigator.pop(pageContext),
        ),
      ),
    );
    transferController.dispose();
  }

  Future<void> _openTransferDetail(String transferId) async {
    final viewerId = await widget.api.currentUserId();
    if (!mounted) return;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (_) => ChatTransferDetailSheet(
        api: widget.api,
        transferId: transferId,
        viewerId: viewerId ?? '',
        onSettled: () => controller?.refresh(),
      ),
    );
    controller?.refresh();
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
        CupertinoPageRoute(
          builder: (_) => ContactProfilePage(
            api: widget.api,
            initialContact: contact,
            onVoice: widget.onVoice,
            onVideo: widget.onVideo,
            onContactUpdated: (updated) =>
                _identityCache.applyUpdatedContact(updated.toSummary()),
          ),
        ),
      );

  Future<void> _openConversationDetails() async {
    if (isGroup) {
      final infoController = GroupChatInfoController(
        MatrixGroupChatInfoGateway(widget.room),
      )..bindMembershipChanges(
          widget.room.client.onSync.stream,
          roomId: widget.room.id,
        );
      final contacts = await widget.api.listContacts();
      if (!mounted) return;
      final contactsById = {
        for (final contact in contacts)
          contact.matrixUserId: contact.toDetails(),
      };
      await Navigator.push<void>(
        context,
        CupertinoPageRoute(
          builder: (_) => GroupChatInfoPage(
            controller: infoController,
            identityCache: _identityCache,
            onAddMember: () => _openGroupMemberPicker(infoController),
            onSearchHistory: _openHistorySearch,
            onClearLocalHistory: _clearLocalHistory,
            onMemberTap: (member) => openGroupMemberProfile(
              context,
              api: widget.api,
              lookupByMatrixId: widget.api.lookupUserByMatrixId,
              member: member,
              selfMatrixUserId: widget.room.client.userID,
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
    User? member;
    for (final participant in widget.room.getParticipants()) {
      if (participant.id != widget.room.client.userID) {
        member = participant;
        break;
      }
    }
    final contact = peer;
    final peerId = contact?.matrixUserId ?? member?.id;
    if (peerId == null) return;
    final peerName =
        contact?.displayName ?? member?.calcDisplayname() ?? peerId;
    final avatarUrl = contact?.avatarUrl ?? member?.avatarUrl?.toString();
    await Navigator.push<void>(
      context,
      CupertinoPageRoute(
        builder: (_) => DirectChatInfoPage(
          peerName: peerName,
          peerId: peerId,
          matrixClient: widget.room.client,
          peerAvatarUrl: avatarUrl,
          preference: preferenceForRoom(widget.room),
          onAddMember: widget.onCreateGroup,
          onSearchHistory: _openHistorySearch,
          onClearLocalHistory: _clearLocalHistory,
          onPreferenceChanged: (preference) =>
              writeConversationPreference(widget.room, preference),
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
        CupertinoPageRoute(
          builder: (_) => GroupMemberPickerPage(
            contacts: contacts,
            existingMemberIds: existing,
            onInvite: infoController.invite,
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
    final messages = controller?.messages ?? const <RoomMessageViewModel>[];
    Navigator.push<void>(
      context,
      CupertinoPageRoute(
        builder: (_) => GroupChatHistorySearchPage(
          isGroup: isGroup,
          onEntryTap: (entry) async {
            Navigator.pop(context);
            if (entry.eventId.isNotEmpty) {
              await _scrollToMessage(entry.eventId);
            }
          },
          entries: [
            for (final message in messages)
              GroupChatHistoryEntry(
                sender: _displayName(message.senderId, message.isOwn),
                text: message.text,
                senderId: message.senderId,
                eventId: message.id,
                timestamp: message.timestamp,
                kind: switch (message.kind) {
                  RoomMessageKind.video => LocalChatSearchKind.video,
                  RoomMessageKind.image
                      when message.mimeType?.startsWith('video/') == true =>
                    LocalChatSearchKind.video,
                  RoomMessageKind.image => LocalChatSearchKind.image,
                  RoomMessageKind.file => LocalChatSearchKind.file,
                  _ => LocalChatSearchKind.text,
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _clearLocalHistory() async {
    final store = hiddenEvents;
    if (store == null) return;
    for (final message
        in controller?.messages ?? const <RoomMessageViewModel>[]) {
      await store.hide(widget.room.id, message.id);
    }
    if (mounted) setState(() {});
  }

  Future<void> _scrollToMessage(String eventId) async {
    var target = messageKeys[eventId]?.currentContext;
    // A reply may point beyond the currently loaded timeline window. Fetch
    // older batches until the event becomes available, with a strict bound to
    // avoid an endless request loop when the event has expired or was purged.
    for (var attempts = 0;
        target == null && attempts < 20 && mounted;
        attempts++) {
      final before = controller?.messages.length ?? 0;
      await controller?.loadHistory();
      if (!mounted || (controller?.messages.length ?? 0) <= before) break;
      await WidgetsBinding.instance.endOfFrame;
      target = messageKeys[eventId]?.currentContext;
    }
    if (target == null || !mounted || !target.mounted) return;
    final scrollTarget = target;
    await Scrollable.ensureVisible(
      scrollTarget,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: .5,
    );
    if (!mounted) return;
    setState(() => highlightedMessageId = eventId);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted && highlightedMessageId == eventId) {
      setState(() => highlightedMessageId = null);
    }
  }

  String _displayName(String matrixUserId, bool own) {
    if (own) return ownProfile?.nickname ?? '我';
    final memberName = widget.room
        .unsafeGetUserFromMemoryOrFallback(matrixUserId)
        .calcDisplayname();
    final contact = contactsByMatrixId[matrixUserId];
    // 优先级（需求 3）：私聊 备注>昵称；群聊 群昵称>备注>昵称。
    return resolveChatSenderDisplayName(
      isDirectChat: widget.room.isDirectChat,
      memberName: memberName,
      contactNickname: contact?.nickname,
      remark: contact?.remark,
    );
  }

  Widget _avatar(RoomMessageViewModel message) {
    final contact = contactsByMatrixId[message.senderId];
    final member =
        widget.room.unsafeGetUserFromMemoryOrFallback(message.senderId);
    return MatrixUserAvatar(
      client: widget.room.client,
      diagnosticSource: 'room-message',
      nickname: _displayName(message.senderId, message.isOwn),
      fallbackSeed: message.senderId.isEmpty ? 'me' : message.senderId,
      matrixAvatarUri: message.isOwn ? null : member.avatarUrl,
      fallbackAvatarUrl:
          message.isOwn ? ownProfile?.avatarUrl : contact?.avatarUrl,
      size: WeChatDimensions.messageAvatar,
    );
  }

  Widget _messageContent(RoomMessageViewModel message) =>
      switch (message.kind) {
        RoomMessageKind.image => EncryptedImageMessage(
            load: () => controller!.loadAttachment(message.id),
            forwardTargets: _imageForwardTargets,
            forwardTo: (roomId) async {
              final interaction = _interaction;
              if (interaction == null) {
                throw StateError('forward unavailable');
              }
              await interaction.forward(message.id, roomId);
            },
          ),
        RoomMessageKind.file => WeChatAttachmentTile(
            name: message.text,
            progress: switch (message.deliveryState) {
              RoomDeliveryState.sending => .5,
              RoomDeliveryState.sent => 1,
              RoomDeliveryState.failed => 0,
            },
          ),
        RoomMessageKind.voice => WeChatVoiceBubble(
            duration: message.voiceDuration,
            state: voicePlayback.isPlaying(message.id)
                ? VoicePlaybackState.playing
                : voicePlayback.isPaused(message.id)
                    ? VoicePlaybackState.paused
                    : VoicePlaybackState.idle,
            onTap: () => unawaited(voicePlayback.toggle(message)),
            playback: voicePlayback,
            messageId: message.id,
          ),
        RoomMessageKind.redPacket => WeChatRedPacketCard(
            greeting: message.greeting ?? '恭喜发财',
            state: RedPacketVisualState.available,
            onTap: message.packetId == null
                ? null
                : () => showRedPacketClaimDialog(
                      context,
                      api: widget.api,
                      packetId: message.packetId!,
                      senderName: _senderDisplayName(message),
                      greeting: message.greeting ?? '恭喜发财，大吉大利',
                      senderAvatar: _avatar(message),
                    ),
          ),
        RoomMessageKind.transfer => WeChatTransferCard(
            amount: message.transferAmount ?? '--',
            state: TransferCardState.pending,
            isOwn: message.isOwn,
            onTap: message.transferId == null
                ? null
                : () => _openTransferDetail(message.transferId!),
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
          ),
        RoomMessageKind.text => EmojiText(message.text),
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
    User? member(String userId) {
      for (final participant in widget.room.getParticipants()) {
        if (participant.id == userId) return participant;
      }
      return null;
    }

    return formatNudgeNotice(
      viewerId: widget.room.client.userID ?? '',
      senderId: nudge.senderId,
      senderName: nudge.senderName,
      targetUserId: nudge.targetUserId,
      targetName: nudge.targetName,
      suffix: nudge.suffix,
      viewerRemarkForTarget:
          contactsByMatrixId[nudge.targetUserId]?.displayName,
      targetLiveName: member(nudge.targetUserId)?.calcDisplayname(),
      senderLiveName: member(nudge.senderId)?.calcDisplayname(),
    );
  }

  String _senderDisplayName(RoomMessageViewModel message) {
    final contact = contactsByMatrixId[message.senderId];
    User? member;
    for (final participant in widget.room.getParticipants()) {
      if (participant.id == message.senderId) {
        member = participant;
        break;
      }
    }
    // 备注隐私红线：只向解析器提供主昵称，不读备注字段。
    return resolveMessageSenderDisplayName(
      senderId: message.senderId,
      contactDisplayName: contact?.primaryDisplayName,
      matrixDisplayName: member?.calcDisplayname(),
    );
  }

  Widget _messageRow(RoomMessageViewModel message, DateTime? previousTime) {
    final contact = contactsByMatrixId[message.senderId];
    final displayName = _senderDisplayName(message);
    if (message.isRecalled) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: message.isOwn
              ? Wrap(children: [
                  const Text('你撤回了一条消息 ',
                      style: TextStyle(
                          color: WeChatColors.textSecondary, fontSize: 13)),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    onPressed: () => setState(() {
                      input.text = recalledDrafts[message.id] ?? '';
                      input.selection =
                          TextSelection.collapsed(offset: input.text.length);
                    }),
                    child: const Text('重新编辑',
                        style: TextStyle(
                            color: WeChatColors.socialLink, fontSize: 13)),
                  ),
                ])
              : Text('$displayName 撤回了一条消息',
                  style: const TextStyle(
                      color: WeChatColors.textSecondary, fontSize: 13)),
        ),
      );
    }
    final candidates = (controller?.messages ?? const <RoomMessageViewModel>[])
        .where((item) => item.id == message.replyToEventId);
    final replied = candidates.isEmpty ? null : candidates.first;
    // 纯动效表情消息：按微信习惯去气泡，放大渲染动画表情。
    final animatedEmojis = message.kind == RoomMessageKind.text
        ? fluentEmojisInMessage(message.text)
        : const <FluentEmoji>[];
    final isAnimatedEmojiMessage = animatedEmojis.isNotEmpty;
    final isImageMessage = message.kind == RoomMessageKind.image;
    void appendMentionDraft() {
      final value = mentionDraft.append(
        input.text,
        displayName: displayName,
        userId: message.senderId,
      );
      input
        ..text = value
        ..selection = TextSelection.collapsed(offset: value.length);
    }

    // 即时反馈语义：发送中的消息视觉上等同已发出（无转圈/半透明），
    // 仅在真正失败时展示红色重试标识。
    final deliveryState = switch (message.deliveryState) {
      RoomDeliveryState.sending ||
      RoomDeliveryState.sent =>
        MessageDeliveryState.sent,
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
            key: Key('animated-emoji-${message.id}'),
            emojis: animatedEmojis,
            direction: message.isOwn
                ? MessageDirection.outgoing
                : MessageDirection.incoming,
            state: deliveryState,
            senderName: message.isOwn ? null : displayName,
            avatar: _avatar(message),
            onAvatarTap: contact == null ? null : () => _openContact(contact),
            onAvatarDoubleTap: () => _sendNudge(message, displayName),
            onAvatarLongPress: appendMentionDraft,
            onLongPress: () => unawaited(_showMessageActions(
                message, menuLinks.putIfAbsent(message.id, () => LayerLink()))),
          )
        else if (message.kind == RoomMessageKind.video)
          // 微信式视频消息：无气泡媒体卡（缩略图+播放按钮+时长），
          // 点击全屏播放；头像/昵称与图片消息一致。
          WeChatMessageBubble(
            key: Key('video-message-\${message.id}'),
            decorateContent: false,
            content: VideoMessageCard(
              duration: message.videoDuration,
              posterLoader: () => _loadVideoPoster(message.id),
              onOpen: () => unawaited(_openVideoViewer(message)),
            ),
            senderBadge: message.isOwn ? null : _senderBadge(message),
            senderName: message.isOwn ? null : displayName,
            avatar: _avatar(message),
            onAvatarTap: contact == null ? null : () => _openContact(contact),
            onAvatarDoubleTap: () => _sendNudge(message, displayName),
            onAvatarLongPress: appendMentionDraft,
            onLongPress: () => unawaited(_showMessageActions(
                message, menuLinks.putIfAbsent(message.id, () => LayerLink()))),
            direction: message.isOwn
                ? MessageDirection.outgoing
                : MessageDirection.incoming,
            state: deliveryState,
          )
        else if (isImageMessage)
          // 微信式图片消息：无气泡底衬，但头像/昵称与普通消息一致展示；
          // **缩略图优先**：气泡先渲染发送端 ≤800px/≤100KB 压缩演绎版，
          // 点击查看器再按需加载原图；无缩略图（旧消息）自动回退全量。
          // 页级内存缓存命中时同步渲染。
          WeChatMessageBubble(
            key: Key('image-message-${message.id}'),
            decorateContent: false,
            content: EncryptedImageMessage(
              initialBytes: thumbnailMemoryCache.get('thumb:${message.id}') ??
                  imageMemoryCache.get(message.id),
              loadThumbnail: () => thumbnailMemoryCache.putIfAbsent(
                'thumb:${message.id}',
                () async {
                  final thumbnail = await controller!.loadThumbnail(message.id);
                  if (thumbnail != null) return thumbnail;
                  // 旧消息无缩略图：回退全量并计入缩略图缓存，
                  // 避免滚动往复时重复下载完整附件。
                  return loadMediaWithCache(
                    MediaCacheKey(roomId: widget.room.id, eventId: message.id),
                    () => controller!.loadAttachment(message.id),
                  );
                },
              ),
              load: () => imageMemoryCache.putIfAbsent(
                message.id,
                () => loadMediaWithCache(
                  MediaCacheKey(roomId: widget.room.id, eventId: message.id),
                  () => controller!.loadAttachment(message.id),
                ),
              ),
              originalSizeHint: message.attachmentSize,
              forwardTargets: _imageForwardTargets,
              forwardTo: (roomId) async {
                final interaction = _interaction;
                if (interaction == null) {
                  throw StateError('forward unavailable');
                }
                await interaction.forward(message.id, roomId);
              },
            ),
            senderName: message.isOwn ? null : displayName,
            senderBadge: message.isOwn ? null : _senderBadge(message),
            avatar: _avatar(message),
            onAvatarTap: contact == null ? null : () => _openContact(contact),
            onAvatarDoubleTap: () => _sendNudge(message, displayName),
            onAvatarLongPress: appendMentionDraft,
            onLongPress: () => unawaited(_showMessageActions(
                message, menuLinks.putIfAbsent(message.id, () => LayerLink()))),
            direction: message.isOwn
                ? MessageDirection.outgoing
                : MessageDirection.incoming,
            state: deliveryState,
          )
        else
          WeChatMessageBubble(
            content: _messageContent(message),
            onRetry: () => unawaited(_retryMessage(message)),
            decorateContent: messageBubbleIsDecorated(message.kind),
            senderName: message.isOwn ? null : displayName,
            senderBadge: message.isOwn ? null : _senderBadge(message),
            avatar: _avatar(message),
            onAvatarTap: contact == null ? null : () => _openContact(contact),
            onAvatarDoubleTap: () => _sendNudge(message, displayName),
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
            child: _QuotePreview(
              message: replied,
              targetEventId: message.replyToEventId!,
              displayName: replied == null
                  ? '引用消息'
                  : _displayName(replied.senderId, replied.isOwn),
              onTap: () => _scrollToMessage(message.replyToEventId!),
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
    unawaited(HapticFeedback.mediumImpact());
    final serverNow = await _serverNow();
    if (!mounted) return;
    final actions = MessageActionPolicy.actionsFor(
      MessageCapabilities(
        kind: _contentKind(message),
        isOwn: message.isOwn,
        sentAt: message.timestamp,
        serverNow: serverNow ?? message.timestamp.add(const Duration(days: 1)),
      ),
    );
    if (actions.isEmpty) return;
    dismissActionMenu();
    final isOwn = message.isOwn;
    actionMenuEntry = OverlayEntry(
      builder: (overlayContext) => Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: dismissActionMenu,
            child: const ColoredBox(color: Color(0x1A000000)),
          ),
        ),
        CompositedTransformFollower(
          link: anchor,
          targetAnchor: isOwn ? Alignment.topRight : Alignment.topLeft,
          followerAnchor: isOwn ? Alignment.bottomRight : Alignment.bottomLeft,
          offset: Offset(isOwn ? -8 : 8, -8),
          showWhenUnlinked: false,
          child: MessageBubbleMenu(
            actions: actions,
            onSelected: (action) {
              dismissActionMenu();
              unawaited(_handleMessageAction(message, action));
            },
          ),
        ),
      ]),
    );
    Overlay.of(context, rootOverlay: true).insert(actionMenuEntry!);
  }

  void dismissActionMenu() {
    actionMenuEntry?.remove();
    actionMenuEntry = null;
  }

  Future<void> _handleMessageAction(
    RoomMessageViewModel message,
    MessageAction action,
  ) async {
    switch (action) {
      case MessageAction.copy:
        await Clipboard.setData(ClipboardData(text: message.text));
        if (mounted) _showMediaMessage('已复制');
      case MessageAction.deleteLocal:
        if (hiddenEvents == null) return;
        await hiddenEvents!.hide(widget.room.id, message.id);
        if (mounted) setState(() {});
      case MessageAction.multiSelect:
        setState(() => selection.startWith(message.id));
      case MessageAction.forward:
        await _forwardMessages([message]);
      case MessageAction.reply:
        setState(() => replyingTo = message);
      case MessageAction.recall:
        final interaction = _interaction;
        final serverNow = await _serverNow();
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
      final member =
          widget.room.unsafeGetUserFromMemoryOrFallback(message.senderId);
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
    final message = messages.firstWhere((item) => item.id == eventId);
    return MessageActionPolicy.isForwardable(_contentKind(message));
  }

  Future<void> _deleteSelection() async {
    final store = hiddenEvents;
    if (store == null) return;
    for (final eventId in selection.selectedIds) {
      await store.hide(widget.room.id, eventId);
    }
    if (!mounted) return;
    setState(selection.exit);
  }

  /// 转发：跳转独立“选择聊天”页完成接收对象选择（微信式，禁止底部弹层）。
  Future<void> _forwardMessages(List<RoomMessageViewModel> messages) async {
    final interaction = _interaction;
    if (interaction == null) {
      if (mounted) setState(() => mediaMessage = '转发服务尚未就绪，请稍后重试');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final store = RecentForwardStore(prefs);
    final recentIds = store.load();
    final vaultRoomId = widget
        .room.client.accountData[emojiVaultAccountDataType]?.content['room_id']
        ?.toString();
    final reminderRoomId = widget.room.client
        .accountData[messageReminderAccountDataType]?.content['room_id']
        ?.toString();
    final candidates = <ChatForwardCandidate>[
      for (final room in widget.room.client.rooms)
        if (room.encrypted &&
            !isMatrixControlRoom(
              roomId: room.id,
              displayName: room.getLocalizedDisplayname(),
              vaultRoomId: vaultRoomId,
              reminderRoomId: reminderRoomId,
            ))
          ChatForwardCandidate(
            roomId: room.id,
            title: _forwardTitleFor(room),
            avatar: _forwardRoomAvatar(room),
          ),
    ];
    if (candidates.isEmpty) {
      if (mounted) setState(() => mediaMessage = '没有可用的端到端加密会话');
      return;
    }
    await Navigator.of(context, rootNavigator: true).push(
      CupertinoPageRoute(
        builder: (_) => ChatForwardPickerPage(
          candidates: candidates,
          recentRoomIds: [
            for (final id in recentIds)
              if (candidates.any((c) => c.roomId == id)) id,
          ],
          onForward: (roomIds) async {
            for (final roomId in roomIds) {
              for (final message in messages) {
                await interaction.forward(message.id, roomId);
              }
            }
            await store.record(roomIds);
          },
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      mediaMessage = '已转发';
      selection.exit();
    });
  }

  String _forwardTitleFor(Room room) {
    final peer = room.directChatMatrixID;
    if (peer != null) {
      final contact = contactsByMatrixId[peer];
      if (contact != null) return contact.displayName;
    }
    return room.getLocalizedDisplayname();
  }

  Widget _forwardRoomAvatar(Room room) {
    if (room.isDirectChat || room.avatar != null) {
      return MatrixUserAvatar(
        client: room.client,
        nickname: room.getLocalizedDisplayname(),
        fallbackSeed: room.id,
        matrixAvatarUri: room.avatar,
        size: 52,
      );
    }
    return const ColoredBox(
      color: WeChatColors.lightSurface,
      child: Icon(CupertinoIcons.person_2, size: 25),
    );
  }

  @override
  void dispose() {
    _identityCache.removeListener(_identityChanged);
    unawaited(voicePlayback.stopAll());
    unawaited(_onVoiceCancel(VoiceArmedTarget.cancel));
    controller?.removeListener(_changed);
    controller?.dispose();
    mediaMessageTimer?.cancel();
    _voiceMaxTimer?.cancel();
    _voiceTicker?.cancel();
    _readReceiptDebounce?.cancel();
    voiceService?.dispose();
    inputFocusNode.dispose();
    input.dispose();
    messageScrollController.removeListener(_onMessageScroll);
    ConversationReadState.shared().setRoomOpen(widget.room.id, open: false);
    messageScrollController.dispose();
    StatisticsRoomScope.leave(widget.room.id);
    super.dispose();
  }

  /// 历史加载状态行（列表视觉顶部）：loading 图标 / "没有更多了"。
  Widget _historyStatusRow() {
    if (controller?.historyLoading ?? false) {
      return const Padding(
        key: Key('chat-history-loading'),
        padding: EdgeInsets.symmetric(vertical: WeChatSpacing.md),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CupertinoActivityIndicator(radius: 9),
              SizedBox(width: 8),
              Text('加载中…',
                  style: TextStyle(
                      fontSize: 12, color: WeChatColors.textSecondary)),
            ],
          ),
        ),
      );
    }
    return const Padding(
      key: Key('chat-history-end'),
      padding: EdgeInsets.symmetric(vertical: WeChatSpacing.md),
      child: Center(
        child: Text('没有更多了',
            style: TextStyle(fontSize: 12, color: WeChatColors.textTertiary)),
      ),
    );
  }

  Timer? _readReceiptDebounce;

  /// 查看中收到新消息：立即本地清零，防抖推进服务器已读回执（m.read）。
  void _syncReadReceiptWhileViewing() {
    if (!ConversationReadState.shared().isRoomOpen(widget.room.id)) return;
    final messages = controller?.messages;
    if (messages == null || messages.isEmpty) return;
    ConversationReadState.shared()
        .markCleared(widget.room.id, eventId: messages.first.id);
    _readReceiptDebounce?.cancel();
    _readReceiptDebounce = Timer(const Duration(milliseconds: 800), () {
      if (!mounted ||
          !ConversationReadState.shared().isRoomOpen(widget.room.id)) {
        return;
      }
      unawaited(controller?.markRead());
    });
  }

  /// 上滑接近顶部（reverse 列表像素增大方向）→ 自动加载更早历史。
  /// 加载中的幂等/耗尽判定由 [RoomTimelineController.loadHistory] 负责。
  void _onMessageScroll() {
    if (!messageScrollController.hasClients) return;
    final metrics = messageScrollController.position;
    if (!metrics.hasContentDimensions) return;
    if (metrics.maxScrollExtent - metrics.pixels < 240) {
      unawaited(controller?.loadHistory());
    }
  }

  @override
  Widget build(BuildContext context) {
    final allMessages = controller?.messages ?? const <RoomMessageViewModel>[];
    final messages = hiddenEvents?.visibleItems(
          widget.room.id,
          allMessages,
          eventId: (message) => message.id,
        ) ??
        allMessages;
    final showAnnouncement =
        readAnnouncementVersion != null && _showAnnouncement;
    return WeChatPageScaffold.navigation(
      backgroundColor: WeChatColors.chatPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.chatNavigationBackground,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: peer == null ? null : () => _openContact(peer!),
          child: WeChatNavTitle(_navigationTitle),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoButton(
              key: const Key('chat-details'),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              onPressed: _openConversationDetails,
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
                if (showAnnouncement)
                  CupertinoButton(
                    key: const Key('group-announcement-bar'),
                    padding: EdgeInsets.zero,
                    onPressed: _openAnnouncement,
                    child: Container(
                      height: 40,
                      color: WeChatColors.chatNavigationBackground,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(children: [
                        const Icon(CupertinoIcons.volume_up, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _announcement,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: WeChatColors.textSecondary),
                          ),
                        ),
                        const CupertinoListTileChevron(),
                      ]),
                    ),
                  ),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _dismissComposerExtensions,
                    child: loading
                        ? const Center(child: CupertinoActivityIndicator())
                        : errorMessage != null
                            ? Center(child: Text(errorMessage!))
                            : messages.isEmpty
                                ? const SizedBox.expand()
                                : ListView.builder(
                                    controller: messageScrollController,
                                    reverse: true,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: WeChatSpacing.md,
                                      vertical: WeChatSpacing.sm,
                                    ),
                                    // 顶部状态行（视觉上的最上方）：加载历史中
                                    // 显示 loading，历史取尽显示"没有更多了"。
                                    itemCount: messages.length +
                                        ((controller?.historyLoading ??
                                                    false) ||
                                                (controller?.historyExhausted ??
                                                    false)
                                            ? 1
                                            : 0),
                                    itemBuilder: (_, reverseIndex) {
                                      if (reverseIndex == messages.length) {
                                        return _historyStatusRow();
                                      }
                                      final index =
                                          messages.length - reverseIndex - 1;
                                      final message = messages[index];
                                      final previous = index == 0
                                          ? null
                                          : messages[index - 1].timestamp;
                                      return Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: WeChatSpacing.sm,
                                        ),
                                        child: KeyedSubtree(
                                          key: messageKeys.putIfAbsent(
                                            message.id,
                                            GlobalKey.new,
                                          ),
                                          child: AnimatedContainer(
                                            duration: const Duration(
                                                milliseconds: 180),
                                            color: highlightedMessageId ==
                                                    message.id
                                                ? WeChatColors.divider
                                                : const Color(0x00000000),
                                            child:
                                                _messageRow(message, previous),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
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
                      color: WeChatColors.chatNavigationBackground,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (mediaThumbBytes != null) ...[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: Image.memory(
                                mediaThumbBytes!,
                                key: const Key('media-thumb-preview'),
                                width: 40,
                                height: 40,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
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
                          onPressed: () => setState(() => replyingTo = null),
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
                      for (final message in messages)
                        if (selection.selectedIds.contains(message.id)) message,
                    ]),
                    onDelete: _deleteSelection,
                    onCancel: () => setState(selection.exit),
                  )
                else ...[
                  // 「拍摄」长按录像带回的待发视频：确认后压缩发送（需求 2）。
                  if (pendingVideoSend != null) _pendingVideoSendBar(),
                  ChatComposerBar(
                    controller: input,
                    focusNode: inputFocusNode,
                    panel: composerPanel,
                    onMore: () => _togglePanel(ComposerPanel.more),
                    onVoice: _toggleVoice,
                    onEmoji: () => _togglePanel(ComposerPanel.emoji),
                    onSend: _send,
                    onSubmitted: (_) => _send(),
                    voiceField: WeChatHoldToTalk(
                      controller: voiceRecording,
                      onStart: _onVoiceStart,
                      onStop: _onVoiceStop,
                      onCancel: _onVoiceCancel,
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
                        onSelected: _handleMoreAction,
                        onCameraLongPress: _startVideoCapture,
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
                          onCustomSelected: _sendCustomEmoji,
                        ),
                      ),
                    ),
                  if (composerPanel == ComposerPanel.mention)
                    WeChatMentionPanel(
                      options: _mentionMembers(),
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

final class GroupAnnouncementPage extends StatelessWidget {
  const GroupAnnouncementPage({
    super.key,
    required this.title,
    required this.announcement,
  });
  final String title;
  final String announcement;
  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: const Text('群公告'),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              Text(announcement),
            ]),
          ),
        ),
      );
}

final class _QuotePreview extends StatelessWidget {
  const _QuotePreview({
    required this.message,
    required this.targetEventId,
    required this.displayName,
    required this.onTap,
  });

  final RoomMessageViewModel? message;
  final String targetEventId;
  final String displayName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final message = this.message;
    final summary = switch (message?.kind) {
      RoomMessageKind.image => '图片',
      RoomMessageKind.voice => '语音 ${message!.voiceDuration.inSeconds}″',
      RoomMessageKind.file => '文件：${message!.text}',
      _ => _truncateQuoteText(message?.text ?? '原消息加载中'),
    };
    return CupertinoButton(
      key: Key('reply-preview-$targetEventId'),
      padding: const EdgeInsets.only(top: 4),
      minimumSize: Size.zero,
      onPressed: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 236),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: WeChatColors.divider,
          borderRadius: BorderRadius.circular(WeChatRadius.control),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (message?.kind == RoomMessageKind.image)
            const Icon(CupertinoIcons.photo,
                size: 15, color: WeChatColors.textSecondary)
          else if (message?.kind == RoomMessageKind.voice)
            const Icon(CupertinoIcons.speaker_2,
                size: 15, color: WeChatColors.textSecondary),
          if (message?.kind == RoomMessageKind.image ||
              message?.kind == RoomMessageKind.voice)
            const SizedBox(width: 4),
          Flexible(
            child: Text(
              '$displayName：$summary',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: WeChatColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

String _truncateQuoteText(String value) {
  final characters = value.characters;
  return characters.length > 10
      ? '${characters.take(10).toString()}...'
      : value;
}
