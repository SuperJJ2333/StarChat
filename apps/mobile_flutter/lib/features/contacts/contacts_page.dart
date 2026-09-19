import 'contact_actions.dart';
import '../../ui/components/top_more_menu.dart';
import 'scan_qr_page.dart';
import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../core/permissions/blocked_contacts.dart';
import '../../core/support_identity_repository.dart';
import '../matrix/matrix_e2ee_client.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/components/wechat_nav_title.dart';
import '../../ui/components/wechat_contact_index.dart';
import '../../ui/components/wechat_contact_tile.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'contact_models.dart';
import 'contact_tag_pages.dart';
import 'add_friend_profile_page.dart';
import 'friend_request_review_page.dart';
import 'contact_profile_sections.dart';
import '../moments/moment_profile_preview.dart';
import '../search/global_search_page.dart';
import '../friendship/friend_acceptance_coordinator.dart';
import '../friendship/friend_request_snapshot_store.dart';
import '../matrix/profile_repository.dart';
import '../matrix/direct_chat_controller.dart';
import '../../ui/motion/motion_page_route.dart';

typedef ContactAction = Future<void> Function(ContactDetails contact);

abstract final class ContactIndex {
  static const alphabet = <String>[
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
  ];
  static const labels = <String>['★', ...alphabet, '#'];
}

final class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    required this.api,
    required this.onOpenRoom,
    this.matrix,
    required this.pendingFriendRequests,
    this.directChats,
    this.onRequestsChanged,
    this.onFriendRequests,
    this.onMessage,
    this.onVoice,
    this.onVideo,
    this.onGroupChat,
    this.onScan,
    this.onAppearance,
    this.onGroupAddressList,
    this.identityCache,
    this.supportIdentities,
  });

  final ContactsGateway api;
  final MatrixSdkE2eeClient? matrix;

  /// 打开房间（必填）：本页搜索入口把结果交给组合根的统一策略路径。
  final GlobalSearchRoomOpenCallback onOpenRoom;

  final ValueNotifier<int> pendingFriendRequests;
  final DirectChatController? directChats;
  final VoidCallback? onRequestsChanged;
  final VoidCallback? onFriendRequests;
  final ContactAction? onMessage;
  final ContactAction? onVoice;
  final ContactAction? onVideo;
  final VoidCallback? onGroupChat;
  final VoidCallback? onScan;
  final VoidCallback? onAppearance;

  /// BUG4：通讯录首页"群聊"→ 群聊通讯录列表（不再误入发起群聊）；
  /// "+"菜单的"发起群聊"继续走 [onGroupChat]。
  final VoidCallback? onGroupAddressList;
  final ProfileRepository? identityCache;
  final SupportIdentityRepository? supportIdentities;

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

final class _ContactsPageState extends State<ContactsPage> {
  late Future<List<ContactSummary>> contacts;
  final scrollController = ScrollController();
  final sectionOffsets = <String, double>{};
  SupportIdentityRepository? _support;
  Timer? _supportTimer;
  bool _ownsSupport = false;
  List<ContactSummary> _supportContacts = const [];
  int _contactsLoadGeneration = 0;

  @override
  void initState() {
    super.initState();
    final cached = widget.identityCache?.contacts ?? const <ContactSummary>[];
    contacts = cached.isEmpty
        ? widget.api.listContacts()
        : Future.value(List.unmodifiable(cached));
    widget.identityCache?.addListener(_identityChanged);
    _configureSupport();
    _observeSupportContacts(contacts);
    unawaited(
        widget.identityCache?.refreshContactsQuietly() ?? Future<void>.value());
  }

  Future<void> _warmSupport(Iterable<ContactSummary> values) =>
      _support?.warm([
            for (final contact in values) ...[
              contact.userId,
              contact.matrixUserId,
            ],
          ]) ??
      Future<void>.value();

  void _setSupportContacts(List<ContactSummary> values) {
    _supportContacts = List.unmodifiable(values);
    unawaited(_warmSupport(_supportContacts));
  }

  void _observeSupportContacts(Future<List<ContactSummary>> future) {
    final generation = ++_contactsLoadGeneration;
    future.then((values) {
      if (!mounted || generation != _contactsLoadGeneration) return;
      _setSupportContacts(values);
    }, onError: (_, __) {});
  }

  void _configureSupport() {
    _support = widget.supportIdentities ??
        (widget.api is SupportIdentityGateway
            ? SupportIdentityRepository(widget.api as SupportIdentityGateway)
            : null);
    _ownsSupport = widget.supportIdentities == null && _support != null;
    _supportTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_support?.warm([
            for (final contact in _supportContacts) ...[
              contact.userId,
              contact.matrixUserId,
            ],
          ], force: true) ??
          Future<void>.value());
    });
  }

  @override
  void didUpdateWidget(covariant ContactsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.api, widget.api) ||
        oldWidget.supportIdentities != widget.supportIdentities) {
      _supportTimer?.cancel();
      if (_ownsSupport) _support?.dispose();
      _configureSupport();
      _contactsLoadGeneration++;
      _setSupportContacts(widget.identityCache?.contacts ?? _supportContacts);
    }
  }

  void _identityChanged() {
    if (!mounted) return;
    setState(() {
      contacts = Future.value(
        List.unmodifiable(widget.identityCache?.contacts ?? const []),
      );
    });
    _setSupportContacts(widget.identityCache?.contacts ?? const []);
  }

  void reload() {
    final next = widget.api.listContacts();
    _observeSupportContacts(next);
    setState(() {
      contacts = next;
    });
  }

  @override
  void dispose() {
    _supportTimer?.cancel();
    if (_ownsSupport) _support?.dispose();
    widget.identityCache?.removeListener(_identityChanged);
    scrollController.dispose();
    super.dispose();
  }

  String _indexOf(ContactSummary contact) {
    if (contact.isStarred) return '★';
    for (final candidate in [contact.displayName, contact.username]) {
      if (candidate.isEmpty) continue;
      final initial = candidate.characters.first.toUpperCase();
      if (ContactIndex.alphabet.contains(initial)) return initial;
    }
    return '#';
  }

  Map<String, List<ContactSummary>> _groupContacts(
    List<ContactSummary> values,
  ) {
    final result = <String, List<ContactSummary>>{};
    for (final contact in values) {
      (result[_indexOf(contact)] ??= []).add(contact);
    }
    for (final contacts in result.values) {
      contacts.sort(
        (a, b) => a.displayName.toLowerCase().compareTo(
              b.displayName.toLowerCase(),
            ),
      );
    }
    return result;
  }

  Future<void> _jumpTo(String label) async {
    final offset = sectionOffsets[label];
    if (offset == null || !scrollController.hasClients) return;
    await scrollController.animateTo(
      offset.clamp(0, scrollController.position.maxScrollExtent).toDouble(),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final businessApi = widget.api is BusinessApiClient
        ? widget.api as BusinessApiClient
        : null;
    return WeChatPageScaffold.navigation(
      backgroundColor: WeChatColors.pageBackground(context),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.navigationBackground(context),
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        transitionBetweenRoutes: false,
        middle: const WeChatNavTitle('通讯录'),
        trailing: businessApi == null
            ? null
            : Row(mainAxisSize: MainAxisSize.min, children: [
                CupertinoButton(
                  key: const Key('contacts-search'),
                  padding: EdgeInsets.zero,
                  onPressed: () => Navigator.push(
                    context,
                    MotionPageRoute(
                      builder: (_) => GlobalSearchPage(
                        contactActions: ContactActions(
                          onMessage: widget.onMessage,
                          onVoice: widget.onVoice,
                          onVideo: widget.onVideo,
                        ),
                        identityCache: widget.identityCache,
                        api: businessApi,
                        matrix: widget.matrix,
                        // 必填：通讯录 Tab 的搜索与消息 Tab 拥有完全相同的
                        // 打开能力（同一条 RoomOpeningPolicy 路径）。
                        onOpenRoom: widget.onOpenRoom,
                      ),
                    ),
                  ),
                  child: const Icon(CupertinoIcons.search, size: 22),
                ),
                CupertinoButton(
                  key: const Key('contacts-more'),
                  padding: EdgeInsets.zero,
                  onPressed: () => showTopMoreMenu(
                    context,
                    onCreateGroup: () => widget.onGroupChat?.call(),
                    onAddFriend: () {
                      Navigator.push(
                          context,
                          MotionPageRoute(
                              builder: (_) => AddFriendPage(
                                  contactActions: ContactActions(
                                    onMessage: widget.onMessage,
                                    onVoice: widget.onVoice,
                                    onVideo: widget.onVideo,
                                  ),
                                  api: businessApi,
                                  identityCache: widget.identityCache)));
                    },
                    onScan: widget.onScan ??
                        () => Navigator.of(context, rootNavigator: true).push(
                            MotionPageRoute(
                                builder: (_) => ScanQrPage(
                                    api: businessApi,
                                    groupJoinApi: businessApi))),
                    onAppearance: () => widget.onAppearance?.call(),
                  ),
                  child: const Icon(CupertinoIcons.ellipsis_circle, size: 22),
                ),
              ]),
      ),
      child: SafeArea(
        child: FutureBuilder<List<ContactSummary>>(
          initialData: widget.identityCache?.contacts,
          future: contacts,
          builder: (_, snapshot) {
            final grouped = _groupContacts(
              snapshot.data ?? const <ContactSummary>[],
            );
            // BUG-03：字母跳转偏移量必须与真实行高一致。三个入口行与联系人
            // 行都固定为 contactTileHeight，分组标题固定为 25，因此这里的
            // 算式与实际布局逐项对应（入口行也用 SizedBox 固定高度）。
            var sectionOffset = businessApi == null
                ? 0.0
                : _ContactSectionHeader.leadingEntryCount *
                    WeChatDimensions.contactTileHeight;
            sectionOffsets.clear();
            for (final label in ContactIndex.labels) {
              final contacts = grouped[label];
              if (contacts == null || contacts.isEmpty) continue;
              sectionOffsets[label] = sectionOffset;
              sectionOffset += _ContactSectionHeader.height +
                  contacts.length * WeChatDimensions.contactTileHeight;
            }
            return Stack(
              children: [
                ListView(
                  controller: scrollController,
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  padding: const EdgeInsets.only(
                      right: WeChatDimensions.contactIndexWidth),
                  children: [
                    if (businessApi != null) ...[
                      // BUG-03：入口行高度固定为 contactTileHeight，
                      // 使字母索引的偏移量与实际布局严格一致。
                      SizedBox(
                        height: WeChatDimensions.contactTileHeight,
                        child: WeChatListTile(
                          leadingSize: WeChatDimensions.contactAvatar,
                          leadingToTitle: WeChatSpacing.md,
                          showDivider: true,
                          leading: const Icon(CupertinoIcons.person_add_solid),
                          title: const Text('新的朋友'),
                          trailing: ValueListenableBuilder<int>(
                            valueListenable: widget.pendingFriendRequests,
                            builder: (_, count, __) => count > 0
                                ? Container(
                                    key: const Key('friend-request-badge'),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 7, vertical: 2),
                                    decoration: const BoxDecoration(
                                      color: WeChatColors.danger,
                                      borderRadius:
                                          BorderRadius.all(Radius.circular(10)),
                                    ),
                                    child: Text(
                                      count > 99 ? '99+' : '$count',
                                      style: const TextStyle(
                                          color: CupertinoColors.white,
                                          fontSize: 11),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                          onTap: () async {
                            if (widget.onFriendRequests != null) {
                              widget.onFriendRequests!();
                              return;
                            }
                            await Navigator.push(
                              context,
                              MotionPageRoute(
                                builder: (_) => FriendRequestsPage(
                                  api: businessApi,
                                  pendingRequests: widget.pendingFriendRequests,
                                  directChats: widget.directChats,
                                  onRequestsChanged: widget.onRequestsChanged,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      SizedBox(
                        height: WeChatDimensions.contactTileHeight,
                        child: WeChatListTile(
                          key: const Key('contacts-group-address-entry'),
                          leadingSize: WeChatDimensions.contactAvatar,
                          leadingToTitle: WeChatSpacing.md,
                          showDivider: true,
                          leading: const Icon(CupertinoIcons.person_3_fill),
                          title: const Text('群聊'),
                          onTap:
                              widget.onGroupAddressList ?? widget.onGroupChat,
                        ),
                      ),
                      SizedBox(
                        height: WeChatDimensions.contactTileHeight,
                        child: WeChatListTile(
                          leadingSize: WeChatDimensions.contactAvatar,
                          leadingToTitle: WeChatSpacing.md,
                          showDivider: true,
                          leading: const Icon(CupertinoIcons.tag_fill),
                          title: const Text('标签'),
                          onTap: () => Navigator.push(
                            context,
                            MotionPageRoute(
                              builder: (_) => ContactTagsPage(
                                  api: businessApi,
                                  identityCache: widget.identityCache),
                            ),
                          ),
                        ),
                      ),
                    ],
                    for (final label in ContactIndex.labels)
                      if (grouped[label]?.isNotEmpty ?? false) ...[
                        _ContactSectionHeader(
                          label: label == '★' ? '星标好友' : label,
                        ),
                        for (var i = 0;
                            i < (grouped[label]?.length ?? 0);
                            i++)
                          WeChatContactTile(
                            nickname: grouped[label]![i].displayName,
                            fallbackSeed: widget.identityCache
                                    ?.resolveIdentity(
                                        userId: grouped[label]![i].userId)
                                    .cacheKey ??
                                grouped[label]![i].username,
                            avatarUrl: grouped[label]![i].avatarUrl,
                            supportIdentities: _support,
                            userId: grouped[label]![i].userId,
                            matrixUserId: grouped[label]![i].matrixUserId,
                            // 好友之间画共享渐隐分割线；分组最后一位不画，
                            // 由分组标题承担分隔。
                            showDivider: i < grouped[label]!.length - 1,
                            onTap: () async {
                              final changed = await Navigator.of(context,
                                      rootNavigator: true)
                                  .push<bool>(
                                MotionPageRoute(
                                  builder: (_) => ContactProfilePage(
                                    identityCache: widget.identityCache,
                                    supportIdentities: _support,
                                    api: widget.api,
                                    initialContact:
                                        grouped[label]![i].toDetails(),
                                    onMessage: widget.onMessage,
                                    onVoice: widget.onVoice,
                                    onVideo: widget.onVideo,
                                    onContactDeleted:
                                        widget.identityCache?.removeContact,
                                    onContactUpdated:
                                        widget.identityCache == null
                                            ? null
                                            : (updated) => widget.identityCache!
                                                    .applyUpdatedContact(
                                                  updated.toSummary(),
                                                ),
                                  ),
                                ),
                              );
                              if (!mounted) return;
                              if (changed == true) reload();
                            },
                          ),
                      ],
                  ],
                ),
                // BUG-03：索引列宽度取设计 token，且整列留白后垂直居中，
                // 不覆盖顶部导航/底部安全区（SafeArea 已由外层保证）。
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 0,
                  width: WeChatDimensions.contactIndexWidth,
                  child: AnimatedBuilder(
                    animation: scrollController,
                    child: WeChatContactIndex(
                        labels: ContactIndex.labels, onSelected: _jumpTo),
                    builder: (_, child) {
                      final pullDown = scrollController.hasClients
                          ? (-scrollController.offset)
                              .clamp(0.0, double.infinity)
                          : 0.0;
                      return Transform.translate(
                        offset: Offset(0, pullDown),
                        child: child,
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

final class _ContactSectionHeader extends StatelessWidget {
  const _ContactSectionHeader({required this.label});

  /// 分组标题固定高度（字母索引跳转偏移量按它计算）。
  static const height = 25.0;

  /// 分组之前的固定入口行数（新的朋友 / 群聊 / 标签）。
  static const leadingEntryCount = 3;

  final String label;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: CupertinoTheme.of(context).scaffoldBackgroundColor,
        child: SizedBox(
          key: Key('contact-section-$label'),
          height: height,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              label,
              style: const TextStyle(
                color: WeChatColors.textSecondary,
                fontSize: WeChatTypography.caption,
              ),
            ),
          ),
        ),
      );
}

final class ContactProfilePage extends StatefulWidget {
  const ContactProfilePage({
    super.key,
    required this.api,
    required this.initialContact,
    this.identityCache,
    this.onMessage,
    this.onVoice,
    this.onVideo,
    this.onContactUpdated,
    this.onContactDeleted,
    this.supportIdentities,
  });

  final ContactsGateway api;
  final ProfileRepository? identityCache;
  final ContactDetails initialContact;
  final ContactAction? onMessage;
  final ContactAction? onVoice;
  final ContactAction? onVideo;
  final Future<void> Function(ContactDetails contact)? onContactUpdated;
  final Future<void> Function(String userId)? onContactDeleted;
  final SupportIdentityRepository? supportIdentities;

  @override
  State<ContactProfilePage> createState() => _ContactProfilePageState();
}

final class _ContactProfilePageState extends State<ContactProfilePage> {
  late ContactDetails contact = widget.initialContact;
  ContactSelection? _contactSelection;
  var _presenceRequestGeneration = 0;
  SupportIdentityRepository? _support;
  Timer? _supportTimer;
  bool _ownsSupport = false;

  @override
  void initState() {
    super.initState();
    _bindIdentity();
    _readIdentity();
    _configureSupport();
    unawaited(_refreshPresence());
  }

  void _configureSupport() {
    _support = widget.supportIdentities ??
        (widget.api is SupportIdentityGateway
            ? SupportIdentityRepository(widget.api as SupportIdentityGateway)
            : null);
    _ownsSupport = widget.supportIdentities == null && _support != null;
    unawaited(_support?.warm([contact.userId, contact.matrixUserId]) ??
        Future<void>.value());
    _supportTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_support?.warm([contact.userId, contact.matrixUserId], force: true) ??
          Future<void>.value());
    });
  }

  /// 任意入口（会话/朋友圈/搜索/通讯录）打开资料页即向服务端自取
  /// 该好友最新详情：在线状态与备注不依赖入口数据新鲜度；非好友
  /// （404）保持隐藏状态行；失败静默保留现有内容。
  /// 在线状态后台刷新节流：同一好友 60 秒内重复进页不再发请求，
  /// 已有数据且无变化时不重建 UI（无感加载）。
  // Expandos keep the cache attached to its API/repository owners. A static
  // tuple-keyed map would retain old account owners after sign-out.
  static final Expando<Expando<Map<String, DateTime>>> _presenceFetchedAtByApi =
      Expando();
  static const _presenceTtl = Duration(minutes: 1);

  Future<void> _refreshPresence({bool force = false}) async {
    final userId = contact.userId;
    final api = widget.api;
    final identityCache = widget.identityCache;
    final perRepository =
        _presenceFetchedAtByApi[api] ??= Expando<Map<String, DateTime>>();
    final cacheOwner = identityCache ?? api;
    final fetchedAt = perRepository[cacheOwner] ??= <String, DateTime>{};
    if (!force) {
      final last = fetchedAt[userId];
      if (last != null &&
          DateTime.now().difference(last) < _presenceTtl &&
          contact.lastSeenKnown) {
        return;
      }
    }
    final requestSnapshot = contact;
    final generation = ++_presenceRequestGeneration;
    try {
      final fresh = await api.fetchFriendDetail(userId);
      if (!_isCurrentPresenceRequest(generation, api, identityCache, userId)) {
        return;
      }
      fetchedAt[userId] = DateTime.now();
      if (fresh == null) {
        await identityCache?.applyContactPresence(
          userId,
          lastSeenKnown: false,
          lastSeenAt: null,
        );
        if (!_isCurrentPresenceRequest(
            generation, api, identityCache, userId)) {
          return;
        }
        final latest = identityCache?.contactsByUserId[userId]?.toDetails();
        setState(() => contact = latest ??
            contact.copyWith(
              lastSeenKnown: false,
              clearLastSeen: true,
            ));
        return;
      }
      if (fresh.userId != userId) return;
      final current =
          identityCache?.contactsByUserId[userId]?.toDetails() ?? contact;
      final merged = _mergeAuthorizedDetail(requestSnapshot, current, fresh);
      await identityCache?.applyUpdatedContact(merged.toSummary());
      if (!_isCurrentPresenceRequest(generation, api, identityCache, userId)) {
        return;
      }
      final latest = identityCache?.contactsByUserId[userId]?.toDetails();
      setState(() => contact = latest ?? merged);
    } catch (_) {
      // 网络失败：保留入口携带的数据（通讯录路径仍有缓存值）。
    }
  }

  bool _isCurrentPresenceRequest(
    int generation,
    ContactsGateway api,
    ProfileRepository? identityCache,
    String userId,
  ) =>
      mounted &&
      generation == _presenceRequestGeneration &&
      identical(api, widget.api) &&
      identical(identityCache, widget.identityCache) &&
      userId == contact.userId;

  ContactDetails _mergeAuthorizedDetail(
    ContactDetails snapshot,
    ContactDetails current,
    ContactSummary fresh,
  ) {
    bool tagsEqual(List<String> a, List<String> b) =>
        a.length == b.length &&
        a.indexed.every((entry) => entry.$2 == b[entry.$1]);
    final avatarChanged = snapshot.avatarUrl != current.avatarUrl ||
        snapshot.avatarIsKnown != current.avatarIsKnown;
    final useFreshPresence = fresh.lastSeenKnown;
    return ContactDetails(
      userId: current.userId,
      username: fresh.username,
      matrixUserId: fresh.matrixUserId,
      nickname: snapshot.nickname == current.nickname
          ? fresh.nickname
          : current.nickname,
      remark: snapshot.remark == current.remark ? fresh.remark : current.remark,
      avatarUrl: avatarChanged || !fresh.avatarIsKnown
          ? current.avatarUrl
          : fresh.avatarUrl,
      avatarIsKnown:
          avatarChanged || !fresh.avatarIsKnown ? current.avatarIsKnown : true,
      nudgeSuffix: snapshot.nudgeSuffix == current.nudgeSuffix
          ? fresh.nudgeSuffix
          : current.nudgeSuffix,
      momentsPermission: snapshot.momentsPermission == current.momentsPermission
          ? fresh.momentsPermission
          : current.momentsPermission,
      tags: tagsEqual(snapshot.tags, current.tags) ? fresh.tags : current.tags,
      starred:
          snapshot.starred == current.starred ? fresh.starred : current.starred,
      lastSeenAt: useFreshPresence ? fresh.lastSeenAt : current.lastSeenAt,
      lastSeenKnown: useFreshPresence ? true : current.lastSeenKnown,
    );
  }

  void _bindIdentity() {
    _contactSelection?.removeListener(_identityChanged);
    _contactSelection?.dispose();
    _contactSelection = widget.identityCache?.selectContact(contact.userId);
    _contactSelection?.addListener(_identityChanged);
  }

  void _readIdentity() {
    final updated = _contactSelection?.value;
    if (updated != null) contact = updated.toDetails();
  }

  void _identityChanged() {
    if (mounted) setState(_readIdentity);
  }

  @override
  void didUpdateWidget(covariant ContactProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final contactChanged =
        oldWidget.initialContact.userId != widget.initialContact.userId;
    final repositoryChanged = oldWidget.identityCache != widget.identityCache;
    final apiChanged = oldWidget.api != widget.api;
    if (contactChanged || repositoryChanged) contact = widget.initialContact;
    if (repositoryChanged || contactChanged || apiChanged) {
      _presenceRequestGeneration++;
    }
    if (repositoryChanged || contactChanged) {
      _bindIdentity();
      _readIdentity();
      if (contactChanged) {
        unawaited(_support?.warm([contact.userId, contact.matrixUserId],
                force: true) ??
            Future<void>.value());
      }
    }
    if (repositoryChanged || contactChanged || apiChanged) {
      unawaited(_refreshPresence());
    }
    if (!identical(oldWidget.api, widget.api) ||
        oldWidget.supportIdentities != widget.supportIdentities) {
      _supportTimer?.cancel();
      if (_ownsSupport) _support?.dispose();
      _configureSupport();
    }
  }

  @override
  void dispose() {
    _presenceRequestGeneration++;
    _supportTimer?.cancel();
    if (_ownsSupport) _support?.dispose();
    _contactSelection?.removeListener(_identityChanged);
    _contactSelection?.dispose();
    super.dispose();
  }

  Future<void> _contactUpdated(ContactDetails updated) async {
    await widget.identityCache?.applyUpdatedContact(updated.toSummary());
    await widget.onContactUpdated?.call(updated);
  }

  Future<void> _contactDeleted(String userId) async {
    await widget.identityCache?.removeContact(userId);
    await widget.onContactDeleted?.call(userId);
  }

  Future<void> _openMore() async {
    final result = await Navigator.push<ContactMoreResult>(
      context,
      MotionPageRoute(
        builder: (_) => ContactMorePage(
          api: widget.api,
          contact: contact,
          onContactUpdated: _contactUpdated,
          onContactDeleted: _contactDeleted,
        ),
      ),
    );
    if (!mounted || result == null) return;
    if (result.deleted) {
      Navigator.pop(context, true);
    } else {
      final updated = result.contact!;
      if (mounted) setState(() => contact = updated);
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: const Text('好友资料'),
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: _openMore,
            child: const Icon(CupertinoIcons.ellipsis),
          ),
        ),
        child: SafeArea(
          child: ListView(
            children: [
              FriendIdentityCard(
                  contact: contact,
                  identityCache: widget.identityCache,
                  supportIdentities: _support),
              if (widget.api is BusinessApiClient)
                MomentProfilePreview(
                    contactActions: ContactActions(
                      onMessage: widget.onMessage,
                      onVoice: widget.onVoice,
                      onVideo: widget.onVideo,
                    ),
                    identityCache: widget.identityCache,
                    api: widget.api as BusinessApiClient,
                    userId: contact.userId,
                    displayName: contact.primaryDisplayName,
                    key: ValueKey(
                        'profile-moments-${contact.userId}-${contact.momentsPermission}')),
              FriendActionColumn(
                onMessage: widget.onMessage == null
                    ? null
                    : () => widget.onMessage!(contact),
                onVoice: widget.onVoice == null
                    ? null
                    : () => widget.onVoice!(contact),
                onVideo: widget.onVideo == null
                    ? null
                    : () => widget.onVideo!(contact),
              ),
            ],
          ),
        ),
      );
}

final class ContactMoreResult {
  const ContactMoreResult.updated(this.contact) : deleted = false;
  const ContactMoreResult.deleted()
      : contact = null,
        deleted = true;
  final ContactDetails? contact;
  final bool deleted;
}

final class ContactMorePage extends StatefulWidget {
  const ContactMorePage({
    super.key,
    required this.api,
    required this.contact,
    this.onContactUpdated,
    this.onContactDeleted,
  });
  final ContactsGateway api;
  final ContactDetails contact;
  final Future<void> Function(ContactDetails contact)? onContactUpdated;
  final Future<void> Function(String userId)? onContactDeleted;
  @override
  State<ContactMorePage> createState() => _ContactMorePageState();
}

final class _ContactMorePageState extends State<ContactMorePage> {
  late final remark = TextEditingController(text: widget.contact.remark);
  late final tags = TextEditingController(text: widget.contact.tags.join(','));
  late String permission = widget.contact.momentsPermission;
  late ContactDetails current = widget.contact;

  /// 黑名单真实状态：null = 尚未从服务端读到（开关禁用），
  /// 避免用「默认 false」冒充已知状态（BUG-10）。
  bool? blocked;
  bool blocking = false;
  bool saving = false;
  String? errorMessage;

  @override
  void initState() {
    super.initState();
    // 本地优先：已经读过服务端黑名单时，先用本地投影把开关渲染成已知状态，
    // 断网/请求未回来时也能看到真实拉黑状态（而不是一个禁用的开关）。
    if (blockedContacts.hasSnapshot) {
      blocked = blockedContacts.isBlocked(widget.contact.userId);
    }
    unawaited(_loadBlockState());
  }

  /// 从权威接口读回拉黑状态（服务端持久化 → 重开 App 仍然是拉黑）。
  Future<void> _loadBlockState() async {
    try {
      final body = await widget.api.blockList();
      final items = (body['items'] as List?) ?? const [];
      final ids = <String>{
        for (final item in items)
          if (item is Map && item['user_id'] != null)
            item['user_id'].toString(),
      };
      blockedContacts.replaceAll(ids, fromServer: true);
      if (mounted) setState(() => blocked = ids.contains(widget.contact.userId));
    } catch (_) {
      // 失败时只有「确实读过服务端」的本地投影才可作为已知状态；
      // 从未读过就保持 null（未知），不用默认 false 冒充权威结果。
      if (mounted && blockedContacts.hasSnapshot) {
        setState(() =>
            blocked = blockedContacts.isBlocked(widget.contact.userId));
      }
    }
  }

  @override
  void dispose() {
    remark.dispose();
    tags.dispose();
    super.dispose();
  }

  Future<bool> _confirm(String title, String content, {String confirmLabel = '删除'}) async =>
      await showCupertinoDialog<bool>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(confirmLabel),
            ),
          ],
        ),
      ) ??
      false;

  Future<bool> _persist() async {
    if (saving) return false;
    setState(() {
      saving = true;
      errorMessage = null;
    });
    try {
      final updated = await widget.api.updateContactDetails(
        current,
        remark: remark.text.trim().isEmpty ? null : remark.text.trim(),
        tags: tags.text
            .split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList(growable: false),
        momentsPermission: permission,
      );
      await widget.onContactUpdated?.call(updated);
      if (mounted) setState(() => current = updated);
      return true;
    } catch (_) {
      if (mounted) {
        setState(() => errorMessage = '备注保存失败，请检查网络后重试');
      }
      return false;
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _editText(
    String title,
    TextEditingController controller,
  ) async {
    final accepted = await showCupertinoDialog<bool>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: Text(title),
            content: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: CupertinoTextField(controller: controller),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('保存'),
              ),
            ],
          ),
        ) ??
        false;
    if (accepted) await _persist();
  }

  Future<void> _pickTags() async {
    final updated = await Navigator.push<ContactDetails>(
      context,
      MotionPageRoute(
        builder: (_) => ContactTagPickerPage(
          api: widget.api,
          contact: current,
        ),
      ),
    );
    if (updated == null || !mounted) return;
    await widget.onContactUpdated?.call(updated);
    if (!mounted) return;
    setState(() {
      current = updated;
      tags.text = updated.tags.join(',');
    });
  }

  Future<void> _choosePermission() async {
    final selected = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: const Text('朋友圈权限'),
        actions: [
          for (final item in const {
            'DEFAULT': '全部可见',
            'HIDE_MINE': '不让他看我',
            'HIDE_THEIRS': '不看他',
            'MUTUAL_HIDE': '互相不可见',
          }.entries)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(sheetContext, item.key),
              child: Text(item.value),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheetContext),
          child: const Text('取消'),
        ),
      ),
    );
    if (selected == null || selected == permission) return;
    setState(() => permission = selected);
    await _persist();
  }

  /// 黑名单开关：双向可用——加入走 `POST /blocks`，移出走
  /// `DELETE /blocks/{id}`；服务端成功后同步本地投影，聊天发送门立刻生效。
  Future<void> _setBlocked(bool value) async {
    if (blocking || blocked == null || blocked == value) return;
    if (value) {
      final confirmed = await _confirm(
        '加入黑名单',
        '加入后将不再接收对方的好友互动，聊天中也将无法继续发送消息。',
        confirmLabel: '加入',
      );
      if (!confirmed) return;
    }
    setState(() {
      blocking = true;
      errorMessage = null;
    });
    try {
      if (value) {
        await widget.api.blockContact(widget.contact.userId);
      } else {
        await widget.api.unblockContact(widget.contact.userId);
      }
      if (!mounted) return;
      // 立即生效：本地投影与聊天发送门读同一份状态，不必等下一次整表刷新。
      if (value) {
        blockedContacts.markBlocked(widget.contact.userId);
      } else {
        blockedContacts.markUnblocked(widget.contact.userId);
      }
      setState(() => blocked = value);
      // 好友列表/会话气泡的权限投影与设置页保持一致。
      await widget.onContactUpdated?.call(current);
    } catch (_) {
      if (mounted) {
        setState(() => errorMessage =
            value ? '加入黑名单失败，请重试' : '移出黑名单失败，请重试');
      }
    } finally {
      if (mounted) setState(() => blocking = false);
    }
  }

  Future<void> _delete() async {
    try {
      if (!await _confirm('删除好友', '删除后将不再显示在你的通讯录中，且需要重新发送好友申请。')) {
        return;
      }
      await widget.api.deleteContact(widget.contact.userId);
      await widget.onContactDeleted?.call(widget.contact.userId);
      if (mounted) Navigator.pop(context, const ContactMoreResult.deleted());
    } catch (_) {
      if (mounted) {
        await showCupertinoDialog<void>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: const Text('删除失败'),
            content: const Text('删除好友失败，请重试。'),
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
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: const Text('好友设置'),
          leading: CupertinoNavigationBarBackButton(
            onPressed: () => Navigator.pop(
              context,
              ContactMoreResult.updated(current),
            ),
          ),
        ),
        child: SafeArea(
          child: ListView(
            children: [
              if (errorMessage != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Text(
                    errorMessage!,
                    key: const Key('contact-save-error'),
                    style: const TextStyle(color: CupertinoColors.systemRed),
                  ),
                ),
              CupertinoListSection(
                margin: const EdgeInsets.only(top: 12),
                children: [
                  CupertinoListTile(
                    title: const Text('备注'),
                    additionalInfo: Text(remark.text),
                    trailing: const CupertinoListTileChevron(),
                    onTap: () => _editText('设置备注', remark),
                  ),
                  CupertinoListTile(
                    title: const Text('标签'),
                    additionalInfo: Text(tags.text),
                    trailing: const CupertinoListTileChevron(),
                    onTap: _pickTags,
                  ),
                  CupertinoListTile(
                    title: const Text('朋友圈权限'),
                    additionalInfo: Text(
                      permission == 'DEFAULT' ? '全部可见' : '已限制',
                    ),
                    trailing: const CupertinoListTileChevron(),
                    onTap: _choosePermission,
                  ),
                  CupertinoListTile(
                    title: const Text('黑名单'),
                    trailing: blocking
                        ? const CupertinoActivityIndicator()
                        : CupertinoSwitch(
                            key: const Key('contact-block-switch'),
                            value: blocked ?? false,
                            onChanged: blocked == null ? null : _setBlocked,
                          ),
                  ),
                ],
              ),
              CupertinoListSection(
                margin: const EdgeInsets.only(top: 12),
                children: [
                  CupertinoListTile(
                    title: const Text(
                      '删除好友',
                      style: TextStyle(color: CupertinoColors.systemRed),
                    ),
                    leading: const Icon(
                      CupertinoIcons.delete,
                      color: CupertinoColors.systemRed,
                    ),
                    onTap: _delete,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

final class LegacyContactTagsPage extends StatefulWidget {
  const LegacyContactTagsPage({super.key, required this.api});
  final BusinessApiClient api;
  @override
  State<LegacyContactTagsPage> createState() => _ContactTagsPageState();
}

final class ContactTagPickerPage extends StatefulWidget {
  const ContactTagPickerPage({
    super.key,
    required this.api,
    required this.contact,
  });
  final ContactsGateway api;
  final ContactDetails contact;

  @override
  State<ContactTagPickerPage> createState() => _ContactTagPickerPageState();
}

final class _ContactTagPickerPageState extends State<ContactTagPickerPage> {
  late final selected = {...widget.contact.tags};
  late Future<Map<String, dynamic>> tags = widget.api.contactTags();

  Future<void> _create() async {
    final controller = TextEditingController();
    final value = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('新建标签'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(controller: controller),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty) return;
    await widget.api.createContactTag(value);
    if (mounted) setState(() => tags = widget.api.contactTags());
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: const Text('标签'),
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            child: const Text('完成'),
            onPressed: () async {
              final updated = await widget.api.updateContactDetails(
                widget.contact,
                remark: widget.contact.remark,
                tags: selected.toList(growable: false),
                momentsPermission: widget.contact.momentsPermission,
              );
              if (context.mounted) Navigator.pop(context, updated);
            },
          ),
        ),
        child: SafeArea(
          child: FutureBuilder<Map<String, dynamic>>(
            future: tags,
            builder: (_, snapshot) {
              final items = (snapshot.data?['items'] as List?) ?? const [];
              final loading = snapshot.connectionState ==
                      ConnectionState.waiting &&
                  !snapshot.hasData;
              return ListView(
                children: [
                  WeChatListTile(
                    title: const Text('新建标签'),
                    leading: const Icon(CupertinoIcons.add_circled),
                    onTap: _create,
                  ),
                  // 加载中与失败必须区分：旧实现失败时只剩「新建标签」一行，
                  // 用户看不出标签列表是空的还是没加载出来。
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(child: CupertinoActivityIndicator()),
                    ),
                  if (snapshot.hasError)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Column(children: [
                        const Text('标签加载失败',
                            style: TextStyle(
                                fontSize: 14, color: WeChatColors.textSecondary)),
                        const SizedBox(height: 8),
                        CupertinoButton(
                          key: const Key('tag-picker-tags-retry'),
                          onPressed: () =>
                              setState(() => tags = widget.api.contactTags()),
                          child: const Text('重试'),
                        ),
                      ]),
                    ),
                  for (final raw in items)
                    WeChatListTile(
                      title: Text(raw['name'].toString()),
                      trailing: Icon(
                        selected.contains(raw['name'].toString())
                            ? CupertinoIcons.check_mark_circled_solid
                            : CupertinoIcons.circle,
                        color: selected.contains(raw['name'].toString())
                            ? WeChatColors.brandPrimary
                            : WeChatColors.textTertiary,
                      ),
                      onTap: () => setState(() {
                        final name = raw['name'].toString();
                        selected.contains(name)
                            ? selected.remove(name)
                            : selected.add(name);
                      }),
                    ),
                ],
              );
            },
          ),
        ),
      );
}

final class _ContactTagsPageState extends State<LegacyContactTagsPage> {
  final name = TextEditingController();
  late Future<Map<String, dynamic>> tags = widget.api.contactTags();
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> _rename(Map tag) async {
    final field = TextEditingController(text: tag['name'].toString());
    final value = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('重命名标签'),
        content: CupertinoTextField(controller: field, autofocus: true),
        actions: [
          CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
          CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext, field.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    field.dispose();
    if (value == null || value.isEmpty) return;
    await widget.api.renameContactTag(tag['id'].toString(), value);
    if (mounted) setState(() => tags = widget.api.contactTags());
  }

  Future<void> _delete(Map tag) async {
    await widget.api.deleteContactTag(tag['id'].toString());
    if (mounted) setState(() => tags = widget.api.contactTags());
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text('标签')),
        child: SafeArea(
          child: FutureBuilder<Map<String, dynamic>>(
            future: tags,
            builder: (_, snapshot) {
              final items = (snapshot.data?['items'] as List?) ?? const [];
              return ListView(
                children: [
                  CupertinoListSection.insetGrouped(
                    children: [
                      CupertinoTextField(
                        controller: name,
                        placeholder: '新标签名称',
                        padding: const EdgeInsets.all(12),
                      ),
                      ModernActionButton(
                        icon: CupertinoIcons.add_circled,
                        label: '创建标签',
                        onPressed: () async {
                          await widget.api.createContactTag(name.text.trim());
                          name.clear();
                          if (mounted) {
                            setState(() => tags = widget.api.contactTags());
                          }
                        },
                      ),
                    ],
                  ),
                  for (final tag in items)
                    WeChatListTile(
                      leading: const Icon(CupertinoIcons.tag),
                      title: Text(tag['name'].toString()),
                      onTap: () =>
                          _rename(Map<String, dynamic>.from(tag as Map)),
                      trailing: CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () =>
                            _delete(Map<String, dynamic>.from(tag as Map)),
                        child: const Icon(CupertinoIcons.delete,
                            color: CupertinoColors.systemRed),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
}

final class AddFriendPage extends StatefulWidget {
  const AddFriendPage({
    super.key,
    required this.api,
    this.identityCache,
    this.contactActions,
  });
  final ContactActions? contactActions;
  final ProfileRepository? identityCache;
  final AddFriendGateway api;
  @override
  State<AddFriendPage> createState() => _AddFriendState();
}

final class _AddFriendState extends State<AddFriendPage> {
  static const _minQueryLength = 2;

  final q = TextEditingController();
  Timer? _debounce;
  List items = [];
  String? hint = '输入至少 $_minQueryLength 个字符，可通过畅聊号或邮箱搜索';
  bool searching = false;

  @override
  void initState() {
    super.initState();
    widget.identityCache?.addListener(_identityChanged);
    q.addListener(_onChanged);
  }

  @override
  void dispose() {
    q.removeListener(_onChanged);
    _debounce?.cancel();
    q.dispose();
    widget.identityCache?.removeListener(_identityChanged);
    super.dispose();
  }

  void _identityChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant AddFriendPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identityCache != widget.identityCache) {
      oldWidget.identityCache?.removeListener(_identityChanged);
      widget.identityCache?.addListener(_identityChanged);
    }
  }

  String _displayName(Map user) =>
      widget.identityCache
          ?.resolveIdentity(
              userId: user['user_id']?.toString(),
              username: user['username']?.toString(),
              nickname: user['nickname']?.toString())
          .displayName ??
      ContactSummary(
              userId: user['user_id'].toString(),
              username: user['username'].toString(),
              matrixUserId: '',
              nickname: user['nickname']?.toString())
          .displayName;

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _search);
  }

  Future<void> _search() async {
    final query = q.text.trim();
    if (query.length < _minQueryLength) {
      if (!mounted) return;
      setState(() {
        items = [];
        searching = false;
        hint = '输入至少 $_minQueryLength 个字符，可通过畅聊号或邮箱搜索';
      });
      return;
    }
    setState(() => searching = true);
    try {
      final result = await widget.api.searchUsers(query);
      if (!mounted) return;
      setState(() {
        items = result['items'] as List;
        searching = false;
        hint = items.isEmpty ? '未找到匹配的用户' : null;
      });
    } on BusinessApiException catch (error) {
      if (!mounted) return;
      // 失败不覆盖：保留上一次成功的结果，只更新提示（微信级加载模型）。
      setState(() {
        searching = false;
        hint = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        searching = false;
        hint = '搜索失败，正在显示上次结果';
      });
    }
  }

  void _openRequestPage(Map user) {
    // BUG 2：先看资料再决定是否添加，禁止快捷直接发送请求。
    final nickname = user['nickname']?.toString();
    Navigator.push(
      context,
      MotionPageRoute(
        builder: (_) => AddFriendProfilePage(
          contactActions: widget.contactActions,
          identityCache: widget.identityCache,
          api: widget.api,
          userId: user['user_id'].toString(),
          username: user['username'].toString(),
          nickname: nickname != null && nickname.isNotEmpty
              ? nickname
              : user['username'].toString(),
          relationshipState: user['relationship_state']?.toString() ?? 'NONE',
          avatarUrl: user['avatar_url']?.toString(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text('添加朋友')),
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: CupertinoSearchTextField(
                controller: q,
                placeholder: '畅聊号 / 邮箱',
                onSubmitted: (_) => _search(),
              ),
            ),
            if (searching)
              const Padding(
                padding: EdgeInsets.all(12),
                child: CupertinoActivityIndicator(),
              )
            else if (hint != null)
              Padding(
                key: const Key('add-friend-hint'),
                padding: const EdgeInsets.all(16),
                child: Text(
                  hint!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: WeChatColors.textSecondary,
                  ),
                ),
              ),
            Expanded(
              child: ListView(
                children: [
                  for (final user in items)
                    WeChatListTile(
                      key: Key('add-friend-${user['user_id']}'),
                      onTap: () => _openRequestPage(user as Map),
                      leading: UserAvatar(
                        nickname: _displayName(user),
                        fallbackSeed: widget.identityCache
                                ?.resolveIdentity(
                                    userId: user['user_id'].toString())
                                .cacheKey ??
                            user['user_id'].toString(),
                        avatarUrl: widget.identityCache == null
                            ? user['avatar_url']?.toString()
                            : widget.identityCache!
                                .resolveIdentity(
                                    userId: user['user_id'].toString(),
                                    avatarUrl: user['avatar_url']?.toString())
                                .avatarUrl,
                        diagnosticSource: 'add-friend-search',
                      ),
                      title: Text(_displayName(user)),
                      subtitle: Text('畅聊号：${user['username']}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _friendLabel(
                                user['relationship_state']?.toString()),
                            key: Key('add-friend-state-${user['user_id']}'),
                            style: const TextStyle(
                                fontSize: 13,
                                color: WeChatColors.textSecondary),
                          ),
                          const SizedBox(width: 4),
                          const CupertinoListTileChevron(),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ]),
        ),
      );
}

String _friendLabel(String? state) => switch (state) {
      'OUTGOING_PENDING' => '申请已发送',
      'FRIEND' => '已添加',
      'REUSABLE' => '重新申请',
      _ => '添加',
    };

final class FriendRequestsPage extends StatefulWidget {
  const FriendRequestsPage({
    super.key,
    required this.api,
    this.pendingRequests,
    this.directChats,
    this.onRequestsChanged,
    this.identityCache,
    this.onEstablishDirectChat,
    this.onEstablishDirectChatWithRequest,
  });
  final BusinessApiClient api;
  final ValueNotifier<int>? pendingRequests;

  /// 接受申请成功后用于立即创建双方 DM 会话（消息页即时出现入口）。
  final DirectChatController? directChats;

  /// 申请状态变化后回调（通讯录/消息页即时刷新）。
  final VoidCallback? onRequestsChanged;

  /// BUG 3：accept 成功后乐观插入好友（本地立即可见，禁止等待重启）。
  final ProfileRepository? identityCache;

  /// **测试专用**的旧私聊建立钩子（无「接受招呼 + 打开会话」编排）。
  ///
  /// 生产路径只走 [onEstablishDirectChatWithRequest]（组合根注入
  /// `AppHome._establishDirectChatAndGreet`）；该回退仅用于单元测试注入，
  /// 由架构守卫测试锁定"生产组合必须传 request 版本"。
  @visibleForTesting
  final Future<void> Function(
          String matrixUserId, String friendUserId, String friendDisplayName)?
      onEstablishDirectChat;

  /// 生产路径：接受好友后的完整编排（建私聊 + 发送接受系统消息 + 打开会话）。
  final Future<void> Function(String matrixUserId, String friendUserId,
      String friendDisplayName, Map request)? onEstablishDirectChatWithRequest;

  @override
  State<FriendRequestsPage> createState() => _FriendRequestsPageState();
}

final class _FriendRequestsPageState extends State<FriendRequestsPage> {
  /// 本地优先：进入即用上次成功的列表（首帧就有内容），随后后台刷新。
  FriendRequestSnapshot? _snapshot;
  Map<String, dynamic>? _payload;
  Object? _error;
  bool _loading = false;
  int _generation = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _snapshot = FriendRequestSnapshotStores.shared?.read();
    _payload = _snapshot?.payload;
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }

  void _reload() => unawaited(_load());

  Future<void> _load() async {
    final generation = ++_generation;
    if (mounted) setState(() => _loading = true);
    String? scope;
    try {
      final userId = await widget.api.currentMatrixUserId();
      scope = userId == null || userId.isEmpty ? null : 'matrix:$userId';
    } catch (_) {
      scope = null;
    }
    if (_disposed || generation != _generation) return;
    final cached = _snapshot;
    if (scope != null && cached != null && cached.scope != scope) {
      // 账号切换保护：绝不展示上一个账号的申请列表。
      setState(() {
        _snapshot = null;
        _payload = null;
      });
      unawaited(FriendRequestSnapshotStores.shared?.clear());
    }
    try {
      final body = await widget.api.friendRequests();
      if (_disposed || generation != _generation) return;
      if (mounted) {
        setState(() {
          _payload = body;
          _error = null;
          _loading = false;
        });
      }
      if (scope != null) {
        final snapshot = FriendRequestSnapshot(
            scope: scope, payload: body, savedAt: DateTime.now());
        _snapshot = snapshot;
        final store = FriendRequestSnapshotStores.shared;
        if (store != null) {
          try {
            await store.write(snapshot);
          } catch (_) {
            // 本地快照写失败不是刷新失败。
          }
        }
      }
    } catch (error) {
      if (_disposed || generation != _generation) return;
      if (mounted) {
        setState(() {
          _error = error;
          _loading = false;
        });
      }
    }
  }

  /// BUG 2：点击申请进入"通过朋友验证"页；accept/reject 只在该页触发。
  Future<void> _openReview(Map request) async {
    await Navigator.push(
      context,
      MotionPageRoute(
        builder: (_) => FriendRequestReviewPage(
          request: request,
          onAccept: () => _resolve(request, true),
          onReject: () => _resolve(request, false),
          onOpenAccepted: () => _openAcceptedRequest(request),
        ),
      ),
    );
    if (mounted) _reload();
  }

  /// BUG 3：accept 编排（对应领域事件 friend.accepted）。
  /// 仅当用户在"通过朋友验证"页点击通过验证时才调用 accept API；
  /// 成功后：乐观插入本地好友 → 建立/取得加密私聊 → 发送好友接受
  /// 系统消息 → 会话列表刷新。任何后续步骤失败都不回滚好友关系，
  /// 禁止要求用户退出 APP 才能看到好友。
  bool _resolving = false;

  Future<void> _openAcceptedRequest(Map request) async {
    if (_resolving || request['status'] != 'ACCEPTED') return;
    _resolving = true;
    try {
      // Historical acceptance is not current friendship authority. A removed
      // friend must not be reinserted merely by reopening an old request.
      final body = await widget.api.friends();
      final current = ((body['items'] as List?) ?? const []).whereType<Map>();
      if (!current.any((friend) =>
          friend['user_id'] == request['user_id'] &&
          friend['matrix_user_id'] == request['matrix_user_id'])) {
        throw StateError('当前好友关系不可用');
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      await _initializeAcceptedRequest(request);
    } catch (_) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: const Text('暂时无法打开聊天'),
          content: const Text('请检查网络及当前好友关系后重试。'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('好的'),
            )
          ],
        ),
      );
    } finally {
      _resolving = false;
    }
  }

  Future<void> _resolve(Map request, bool accept) async {
    if (_resolving) return;
    _resolving = true;
    try {
      final id = request['id'].toString();
      if (accept) {
        await widget.api.acceptFriendRequest(id);
      } else {
        await widget.api.rejectFriendRequest(id);
      }
      if (!mounted) return;
      // 先退出验证页，接下来的加密私聊导航成为当前页面。
      Navigator.of(context).pop();
      final pending = widget.pendingRequests;
      if (pending != null && pending.value > 0) pending.value -= 1;
      if (accept) {
        await _initializeAcceptedRequest({...request, 'status': 'ACCEPTED'});
      }
      widget.onRequestsChanged?.call();
      if (mounted) _reload();
    } catch (_) {
      if (!mounted) return;
      await showCupertinoDialog<void>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
                title: const Text('操作未完成'),
                content: const Text('请检查网络后重试'),
                actions: [
                  CupertinoDialogAction(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('好的'))
                ],
              ));
    } finally {
      _resolving = false;
    }
  }

  Future<void> _initializeAcceptedRequest(Map request) async {
    while (mounted) {
      try {
        await _onFriendAccepted(request);
        return;
      } catch (_) {
        if (!mounted) return;
        final retry = await showCupertinoDialog<bool>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: const Text('已添加好友'),
            content: const Text('聊天和好友申请说明尚未准备好，请重试。好友关系已保存。'),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('稍后'),
              ),
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('重试'),
              ),
            ],
          ),
        );
        if (retry != true) return;
      }
    }
  }

  Future<void> _onFriendAccepted(Map request) async {
    final cache = widget.identityCache;
    if (cache == null) return;
    // BUG 3 编排：乐观插入 + 私聊建立 + 好友接受系统消息。
    final coordinator = FriendAcceptanceCoordinator(
      identityCache: cache,
      establishDirectChatWithRequest: widget.onEstablishDirectChatWithRequest,
      establishDirectChat: widget.onEstablishDirectChat ??
          (matrixUserId, friendUserId, friendDisplayName) async {
            final directChats = widget.directChats;
            if (directChats != null) {
              await directChats.open(matrixUserId);
            }
          },
    );
    await coordinator.onAccepted(request);
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        backgroundColor: WeChatColors.pageBackground(context),
        navigationBar: CupertinoNavigationBar(
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text('新的朋友')),
        child: SafeArea(
          child: Builder(builder: (context) {
            final items = ((_payload?['items'] as List?) ?? const [])
                .where(
                    (item) => item is Map && item['direction'] != 'OUTGOING')
                .toList();
            return ListView(
              children: [
                for (final request in items)
                  _FriendRequestTile(
                    request: request as Map,
                    onTap: () => _openReview(request),
                  ),
                // 三种"没有行"的情形必须区分：加载中 / 加载失败 / 真的没有。
                // 旧实现把前两种都渲染成「暂无新的朋友」，断网时会把上一份真实
                // 列表丢掉并谎报"没有新朋友"。
                if (items.isEmpty && _loading)
                  const Padding(
                    padding: EdgeInsets.only(top: WeChatSpacing.xxl),
                    child: Center(child: CupertinoActivityIndicator()),
                  ),
                if (items.isEmpty && !_loading && _error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: WeChatSpacing.xxl),
                    child: Column(children: [
                      const Text('新的朋友加载失败',
                          style: TextStyle(
                              fontSize: 14, color: WeChatColors.textSecondary)),
                      const SizedBox(height: 8),
                      CupertinoButton(
                        key: const Key('friend-requests-retry'),
                        onPressed: _reload,
                        child: const Text('重试'),
                      ),
                    ]),
                  ),
                if (items.isEmpty && !_loading && _error == null)
                  const Padding(
                    padding: EdgeInsets.only(top: WeChatSpacing.xxl),
                    child: Center(child: Text('暂无新的朋友')),
                  ),
              ],
            );
          }),
        ),
      );
}

final class _FriendRequestTile extends StatelessWidget {
  const _FriendRequestTile({required this.request, required this.onTap});
  final Map request;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // BUG 2 状态机：PENDING/ACCEPTED/REJECTED/EXPIRED/CANCELLED。
    final status = request['status']?.toString() ?? 'PENDING';
    final label = switch (status) {
      'PENDING' => '接受',
      'ACCEPTED' => '已添加',
      'REJECTED' => '已拒绝',
      'EXPIRED' => '已过期',
      'CANCELLED' => '已撤销',
      _ => '已处理'
    };
    return SizedBox(
      height: _friendRequestTileHeight,
      // 昵称与打招呼内容作为一个整体与头像垂直居中对齐：昵称不再贴行顶、
      // 打招呼内容不再贴行底（此前 CupertinoListTile 的 spaceBetween 把它们
      // 分别顶到上下两边）。头像保持 40dp 设计尺寸。
      child: WeChatListTile(
        onTap: onTap,
        showDivider: true,
        leadingSize: WeChatDimensions.contactAvatar,
        leadingToTitle: WeChatSpacing.md,
        leading: UserAvatar(
            nickname: request['nickname']?.toString() ??
                request['username']?.toString() ??
                '',
            fallbackSeed: request['username']?.toString() ?? '',
            avatarUrl: request['avatar_url']?.toString()),
        title: Text(request['nickname']?.toString() ??
            request['username']?.toString() ??
            ''),
        subtitle: Text(request['message']?.toString().isNotEmpty == true
            ? request['message'].toString()
            : '请求添加你为好友'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              key: Key('friend-request-state-${request['id']}'),
              style: TextStyle(
                fontSize: 13,
                color: status == 'PENDING'
                    ? WeChatColors.brandPrimary
                    : WeChatColors.textSecondary,
              ),
            ),
            const SizedBox(width: 4),
            const CupertinoListTileChevron(),
          ],
        ),
      ),
    );
  }
}

/// 「新的朋友」请求行高度：两行文案 + 头像的舒适行高（与演示稿
/// `frontend/src/screens/contacts.js` 的请求行一致）。
const _friendRequestTileHeight = 68.0;
