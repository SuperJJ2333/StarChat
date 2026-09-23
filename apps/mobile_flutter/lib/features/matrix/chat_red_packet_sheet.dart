import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../../core/amount_rules.dart';
import '../../core/business_api_client.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../contacts/contact_models.dart';
import 'chat_payment_flow.dart';
import 'chat_red_packet_controller.dart';
import 'group_member_picker.dart';
import 'matrix_e2ee_client.dart' show MatrixRoomMemberSnapshot;
import 'matrix_user_avatar.dart';

abstract interface class ChatRedPacketSupport {
  Future<double> balance();
  Future<RedPacketLimits> limits();
}

final class RedPacketLimits {
  const RedPacketLimits({required this.maxTotal});
  final double maxTotal;
}

final class BusinessChatRedPacketSupport implements ChatRedPacketSupport {
  const BusinessChatRedPacketSupport(this.api);
  final BusinessApiClient api;
  @override
  Future<double> balance() async {
    final body = await api.caibiBalance();
    return double.tryParse(body['balance']?.toString() ?? '') ?? 0;
  }

  @override
  Future<RedPacketLimits> limits() async {
    final body = await api.redPacketLimits();
    final maximum = double.tryParse(body['max_total']?.toString() ?? '');
    if (maximum == null || !maximum.isFinite || maximum <= 0) {
      throw const FormatException('Invalid red packet runtime limit');
    }
    return RedPacketLimits(maxTotal: maximum);
  }
}

final class ChatRoomMember {
  const ChatRoomMember(this.id, this.name,
      {this.avatarUrl, this.businessAvatarUrl, this.businessUserId});
  final String id;
  final String name;

  /// Matrix 房间成员头像（mxc://，非好友时回退）。
  final String? avatarUrl;

  /// 业务头像（好友资料，http(s)，走统一缓存）。
  final String? businessAvatarUrl;
  final String? businessUserId;
}

/// 把当前房间的已加入成员投影成可选择成员。
///
/// 只包含本会话成员（排除自己，绝不含通讯录好友）。好友身份同时保留
/// Matrix 头像（mxc，供房间头像解析）与业务头像/业务账号（供确认收款账号），
/// 显示名优先使用好友备注，其次 Matrix 显示名。
List<ChatRoomMember> chatRoomMembersFor({
  required Iterable<MatrixRoomMemberSnapshot> members,
  required String? currentUserId,
  required Map<String, ContactDetails> contactsByMatrixId,
}) {
  final result = <ChatRoomMember>[];
  for (final member in members) {
    if (!member.isJoined) continue;
    if (currentUserId != null && member.id == currentUserId) continue;
    final contact = contactsByMatrixId[member.id];
    final remark = contact?.remark?.trim();
    result.add(ChatRoomMember(
      member.id,
      (remark == null || remark.isEmpty)
          ? (contact?.displayName ?? member.displayName)
          : remark,
      avatarUrl: member.avatarUri?.toString(),
      businessAvatarUrl: contact?.avatarUrl,
      businessUserId: contact?.userId,
    ));
  }
  return result;
}

String redPacketTypeLabel(String mode) => switch (mode) {
      'EQUAL' => '普通红包',
      'EXCLUSIVE' => '专属红包',
      _ => '拼手气红包',
    };

final class ChatRedPacketSheet extends StatefulWidget {
  const ChatRedPacketSheet({
    super.key,
    required this.controller,
    required this.isGroup,
    required this.onSent,
    this.support,
    this.members = const <ChatRoomMember>[],
    this.resolveBusinessUser,
    this.avatarMedia,
  });
  final ChatRedPacketController controller;
  final bool isGroup;
  final VoidCallback onSent;
  final ChatRedPacketSupport? support;
  final List<ChatRoomMember> members;
  final Future<Map<String, dynamic>> Function(String matrixUserId)?
      resolveBusinessUser;
  final AvatarMediaCapability? avatarMedia;
  @override
  State<ChatRedPacketSheet> createState() => _State();
}

final class _State extends State<ChatRedPacketSheet>
    with WidgetsBindingObserver {
  final total = TextEditingController();
  final shares = TextEditingController(); // 规格要求：默认空，避免忘记设置
  final greeting = TextEditingController(text: '恭喜发财，大吉大利');
  String mode = 'RANDOM';
  String? recipientId;
  String? recipientName;
  String? recipientMatrixUserId;
  double? balance;
  // Only the business configuration supplies a cap; missing data is unknown.
  double? maxTotal;
  bool loadingLimits = false;
  Future<void>? _limitLoad;
  bool _submitting = false;
  bool resolvingRecipient = false;
  int _resolutionGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_change);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadBalance());
    unawaited(_loadLimits());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_change);
    total.dispose();
    shares.dispose();
    greeting.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_loadLimits());
  }

  void _change() {
    if (mounted) setState(() {});
  }

  Future<void> _loadBalance() async {
    final support = widget.support;
    if (support == null) return;
    try {
      final loaded = await support.balance();
      if (mounted) setState(() => balance = loaded);
    } catch (_) {
      // Balance is a hint only; the server remains authoritative.
    }
  }

  Future<void> _loadLimits() {
    return _limitLoad ??= _fetchLimits().whenComplete(() => _limitLoad = null);
  }

  Future<void> _fetchLimits() async {
    final support = widget.support;
    if (support == null || !mounted) return;
    setState(() => loadingLimits = true);
    try {
      final limits = await support.limits();
      if (mounted) setState(() => maxTotal = limits.maxTotal);
    } catch (_) {
      if (mounted) setState(() => maxTotal = null);
    } finally {
      if (mounted) setState(() => loadingLimits = false);
    }
  }

  /// ADR-0073：手续费规则与转账**同一实现**（[chatPaymentFeeOrNull]，BigInt
  /// 无浮点），这里只做展示与提交前校验；服务端仍是权威。
  static double? _fee(String raw) {
    final text = chatPaymentFeeOrNull(raw);
    return text == null ? null : double.tryParse(text);
  }

  Future<void> _send() async {
    if (resolvingRecipient || _submitting) return;
    setState(() => _submitting = true);
    try {
      // Refresh before a cached cap can reject a newly permitted amount.
      // Concurrent resume/retry loads share the same bounded API request.
      await _loadLimits();
      if (!mounted) return;
      await _submit();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submit() async {
    final amountError = AmountRules.validate(total.text.trim());
    if (amountError != null) {
      await _alert(amountError);
      return;
    }
    final amount = double.parse(total.text.trim());
    final maximum = maxTotal;
    if (maximum != null && amount > maximum) {
      await _alert('单个红包金额不能超过 ${maximum.toStringAsFixed(2)} 点钻');
      return;
    }
    var shareCount = 1; // 私聊固定 1 个；群聊取输入框（空=未设置）
    if (widget.isGroup && mode != 'EXCLUSIVE') {
      shareCount = int.tryParse(shares.text.trim()) ?? 0;
      if (shareCount < 1 || shareCount > 500) {
        await _alert('红包个数需在 1-500 之间');
        return;
      }
      if (amount < shareCount * 0.01) {
        await _alert('单个红包最少 0.01 点钻');
        return;
      }
    }
    if (mode == 'EXCLUSIVE' && recipientId == null) {
      await _alert('请选择专属红包接收人');
      return;
    }
    // ADR-0073：发起方承担 0.5% 手续费（最低 0.01 点钻），与转账同一实现；
    // 这里只作提交前提示，服务端仍是权威。
    final fee = _fee(total.text.trim());
    if (fee == null) {
      await _alert('请输入有效的红包金额');
      return;
    }
    if (!widget.isGroup && balance != null && amount + fee > balance!) {
      await _alert(
          '红包创建失败，账户余额不足（含 0.5% 手续费 ${fee.toStringAsFixed(2)} 点钻，需合计 ${(amount + fee).toStringAsFixed(2)} 点钻）',
          key: const Key('chat-red-packet-insufficient-dialog'));
      return;
    }
    await widget.controller.submit(
      total: total.text.trim(),
      greeting: greeting.text.trim().isEmpty ? '恭喜发财' : greeting.text.trim(),
      mode: widget.isGroup ? mode : 'EQUAL',
      shareCount: mode == 'EXCLUSIVE' ? 1 : shareCount,
      exclusiveRecipientId: mode == 'EXCLUSIVE' ? recipientId : null,
      exclusiveRecipientMatrixId:
          mode == 'EXCLUSIVE' ? recipientMatrixUserId : null,
    );
    if (!mounted) return;
    final state = widget.controller.state;
    if (state.status == ChatRedPacketStatus.sent) {
      widget.onSent();
      return;
    }
    if (state.status == ChatRedPacketStatus.failed && state.message != null) {
      await _alert(state.message!,
          key: const Key('chat-red-packet-error-dialog'));
    }
  }

  Future<void> _alert(String message, {Key? key}) => showCupertinoDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => CupertinoAlertDialog(
          key: key,
          title: const Text('提示'),
          content: Text(message),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      );

  Future<void> _pickType() async {
    final selected = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: const Text('选择红包类型'),
        actions: [
          for (final (value, label) in const [
            ('RANDOM', '拼手气红包'),
            ('EQUAL', '普通红包'),
            ('EXCLUSIVE', '专属红包'),
          ])
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(sheetContext, value),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (mode == value) ...[
                    const Icon(CupertinoIcons.check_mark, size: 16),
                    const SizedBox(width: 6),
                  ],
                  Text(label),
                ],
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheetContext),
          child: const Text('取消'),
        ),
      ),
    );
    if (selected != null && selected != mode) setState(() => mode = selected);
  }

  Future<void> _pickRecipient() async {
    if (resolvingRecipient) return;
    if (widget.members.isEmpty) {
      await _alert('群成员尚未加载，请稍后再试');
      return;
    }
    final selected = await GroupMemberPicker.show(
      context,
      title: '选择指定成员',
      avatarMedia: widget.avatarMedia,
      itemKeyPrefix: 'chat-red-packet-member',
      selectedMatrixUserId: recipientMatrixUserId,
      members: [
        for (final member in widget.members)
          GroupMemberIdentity(
            matrixUserId: member.id,
            displayName: member.name,
            matrixAvatarUri: member.avatarUrl == null
                ? null
                : Uri.tryParse(member.avatarUrl!),
            businessUserId: member.businessUserId ??
                (member.id.startsWith('@') ? null : member.id),
            businessAvatarUrl: member.businessAvatarUrl,
          )
      ],
    );
    if (!mounted) return;
    if (selected != null) {
      final generation = ++_resolutionGeneration;
      setState(() => resolvingRecipient = true);
      final resolved = await _resolveMember(selected, generation);
      if (!mounted || generation != _resolutionGeneration) return;
      setState(() => resolvingRecipient = false);
      if (resolved == null || !mounted) return;
      setState(() {
        recipientId = resolved.businessUserId;
        recipientMatrixUserId = resolved.matrixUserId;
        recipientName = resolved.displayName;
      });
    }
  }

  Future<GroupMemberIdentity?> _resolveMember(
      GroupMemberIdentity member, int generation) async {
    if (member.businessUserId != null && member.businessUserId!.isNotEmpty) {
      return member;
    }
    final lookup = widget.resolveBusinessUser;
    if (lookup == null) {
      await _showResolutionUnavailable();
      return null;
    }
    try {
      final profile = await lookup(member.matrixUserId);
      if (!mounted || generation != _resolutionGeneration) return null;
      final userId = profile['user_id']?.toString();
      if (profile['matrix_user_id']?.toString() != member.matrixUserId ||
          userId == null ||
          userId.isEmpty) {
        throw StateError('member identity mismatch');
      }
      return member.withBusinessIdentity(
          userId: userId, avatarUrl: profile['avatar_url']?.toString());
    } catch (_) {
      final retry = mounted &&
          generation == _resolutionGeneration &&
          await _offerResolutionRetry();
      if (retry && mounted && generation == _resolutionGeneration) {
        return _resolveMember(member, generation);
      }
      return null;
    }
  }

  Future<void> _showResolutionUnavailable() => showCupertinoDialog<void>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
              title: const Text('无法确认红包账号'),
              content: const Text('当前会话暂不支持确认该群成员账号。'),
              actions: [
                CupertinoDialogAction(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('知道了')),
              ]));

  Future<bool> _offerResolutionRetry() async {
    final retry = await showCupertinoDialog<bool>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
                title: const Text('无法确认红包账号'),
                content: const Text('请重试或选择其他群成员。'),
                actions: [
                  CupertinoDialogAction(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('取消')),
                  CupertinoDialogAction(
                      isDefaultAction: true,
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('重试')),
                ]));
    return retry == true;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final busy = _submitting ||
        state.status == ChatRedPacketStatus.creating ||
        state.status == ChatRedPacketStatus.sharing ||
        resolvingRecipient;
    final exclusive = mode == 'EXCLUSIVE';
    return WeChatPageScaffold.navigation(
      backgroundColor: WeChatColors.resolve(
          context, WeChatColors.redPacketCreateGradientTop),
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.resolve(
            context, WeChatColors.redPacketCreateGradientTop),
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: Text('发红包',
            style: TextStyle(
                color: WeChatColors.resolveTextPrimary(context),
                fontSize: 17,
                fontWeight: FontWeight.w600)),
      ),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              WeChatColors.resolve(
                  context, WeChatColors.redPacketCreateGradientTop),
              WeChatColors.resolve(
                  context, WeChatColors.redPacketCreateGradientBottom)
            ],
          ),
        ),
        child: Column(children: [
          Expanded(
              child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              const SizedBox(height: 10),
              if (widget.isGroup)
                Center(
                  child: CupertinoButton(
                    key: const Key('chat-red-packet-type'),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    minimumSize: Size.zero,
                    color: WeChatColors.redPacketCreateTint,
                    borderRadius: BorderRadius.circular(16),
                    onPressed: busy ? null : _pickType,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(redPacketTypeLabel(mode),
                          style: TextStyle(
                              color: WeChatColors.resolveTextPrimary(context),
                              fontSize: 14)),
                      const SizedBox(width: 4),
                      const Icon(CupertinoIcons.chevron_down,
                          size: 13, color: WeChatColors.textSecondary),
                    ]),
                  ),
                ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: WeChatColors.elevatedSurface(context),
                  borderRadius: BorderRadius.circular(10),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  _field(
                    label: '总金额',
                    key: const Key('chat-red-packet-total'),
                    controller: total,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    placeholder: '0.00',
                    suffix: '点钻',
                    enabled: !busy,
                    inputFormatters: const [TwoDecimalAmountFormatter()],
                  ),
                  _divider(),
                  if (widget.isGroup && !exclusive)
                    _field(
                      label: '红包个数',
                      key: const Key('chat-red-packet-shares'),
                      controller: shares,
                      keyboardType: TextInputType.number,
                      placeholder: '请输入个数',
                      suffix: '个',
                      enabled: !busy,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(3),
                      ],
                    ),
                  if (widget.isGroup && exclusive)
                    _pickerRow(
                      label: '指定成员',
                      key: const Key('chat-red-packet-recipient'),
                      value: recipientName,
                      onTap: busy ? null : _pickRecipient,
                    ),
                  if (widget.isGroup) _divider(),
                  _field(
                    label: '祝福语',
                    key: const Key('chat-red-packet-greeting'),
                    controller: greeting,
                    keyboardType: TextInputType.text,
                    placeholder: '恭喜发财，大吉大利',
                    enabled: !busy,
                    alignRight: false,
                  ),
                ]),
              ),
              const SizedBox(height: 8),
              if (resolvingRecipient)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CupertinoActivityIndicator(),
                        SizedBox(width: 8),
                        Text('正在确认收款账号'),
                      ]),
                ),
              const SizedBox(height: 16),
              CupertinoButton(
                key: const Key('chat-red-packet-send'),
                color: WeChatColors.redPacketAction,
                borderRadius: BorderRadius.circular(8),
                onPressed: busy ? null : _send,
                child: const Text('塞钱进红包',
                    style: TextStyle(
                        color: CupertinoColors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600)),
              ),
              if (state.status == ChatRedPacketStatus.sent)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Center(
                      child: Text('红包已发送',
                          style: TextStyle(
                              color: WeChatColors.brandPrimary, fontSize: 14))),
                ),
              if (state.status == ChatRedPacketStatus.shareFailed)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Center(
                    child: CupertinoButton(
                      onPressed: () => widget.controller.retryShare(),
                      child: const Text('红包已创建，重新发送到会话',
                          style: TextStyle(
                              color: WeChatColors.brandPrimary, fontSize: 14)),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
            ],
          )),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Text('未领取的红包，将于24小时后发起退款',
                textAlign: TextAlign.center,
                style:
                    TextStyle(color: WeChatColors.textSecondary, fontSize: 12)),
          ),
        ]),
      ),
    );
  }

  Widget _divider() => Container(
      height: .5,
      margin: const EdgeInsets.only(left: 16),
      color: WeChatColors.resolve(context, WeChatColors.divider));

  Widget _field({
    required String label,
    required Key key,
    required TextEditingController controller,
    required TextInputType keyboardType,
    required String placeholder,
    String? suffix,
    bool alignRight = true,
    bool enabled = true,
    List<TextInputFormatter> inputFormatters = const [],
  }) =>
      Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: WeChatColors.elevatedSurface(context),
        child: Row(children: [
          SizedBox(
              width: 84,
              child: Text(label,
                  style: TextStyle(
                      fontSize: 16,
                      color: WeChatColors.resolveTextPrimary(context)))),
          Expanded(
            child: CupertinoTextField(
              key: key,
              controller: controller,
              enabled: enabled,
              textAlign: alignRight ? TextAlign.right : TextAlign.left,
              keyboardType: keyboardType,
              placeholder: placeholder,
              inputFormatters: inputFormatters,
              style: TextStyle(
                  fontSize: 16,
                  color: WeChatColors.resolveTextPrimary(context)),
              placeholderStyle: const TextStyle(
                  fontSize: 16, color: WeChatColors.textTertiary),
              decoration: const BoxDecoration(),
            ),
          ),
          if (suffix != null) ...[
            const SizedBox(width: 6),
            Text(suffix,
                style: const TextStyle(
                    fontSize: 15, color: WeChatColors.textSecondary)),
          ],
        ]),
      );

  Widget _pickerRow({
    required String label,
    required Key key,
    String? value,
    VoidCallback? onTap,
  }) =>
      Container(
        key: key,
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: WeChatColors.elevatedSurface(context),
        child: Row(children: [
          SizedBox(
              width: 84,
              child: Text(label, style: const TextStyle(fontSize: 16))),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: SizedBox(
                height: 54,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(value ?? '请选择',
                        style: TextStyle(
                            fontSize: 16,
                            color: value == null
                                ? WeChatColors.textTertiary
                                : WeChatColors.resolveTextPrimary(context))),
                    const SizedBox(width: 4),
                    const Icon(CupertinoIcons.chevron_right,
                        size: 14, color: WeChatColors.textTertiary),
                  ],
                ),
              ),
            ),
          ),
        ]),
      );
}
