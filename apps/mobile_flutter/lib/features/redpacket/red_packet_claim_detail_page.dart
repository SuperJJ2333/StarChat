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

  double get amountValue => double.tryParse(amount) ?? 0;
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
int? bestLuckRecordIndex(List<RedPacketClaimRecord> records) {
  if (records.isEmpty) return null;
  var best = 0;
  for (var i = 1; i < records.length; i++) {
    if (records[i].amountValue > records[best].amountValue) best = i;
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
      if (mounted) {
        setState(() {
          contacts = loaded;
          contactsLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) {
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
    final bestIndex = bestLuckRecordIndex(records);
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
    final status = detail?['status']?.toString();
    return WeChatPageScaffold.navigation(
      navigationBar: const CupertinoNavigationBar(
        middle: Text('领取详情'),
      ),
      child: controller.loading && detail == null
          ? const Center(child: CupertinoActivityIndicator())
          : controller.error != null && detail == null
              ? Center(
                  child: Text(
                    '红包详情加载失败，请稍后重试',
                    style: TextStyle(
                      color: WeChatColors.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                )
              : SafeArea(
                  child: ListView(
                    key: const Key('red-packet-claim-detail-page'),
                    padding: const EdgeInsets.all(12),
                    children: [
                      _headerCard(detail, senderName, senderAvatarUrl, status),
                      const SizedBox(height: 12),
                      _recordsCard(records, bestIndex),
                    ],
                  ),
                ),
  );
  }

  Widget _headerCard(
    Map<String, dynamic>? detail,
    String senderName,
    String? senderAvatarUrl,
    String? status,
  ) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        decoration: BoxDecoration(
          color: WeChatColors.elevatedSurface(context),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(children: [
          UserAvatar(
            nickname: senderName,
            fallbackSeed: detail?['sender_id']?.toString() ?? widget.packetId,
            avatarUrl: senderAvatarUrl,
            diagnosticSource: 'red-packet-claim-detail-sender',
            size: 48,
          ),
          const SizedBox(height: 10),
          Text(
            '$senderName的红包',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: WeChatColors.resolveTextPrimary(context),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            detail == null
                ? ''
                : '共 ${detail['total']} 点钻，'
                    '已领取 ${detail['claimed_count']}/${detail['share_count']} 个',
            key: const Key('red-packet-claim-detail-total'),
            style: const TextStyle(
              fontSize: 13,
              color: WeChatColors.textSecondary,
            ),
          ),
          if (detail != null && status != null && status != 'OPEN') ...[
            const SizedBox(height: 4),
            Text(
              redPacketStatusText(status),
              style: const TextStyle(
                fontSize: 13,
                color: WeChatColors.textSecondary,
              ),
            ),
          ],
        ]),
      );

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
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        key: const Key('red-packet-claim-records'),
        children: [
          for (var i = 0; i < records.length; i++) ...[
            if (i > 0)
              Container(
                height: .5,
                margin: const EdgeInsets.only(left: 62),
                color: WeChatColors.divider,
              ),
            _recordRow(records[i], isBest: i == bestIndex),
          ],
        ],
      ),
    );
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
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              color: WeChatColors.resolveTextPrimary(context),
            ),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
