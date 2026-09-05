import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../../core/amount_rules.dart';
import '../../core/business_api_client.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'chat_red_packet_controller.dart';

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
    return RedPacketLimits(
        maxTotal:
            double.tryParse(body['max_total']?.toString() ?? '') ?? 20000);
  }
}

final class ChatRoomMember {
  const ChatRoomMember(this.id, this.name);
  final String id;
  final String name;
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
  });
  final ChatRedPacketController controller;
  final bool isGroup;
  final VoidCallback onSent;
  final ChatRedPacketSupport? support;
  final List<ChatRoomMember> members;
  @override
  State<ChatRedPacketSheet> createState() => _State();
}

final class _State extends State<ChatRedPacketSheet> {
  final total = TextEditingController();
  final shares = TextEditingController(text: '1');
  final greeting = TextEditingController(text: '恭喜发财，大吉大利');
  String mode = 'RANDOM';
  String? recipientId;
  String? recipientName;
  double? balance;
  double maxTotal = 20000;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_change);
    _loadSupport();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_change);
    total.dispose();
    shares.dispose();
    greeting.dispose();
    super.dispose();
  }

  void _change() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSupport() async {
    final support = widget.support;
    if (support == null) return;
    try {
      final loaded = await support.balance();
      if (mounted) setState(() => balance = loaded);
    } catch (_) {
      // Balance is a hint only; the server remains authoritative.
    }
    try {
      final limits = await support.limits();
      if (mounted) setState(() => maxTotal = limits.maxTotal);
    } catch (_) {
      // Limits fall back to the compiled-in default.
    }
  }

  Future<void> _send() async {
    final amountError = AmountRules.validate(total.text.trim());
    if (amountError != null) {
      await _alert(amountError);
      return;
    }
    final amount = double.parse(total.text.trim());
    if (amount > maxTotal) {
      await _alert('单个红包金额不能超过 ${maxTotal.toStringAsFixed(2)} 点钻');
      return;
    }
    var shareCount = 1;
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
    if (balance != null && amount > balance!) {
      await _alert('红包创建失败，账户余额不足',
          key: const Key('chat-red-packet-insufficient-dialog'));
      return;
    }
    await widget.controller.submit(
      total: total.text.trim(),
      greeting: greeting.text.trim().isEmpty ? '恭喜发财' : greeting.text.trim(),
      mode: widget.isGroup ? mode : 'EQUAL',
      shareCount: mode == 'EXCLUSIVE' ? 1 : shareCount,
      exclusiveRecipientId: mode == 'EXCLUSIVE' ? recipientId : null,
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
    if (widget.members.isEmpty) {
      await _alert('群成员尚未加载，请稍后再试');
      return;
    }
    final selected = await showCupertinoModalPopup<ChatRoomMember>(
      context: context,
      builder: (sheetContext) => CupertinoPopupSurface(
        child: SafeArea(
          child: SizedBox(
            height: 360,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('选择指定成员',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                Expanded(
                  child: ListView.builder(
                    key: const Key('chat-red-packet-member-list'),
                    itemCount: widget.members.length,
                    itemBuilder: (context, index) {
                      final member = widget.members[index];
                      return CupertinoButton(
                        key: Key('chat-red-packet-member-${member.id}'),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        onPressed: () => Navigator.pop(sheetContext, member),
                        child: Row(
                          children: [
                            Container(
                              width: 32,
                              height: 32,
                              alignment: Alignment.center,
                              decoration: const BoxDecoration(
                                color: WeChatColors.avatarFallbackBlue,
                                shape: BoxShape.circle,
                              ),
                              child: Text(
                                member.name.isEmpty
                                    ? '?'
                                    : member.name.characters.first,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                                child: Text(member.name,
                                    style: const TextStyle(fontSize: 16))),
                            if (recipientId == member.id)
                              const Icon(CupertinoIcons.check_mark,
                                  size: 16, color: WeChatColors.brandPrimary),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                CupertinoButton(
                  onPressed: () => Navigator.pop(sheetContext),
                  child: const Text('取消'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected != null) {
      setState(() {
        recipientId = selected.id;
        recipientName = selected.name;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final busy = state.status == ChatRedPacketStatus.creating ||
        state.status == ChatRedPacketStatus.sharing;
    final exclusive = mode == 'EXCLUSIVE';
    return WeChatPageScaffold.navigation(
      backgroundColor: WeChatColors.redPacketCreateGradientTop,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.redPacketCreateGradientTop,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: const Text('发红包',
            style: TextStyle(
                color: WeChatColors.lightTextPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600)),
      ),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              WeChatColors.redPacketCreateGradientTop,
              WeChatColors.redPacketCreateGradientBottom
            ],
          ),
        ),
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
                        style: const TextStyle(
                            color: WeChatColors.lightTextPrimary,
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
                color: CupertinoColors.white,
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
            Text(
              '单个红包金额不可超过 ${maxTotal.toStringAsFixed(2)} 点钻',
              key: const Key('chat-red-packet-limit-hint'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: WeChatColors.textSecondary, fontSize: 12),
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
            const SizedBox(height: 10),
            Text(
              '未领取的红包，将于24小时后发起退款',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: WeChatColors.textSecondary, fontSize: 12),
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
        ),
      ),
    );
  }

  Widget _divider() => Container(
      height: .5,
      margin: const EdgeInsets.only(left: 16),
      color: WeChatColors.divider);

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
        color: CupertinoColors.white,
        child: Row(children: [
          SizedBox(
              width: 84,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 16, color: WeChatColors.lightTextPrimary))),
          Expanded(
            child: CupertinoTextField(
              key: key,
              controller: controller,
              enabled: enabled,
              textAlign: alignRight ? TextAlign.right : TextAlign.left,
              keyboardType: keyboardType,
              placeholder: placeholder,
              inputFormatters: inputFormatters,
              style: const TextStyle(
                  fontSize: 16, color: WeChatColors.lightTextPrimary),
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
        color: CupertinoColors.white,
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
                                : CupertinoColors.black)),
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
