import 'package:flutter/cupertino.dart';

import '../../ui/components/user_avatar.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../contacts/contact_models.dart';
import 'red_packet_controller.dart';

final class RedPacketClaimRecord {
  const RedPacketClaimRecord({
    required this.userId,
    required this.amount,
    this.claimedAt,
    this.nickname,
    this.username,
    this.avatarUrl,
  });

  final String userId;
  final String amount;
  final DateTime? claimedAt;

  /// 服务端补充的公开资料（昵称/畅聊号/自定义头像）。
  final String? nickname;
  final String? username;
  final String? avatarUrl;

  BigInt get amountCents {
    final parts = amount.split('.');
    final whole = BigInt.tryParse(parts.first) ?? BigInt.zero;
    final cents = parts.length > 1 ? '${parts[1]}00'.substring(0, 2) : '00';
    return whole * BigInt.from(100) + (BigInt.tryParse(cents) ?? BigInt.zero);
  }
}

/// Parses the business detail payload into ordered claim records
/// (ascending claim time, matching WeChat's 领取详情 ordering).
List<RedPacketClaimRecord> parseRedPacketClaims(Map<String, dynamic>? detail) {
  final raw = detail?['claims'];
  if (raw is! List) return const [];
  final records = [
    for (final entry in raw)
      if (entry is Map)
        RedPacketClaimRecord(
          userId: entry['user_id']?.toString() ?? '',
          amount: entry['amount']?.toString() ?? '0',
          claimedAt: DateTime.tryParse(entry['claimed_at']?.toString() ?? ''),
          nickname: entry['nickname']?.toString(),
          username: entry['username']?.toString(),
          avatarUrl: entry['avatar_url']?.toString(),
        ),
  ];
  records.sort((a, b) {
    final aTime = a.claimedAt;
    final bTime = b.claimedAt;
    if (aTime == null && bTime == null) return 0;
    if (aTime == null) return 1;
    if (bTime == null) return -1;
    return aTime.compareTo(bTime);
  });
  return records;
}

/// 展示名优先级：**备注**（查看者自己的联系人备注，仅本人可见）→
/// 昵称 → 用户名（畅聊号）→ 好友。
String redPacketDisplayName({
  String? remarkName,
  String? nickname,
  String? username,
}) {
  for (final value in [remarkName, nickname, username]) {
    if (value != null && value.trim().isNotEmpty) return value.trim();
  }
  return '好友';
}

/// Index of the 手气最佳 record: the earliest claim with the highest amount.
int? bestLuckRecordIndex(List<RedPacketClaimRecord> records,
    {Map<String, dynamic>? detail}) {
  if (detail != null) {
    final status = detail['status'];
    final serverTime = DateTime.tryParse('${detail['server_time']}');
    final expiresAt = DateTime.tryParse('${detail['expires_at']}');
    final terminal = status == 'COMPLETED' || status == 'EXPIRED';
    final expired = serverTime != null &&
        expiresAt != null &&
        !expiresAt.isAfter(serverTime);
    // 手气最佳展示门槛（与微信一致）：
    // 1. 群聊 + 拼手气（RANDOM）+ 服务端 best_luck_eligible；
    // 2. 已领取完毕（COMPLETED）或已过期——进行中一律不展示；
    // 3. 份数 ≥ 2：单份红包即使领完也没有“手气”可比。
    final shares = int.tryParse('${detail['share_count']}') ?? 0;
    if (!(detail['room_id'] != null &&
        detail['mode'] == 'RANDOM' &&
        detail['best_luck_eligible'] == true &&
        status != 'CANCELLED' &&
        shares >= 2 &&
        (terminal || expired))) {
      return null;
    }
  }
  if (records.isEmpty) return null;
  var best = 0;
  for (var i = 1; i < records.length; i++) {
    if (records[i].amountCents > records[best].amountCents) best = i;
  }
  return best;
}

final class RedPacketClaimDetailPage extends StatefulWidget {
  const RedPacketClaimDetailPage({
    super.key,
    required this.api,
    required this.packetId,
  });

  final RedPacketViewGateway api;
  final String packetId;

  @override
  State<RedPacketClaimDetailPage> createState() =>
      _RedPacketClaimDetailPageState();
}

final class _RedPacketClaimDetailPageState
    extends State<RedPacketClaimDetailPage> {
  late final RedPacketController controller = RedPacketController(widget.api)
    ..addListener(_changed);
  List<ContactSummary> contacts = const [];
  bool contactsLoaded = false;

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    controller.load(widget.packetId);
    _loadContacts();
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    try {
      final loaded = await widget.api.listContacts();
      if (mounted && controller.isAlive) {
        setState(() {
          contacts = loaded;
          contactsLoaded = true;
        });
      }
    } catch (_) {
      if (mounted && controller.isAlive) {
        setState(() => contactsLoaded = true);
      }
    }
  }

  ContactSummary? _contactOf(String? userId) {
    for (final contact in contacts) {
      if (contact.userId == userId) return contact;
    }
    return null;
  }

  /// 展示名：备注（仅查看者本人可见）→ 昵称 → 用户名 → 好友。
  String _nameOf(RedPacketClaimRecord record) {
    final contact = _contactOf(record.userId);
    return redPacketDisplayName(
      remarkName: contact?.displayName,
      nickname: record.nickname,
      username: record.username,
    );
  }

  @override
  Widget build(BuildContext context) {
    final detail = controller.detail;
    final records = parseRedPacketClaims(detail);
    final bestIndex = bestLuckRecordIndex(records, detail: detail);
    final senderId = detail?['sender_id']?.toString();
    final senderContact = _contactOf(senderId);
    final senderName = redPacketDisplayName(
      remarkName: senderContact?.displayName,
      nickname: detail?['sender_nickname']?.toString(),
      username: detail?['sender_username']?.toString(),
    );
    final senderAvatarUrl =
        detail?['sender_avatar_url']?.toString().isNotEmpty == true
            ? detail!['sender_avatar_url'].toString()
            : senderContact?.avatarUrl;
    final status = effectiveRedPacketStatus(detail);
    return WeChatPageScaffold.navigation(
      navigationBar: const CupertinoNavigationBar(
        middle: Text('领取详情'),
      ),
      child: controller.loading && detail == null
          ? const Center(child: CupertinoActivityIndicator())
          : (controller.ended || (controller.error != null && detail == null))
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      controller.ended ? '会话已结束' : '红包详情加载失败，请稍后重试',
                      style: TextStyle(
                        color: WeChatColors.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                    if (!controller.ended) ...[
                      const SizedBox(height: 12),
                      CupertinoButton(
                        key: const Key('red-packet-claim-detail-retry'),
                        onPressed: () => controller.load(widget.packetId),
                        child: const Text('重试'),
                      ),
                    ],
                  ]),
                )
              : SafeArea(
                  top: false,
                  child: ListView(
                    key: const Key('red-packet-claim-detail-page'),
                    padding: EdgeInsets.zero,
                    children: [
                      _headerCard(detail, senderName, senderAvatarUrl, status),
                      Padding(
                        // 白色列表压在 hero 底弧上（demo：-18px 圆角衔接）。
                        padding:
                            const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: Transform.translate(
                          offset: const Offset(0, -18),
                          child: _recordsCard(records, bestIndex),
                        ),
                      ),
                      if (detail != null) ...[
                        const SizedBox(height: 16),
                        Center(
                          child: Text(
                            '发出时间 ${_formatIssueTime(detail)}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: WeChatColors.textTertiary,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
    );
  }

  /// 微信式橙色 hero（demo 一比一）：渐变底 + 底部 28px 圆角；
  /// 白色列表以 -18px 负边距压在 hero 圆弧上（见 build 的 Stack）。
  Widget _headerCard(
    Map<String, dynamic>? detail,
    String senderName,
    String? senderAvatarUrl,
    String? status,
  ) =>
      Container(
        key: const Key('red-packet-claim-detail-hero'),
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(24, 40, 24, 42),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment(-0.4, -1),
            end: Alignment(0.4, 1),
            colors: [
              Color(0xFFFA9D3B),
              Color(0xFFFA5151),
              Color(0xFFE8413F),
            ],
            stops: [-0.1, 0.55, 1],
          ),
          borderRadius: BorderRadius.only(
            bottomLeft: Radius.circular(28),
            bottomRight: Radius.circular(28),
          ),
        ),
        child: Column(children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFFFDD89F),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: const Icon(CupertinoIcons.gift_fill,
                color: Color(0xFFD2691E), size: 34),
          ),
          const SizedBox(height: 10),
          Text(
            '$senderName的红包',
            style: const TextStyle(
              fontSize: 15,
              color: Color(0xFFFFE7C2),
            ),
          ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(children: [
              TextSpan(
                text: detail == null ? '' : '${detail['total']}',
                style: const TextStyle(
                  fontSize: 44,
                  fontWeight: FontWeight.w700,
                  color: CupertinoColors.white,
                  height: 1.1,
                ),
              ),
              const TextSpan(
                text: ' 点钻',
                style: TextStyle(
                  fontSize: 15,
                  color: CupertinoColors.white,
                ),
              ),
            ]),
            key: const Key('red-packet-claim-detail-total'),
          ),
          const SizedBox(height: 8),
          Text(
            detail == null
                ? ''
                : status == 'OPEN'
                    ? '已领取 ${detail['claimed_count']}/${detail['share_count']} 个'
                    : '${redPacketStatusText(status)} ·'
                        ' 已领取 ${detail['claimed_count']}/${detail['share_count']} 个',
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFFFFE7C2),
            ),
          ),
        ]),
      );

  /// 列表头：N人已领 · 共 已领/总额（demo 一比一）。
  Widget _recordsHeader() {
    final detail = controller.detail;
    if (detail == null) return const SizedBox.shrink();
    final total = detail['total']?.toString() ?? '0';
    final claimedCount = detail['claimed_count']?.toString() ?? '0';
    var claimedTotal = 0.0;
    for (final record in parseRedPacketClaims(detail)) {
      claimedTotal += double.tryParse(record.amount) ?? 0;
    }
    final claimedText = claimedTotal.toStringAsFixed(2);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('$claimedCount人已领',
              style: const TextStyle(
                  fontSize: 13, color: WeChatColors.textSecondary)),
          if (controller.detail?['total'] != null)
            Text('共 $claimedText/$total 点钻',
                style: const TextStyle(
                    fontSize: 13, color: WeChatColors.textSecondary)),
        ],
      ),
    );
  }

  Widget _recordsCard(List<RedPacketClaimRecord> records, int? bestIndex) {
    if (contactsLoaded && records.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 28),
        decoration: BoxDecoration(
          color: WeChatColors.elevatedSurface(context),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(
          child: Text(
            '暂无领取记录',
            style: TextStyle(fontSize: 13, color: WeChatColors.textSecondary),
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: WeChatColors.elevatedSurface(context),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(12),
          bottom: Radius.circular(8),
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0x0F000000),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        key: const Key('red-packet-claim-records'),
        children: [
          _recordsHeader(),
          for (var i = 0; i < records.length; i++) ...[
            if (i > 0)
              Container(
                height: .5,
                margin: const EdgeInsets.only(left: 62),
                color: WeChatColors.resolve(context, WeChatColors.divider),
              ),
            _recordRow(records[i], isBest: i == bestIndex),
          ],
        ],
      ),
    );
  }

  String _formatIssueTime(Map<String, dynamic> detail) {
    final expiresOrCreated = detail['expires_at']?.toString();
    final parsed = expiresOrCreated == null
        ? null
        : DateTime.tryParse(expiresOrCreated)?.add(const Duration(hours: 24));
    final time = parsed ?? DateTime.now();
    final local = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String _formatClaimTime(DateTime time) {
    final local = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  Widget _recordRow(RedPacketClaimRecord record, {required bool isBest}) {
    final name = _nameOf(record);
    final contact = _contactOf(record.userId);
    final avatarUrl = record.avatarUrl?.isNotEmpty == true
        ? record.avatarUrl
        : contact?.avatarUrl;
    return Container(
      key: Key('red-packet-claim-record-${record.userId}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        UserAvatar(
          nickname: name,
          fallbackSeed: record.userId,
          avatarUrl: avatarUrl,
          diagnosticSource: 'red-packet-claim-detail-record',
          size: 36,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  color: WeChatColors.resolveTextPrimary(context),
                ),
              ),
              if (record.claimedAt != null) ...[
                const SizedBox(height: 2),
                Text(
                  _formatClaimTime(record.claimedAt!),
                  style: const TextStyle(
                    fontSize: 11,
                    color: WeChatColors.textTertiary,
                  ),
                ),
              ],
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${record.amount}点钻',
              style: TextStyle(
                fontSize: 15,
                color: WeChatColors.resolveTextPrimary(context),
              ),
            ),
            if (isBest) ...[
              const SizedBox(height: 4),
              Container(
                key: const Key('luck-best-badge'),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: WeChatColors.redPacketGradientTop),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '手气最佳',
                  style: TextStyle(
                    fontSize: 10,
                    color: WeChatColors.redPacketGradientTop,
                  ),
                ),
              ),
            ],
          ],
        ),
      ]),
    );
  }
}
