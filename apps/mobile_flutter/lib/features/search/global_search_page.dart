import 'dart:async';

import '../contacts/contact_actions.dart';
import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../matrix/conversation_presentation.dart';
import '../matrix/decryption_state_controller.dart';
import '../matrix/matrix_e2ee_client.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../contacts/contact_models.dart';
import '../contacts/contacts_page.dart';
import '../matrix/profile_repository.dart';
import 'global_search_controller.dart';
import 'global_search_index.dart';
import 'global_search_models.dart';
import '../matrix/chat_search_query_controller.dart'
    show buildHighlightSnippet, formatSearchResultTime;

/// 全局搜索（device-side，typed results）：
/// - 联系人：本机身份缓存投影（备注/昵称优先）；
/// - 群聊：仅 `!isDirect`，可点击进入会话语义由调用方注入的 openRoom 承担；
/// - 聊天记录：真正的本地历史搜索（[GlobalSearchIndex]，已解密正文），
///   按会话聚合；单条命中直接打开并定位，多条进入会话内结果页。
///
/// 安全：查询词与明文都不离开设备；页面不调用任何 Business API。
final class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({
    super.key,
    required this.api,
    this.matrix,
    this.identityCache,
    this.contactActions,
    this.contactsLoader,
    this.roomsLoader,
    this.index,
    this.onOpenRoom,
    this.debounce = const Duration(milliseconds: 250),
    this.sectionLimit = 3,
  });
  final BusinessApiClient api;
  final ContactActions? contactActions;
  final ProfileRepository? identityCache;

  /// 搜索入口统一数据源：提供 Matrix 客户端时页面自行加载会话快照。
  final MatrixSdkE2eeClient? matrix;
  final Future<List<ContactSummary>> Function()? contactsLoader;

  /// 会话快照 → typed 房间结果（可注入，测试用）。
  final Future<List<GlobalSearchRoomResult>> Function()? roomsLoader;

  /// 本地已解密聊天记录索引（默认会话级单例）。
  final GlobalSearchIndex? index;

  /// 打开房间（含 anchor 定位）。由持有房间生命周期的一方注入
  /// （MatrixHomePage → RoomLease/RoomPage 统一导航）；为空时不展示
  /// 群聊/聊天记录分组（避免在搜索页复制一套不完整的开会话实现）。
  final Future<void> Function(GlobalSearchRoomResult room,
      {String? anchorEventId})? onOpenRoom;

  final Duration debounce;
  final int sectionLimit;

  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

final class _GlobalSearchPageState extends State<GlobalSearchPage> {
  late final GlobalSearchController controller;
  Future<List<ContactSummary>>? contacts;

  @override
  void initState() {
    super.initState();
    widget.identityCache?.addListener(_identityChanged);
    contacts = _loadContactSummaries();
    widget.identityCache?.refreshContactsQuietly();
    controller = GlobalSearchController(
      loadContacts: _loadContacts,
      loadRooms: _loadRooms,
      index: widget.index ?? GlobalSearchIndex.shared,
      debounce: widget.debounce,
      sectionLimit: widget.sectionLimit,
    )..addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// 联系人快照：立即挂接错误处理，避免在搜索订阅之前产生未处理的异步错误
  /// （矩阵暂不可用时页面必须安全降级而不是崩溃）。
  Future<List<ContactSummary>> _loadContactSummaries() {
    final future = widget.contactsLoader?.call() ??
        (widget.identityCache == null
            ? widget.api.listContacts()
            : Future.value(widget.identityCache!.contacts));
    unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    return future;
  }

  void _identityChanged() {
    if (!mounted) return;
    setState(() {
      contacts = Future.value(widget.identityCache!.contacts);
    });
    unawaited(controller.refresh());
  }

  @override
  void dispose() {
    widget.identityCache?.removeListener(_identityChanged);
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  String _name(ContactSummary item) =>
      widget.identityCache
          ?.resolveIdentity(
              userId: item.userId,
              matrixUserId: item.matrixUserId,
              username: item.username,
              nickname: item.nickname)
          .displayName ??
      item.displayName;

  /// 联系人结果来自本机身份缓存（不发起网络明文检索）。
  Future<List<GlobalSearchContactResult>> _loadContacts() async {
    final loaded = await (contacts ?? Future.value(const <ContactSummary>[]));
    return [
      for (final item in loaded)
        GlobalSearchContactResult(
          userId: item.userId,
          displayName: _name(item),
          username: item.username,
          nickname: item.nickname,
          avatarUrl: item.avatarUrl,
          cacheKey: widget.identityCache
              ?.resolveIdentity(userId: item.userId)
              .cacheKey,
          matchedText: '畅聊号：${item.username}',
        ),
    ];
  }

  /// 群聊结果来自本机会话快照（typed；私聊不进入群聊分组）。
  Future<List<GlobalSearchRoomResult>> _loadRooms() async {
    if (widget.roomsLoader != null) return widget.roomsLoader!();
    final matrix = widget.matrix;
    if (matrix == null) return const [];
    final snapshot = await matrix.conversations.snapshot();
    return [
      for (final room in snapshot.rooms)
        GlobalSearchRoomResult(
          roomId: room.id,
          displayName: room.displayName,
          isDirect: room.isDirect,
          memberCount: room.members.isEmpty ? null : room.members.length,
          avatarSeed: room.id,
          matchedText:
              room.lastEvent?.decryptionState == MessageDecryptionState.decrypted
                  ? room.lastEvent!.text
                  : null,
        ),
    ];
  }

  Future<void> _openRoom(GlobalSearchRoomResult room,
      {String? anchorEventId}) async {
    final open = widget.onOpenRoom;
    if (open == null) return;
    await open(room, anchorEventId: anchorEventId);
  }

  void _openConversation(GlobalSearchConversationHit conversation) {
    Navigator.push<void>(
      context,
      CupertinoPageRoute(
        builder: (_) => GlobalSearchConversationRecordsPage(
          conversation: conversation,
          query: controller.query,
          onOpenHit: (hit) =>
              _openRoom(hit.room, anchorEventId: hit.eventId),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
          key: const Key('global-search-nav'),
          backgroundColor: WeChatColors.navigationBackground(context),
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          transitionBetweenRoutes: false,
          middle: const Text('搜索'),
        ),
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: CupertinoSearchTextField(
                key: const Key('global-search-field'),
                autofocus: true,
                placeholder: '搜索联系人、群聊和聊天记录',
                onChanged: controller.setQuery,
              ),
            ),
            Expanded(child: _body()),
          ]),
        ),
      );

  Widget _body() {
    // 空查询：页面保持干净（不显示任何分组与结果）。
    if (controller.isBlank) return const SizedBox.shrink();
    if (controller.loading && !controller.hasResults) {
      return const Center(
          child: CupertinoActivityIndicator(radius: 12));
    }
    if (controller.error != null && !controller.hasResults) {
      return _Hint(
        key: const Key('global-search-error'),
        text: '搜索暂时不可用，请稍后重试',
        action: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => unawaited(controller.refresh()),
          child: const Text('重试'),
        ),
      );
    }
    if (!controller.hasResults) {
      return const _Hint(
          key: Key('global-search-empty'), text: '无搜索结果');
    }
    final contacts = controller.visibleContacts;
    final rooms = controller.visibleRooms;
    final conversations = controller.visibleConversations;
    final canOpenRoom = widget.onOpenRoom != null;
    return ListView(children: [
      if (contacts.isNotEmpty) ...[
        const _Section('联系人'),
        for (final contact in contacts)
          _ContactRow(
            contact: contact,
            onTap: () => Navigator.push(
                context,
                CupertinoPageRoute(
                    builder: (_) => ContactProfilePage(
                          onMessage: widget.contactActions?.onMessage,
                          onVoice: widget.contactActions?.onVoice,
                          onVideo: widget.contactActions?.onVideo,
                          api: widget.api,
                          initialContact: _contactDetails(contact),
                          identityCache: widget.identityCache,
                        ))),
          ),
        if (controller.hasMoreContacts)
          _MoreRow(
            key: const Key('global-search-more-contacts'),
            label: '更多联系人',
            onTap: () => _openMore(
              title: '联系人',
              children: [
                for (final contact in controller.results.contacts)
                  _ContactRow(
                    contact: contact,
                    onTap: () => Navigator.push(
                        context,
                        CupertinoPageRoute(
                            builder: (_) => ContactProfilePage(
                                  onMessage: widget.contactActions?.onMessage,
                                  onVoice: widget.contactActions?.onVoice,
                                  onVideo: widget.contactActions?.onVideo,
                                  api: widget.api,
                                  initialContact: _contactDetails(contact),
                                  identityCache: widget.identityCache,
                                ))),
                  ),
              ],
            ),
          ),
      ],
      if (canOpenRoom && rooms.isNotEmpty) ...[
        const _Section('群聊'),
        for (final room in rooms)
          _RoomRow(
            room: room,
            onTap: () => unawaited(_openRoom(room)),
          ),
        if (controller.hasMoreRooms)
          _MoreRow(
            key: const Key('global-search-more-rooms'),
            label: '更多群聊',
            onTap: () => _openMore(
              title: '群聊',
              children: [
                for (final room in controller.results.rooms)
                  _RoomRow(
                    room: room,
                    onTap: () => unawaited(_openRoom(room)),
                  ),
              ],
            ),
          ),
      ],
      if (canOpenRoom && conversations.isNotEmpty) ...[
        const _Section('聊天记录'),
        for (final conversation in conversations)
          _ConversationRow(
            conversation: conversation,
            query: controller.query,
            onTap: conversation.isSingleHit
                ? () => unawaited(_openRoom(conversation.latest.room,
                    anchorEventId: conversation.latest.eventId))
                : () => _openConversation(conversation),
          ),
        if (controller.hasMoreConversations)
          _MoreRow(
            key: const Key('global-search-more-messages'),
            label: '更多聊天记录',
            onTap: () => _openMore(
              title: '聊天记录',
              children: [
                for (final conversation in controller.results.conversations)
                  _ConversationRow(
                    conversation: conversation,
                    query: controller.query,
                    onTap: conversation.isSingleHit
                        ? () => unawaited(_openRoom(conversation.latest.room,
                            anchorEventId: conversation.latest.eventId))
                        : () => _openConversation(conversation),
                  ),
              ],
            ),
          ),
      ],
    ]);
  }

  ContactDetails _contactDetails(GlobalSearchContactResult contact) =>
      widget.identityCache?.contactDetailsByUserId(contact.userId) ??
      ContactDetails(
        userId: contact.userId,
        username: contact.username,
        matrixUserId: '',
        nickname: contact.nickname,
        avatarUrl: contact.avatarUrl,
      );

  void _openMore({required String title, required List<Widget> children}) {
    Navigator.push<void>(
      context,
      CupertinoPageRoute(
        builder: (_) => WeChatPageScaffold.navigation(
          navigationBar: CupertinoNavigationBar(
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text(title),
          ),
          child: SafeArea(child: ListView(children: children)),
        ),
      ),
    );
  }
}

/// 单条会话的命中列表（多条命中时进入；点击某条 → 打开房间并定位）。
final class GlobalSearchConversationRecordsPage extends StatelessWidget {
  const GlobalSearchConversationRecordsPage({
    super.key,
    required this.conversation,
    required this.query,
    required this.onOpenHit,
  });

  final GlobalSearchConversationHit conversation;
  final String query;
  final Future<void> Function(GlobalSearchMessageHit hit) onOpenHit;

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: Text(conversation.roomName,
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        child: SafeArea(
          child: ListView.separated(
            key: const Key('global-search-conversation-records'),
            itemCount: conversation.hits.length,
            separatorBuilder: (_, __) => Container(
              height: .5,
              margin: const EdgeInsets.only(left: 62),
              color: WeChatColors.divider,
            ),
            itemBuilder: (context, index) => _MessageHitRow(
              hit: conversation.hits[index],
              query: query,
              onTap: () => unawaited(onOpenHit(conversation.hits[index])),
            ),
          ),
        ),
      );
}

final class _ContactRow extends StatelessWidget {
  const _ContactRow({required this.contact, required this.onTap});

  final GlobalSearchContactResult contact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => WeChatListTile(
        key: Key('global-search-contact-${contact.userId}'),
        onTap: onTap,
        leading: UserAvatar(
          nickname: contact.displayName,
          fallbackSeed: contact.cacheKey ?? contact.userId,
          avatarUrl: contact.avatarUrl,
        ),
        title: Text(contact.displayName,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(contact.matchedText ?? '畅聊号：${contact.username}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      );
}

final class _RoomRow extends StatelessWidget {
  const _RoomRow({required this.room, required this.onTap});

  final GlobalSearchRoomResult room;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => WeChatListTile(
        key: Key('global-search-room-${room.roomId}'),
        onTap: onTap,
        leading: UserAvatar(
          nickname: room.displayName,
          fallbackSeed: room.avatarSeed ?? room.roomId,
          avatarUrl: room.avatarUrl,
        ),
        title: Text(
          room.memberCount == null
              ? room.displayName
              : groupRoomNavigationTitle(room.displayName, room.memberCount!),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: room.matchedText == null
            ? null
            : Text(room.matchedText!,
                maxLines: 1, overflow: TextOverflow.ellipsis),
      );
}

final class _ConversationRow extends StatelessWidget {
  const _ConversationRow(
      {required this.conversation, required this.query, required this.onTap});

  final GlobalSearchConversationHit conversation;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hit = conversation.latest;
    return WeChatListTile(
      key: Key('global-search-conversation-${conversation.roomId}'),
      onTap: onTap,
      leading: UserAvatar(
        nickname: conversation.roomName,
        fallbackSeed: conversation.roomAvatarSeed ?? conversation.roomId,
        avatarUrl: conversation.roomAvatarUrl,
      ),
      title: Text(conversation.roomName,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        conversation.isSingleHit
            ? hit.body
            : '${conversation.total}条相关聊天记录',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

final class _MessageHitRow extends StatelessWidget {
  const _MessageHitRow(
      {required this.hit, required this.query, required this.onTap});

  final GlobalSearchMessageHit hit;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => WeChatListTile(
        key: Key('global-search-hit-${hit.eventId}'),
        onTap: onTap,
        leading: UserAvatar(
          nickname: hit.senderName,
          fallbackSeed: hit.senderId,
        ),
        title: Text(hit.senderName,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HighlightedText(text: hit.body, query: query),
            Text(formatSearchResultTime(hit.timestamp),
                style: const TextStyle(
                    fontSize: 11, color: WeChatColors.textTertiary)),
          ],
        ),
      );
}

/// 关键词高亮（基于纯文本片段，不执行消息中的 HTML/markdown）。
final class _HighlightedText extends StatelessWidget {
  const _HighlightedText({required this.text, required this.query});

  final String text;
  final String query;

  @override
  Widget build(BuildContext context) {
    final segments = buildHighlightSnippet(text, query);
    return Text.rich(
      TextSpan(
        children: [
          for (final segment in segments)
            TextSpan(
              text: segment.text,
              style: segment.highlighted
                  ? TextStyle(
                      color: WeChatColors.resolve(
                          context, WeChatColors.brandPrimary),
                      fontWeight: FontWeight.w600)
                  : null,
            ),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

final class _MoreRow extends StatelessWidget {
  const _MoreRow({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => WeChatListTile(
        onTap: onTap,
        title: Text(label,
            style: const TextStyle(
                fontSize: 15, color: WeChatColors.textSecondary)),
      );
}

final class _Section extends StatelessWidget {
  const _Section(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
        child: Text(label,
            key: Key('global-search-section-$label'),
            style: const TextStyle(color: WeChatColors.textSecondary)),
      );
}

final class _Hint extends StatelessWidget {
  const _Hint({super.key, required this.text, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text,
                  style: const TextStyle(
                      color: WeChatColors.textSecondary, fontSize: 14)),
              if (action != null) ...[const SizedBox(height: 8), action!],
            ],
          ),
        ),
      );
}
