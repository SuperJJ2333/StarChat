import 'package:flutter/cupertino.dart';
import '../../core/amount_rules.dart';
import '../../core/business_api_client.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/foundation/changliao_icons.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../contacts/contact_models.dart';
import 'chat_transfer_controller.dart';

abstract interface class ChatTransferBalanceSource {
  Future<double> balance();
}

abstract interface class ChatTransferContactsSource {
  Future<List<ContactSummary>> contacts();
}

final class BusinessChatTransferBalanceSource
    implements ChatTransferBalanceSource {
  const BusinessChatTransferBalanceSource(this.api);
  final BusinessApiClient api;
  @override
  Future<double> balance() async {
    final body = await api.caibiBalance();
    return double.tryParse(body['balance']?.toString() ?? '') ?? 0;
  }
}

final class BusinessChatTransferContactsSource
    implements ChatTransferContactsSource {
  const BusinessChatTransferContactsSource(this.api);
  final BusinessApiClient api;
  @override
  Future<List<ContactSummary>> contacts() => api.listContacts();
}

final class ChatTransferSheet extends StatefulWidget {
  const ChatTransferSheet({
    super.key,
    required this.controller,
    required this.onSent,
    this.peerId,
    this.peerName,
    this.peerAvatarUrl,
    this.balanceSource,
    this.contactsSource,
  });
  final ChatTransferController controller;

  /// Direct-chat peer, preselected as the default recipient when present.
  final String? peerId;
  final String? peerName;
  final String? peerAvatarUrl;
  final VoidCallback onSent;
  final ChatTransferBalanceSource? balanceSource;
  final ChatTransferContactsSource? contactsSource;
  @override
  State<ChatTransferSheet> createState() => _State();
}

final class _State extends State<ChatTransferSheet> {
  final amount = TextEditingController();
  final note = TextEditingController();
  String? recipientId;
  String? recipientName;
  String? recipientAvatarUrl;
  double? balance;
  List<ContactSummary>? contacts;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_change);
    recipientId = widget.peerId;
    recipientName = widget.peerName;
    recipientAvatarUrl = widget.peerAvatarUrl;
    _loadBalance();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_change);
    amount.dispose();
    note.dispose();
    super.dispose();
  }

  void _change() {
    if (mounted) setState(() {});
  }

  Future<void> _loadBalance() async {
    final source = widget.balanceSource;
    if (source == null) return;
    try {
      final loaded = await source.balance();
      if (mounted) setState(() => balance = loaded);
    } catch (_) {
      // The server remains authoritative for balance checks.
    }
  }

  static double _fee(double value) {
    final rounded = (value * 0.005 * 100).roundToDouble() / 100;
    return rounded < 0.01 ? 0.01 : rounded;
  }

  Future<void> _send() async {
    if (recipientId == null || recipientId!.isEmpty) {
      await _alert('请选择收款用户');
      return;
    }
    final amountError = AmountRules.validate(amount.text);
    if (amountError != null) {
      await _alert(amountError);
      return;
    }
    final value = double.parse(amount.text.trim());
    if (balance != null && value + _fee(value) > balance!) {
      await _alert('转账失败，账户余额不足',
          alertKey: const Key('chat-transfer-insufficient-dialog'));
      return;
    }
    final confirmed = await _confirm(value);
    if (!confirmed) return;
    await widget.controller.submit(
      receiverId: recipientId!,
      amount: value.toStringAsFixed(2),
      note: note.text.trim(),
    );
    if (!mounted) return;
    final state = widget.controller.state;
    if (state.status == ChatTransferStatus.sent) {
      widget.onSent();
      return;
    }
    if (state.status == ChatTransferStatus.failed && state.message != null) {
      await _alert(state.message!);
    }
  }

  Future<bool> _confirm(double value) async {
    final selected = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        key: const Key('chat-transfer-confirm-dialog'),
        title: const Text('确认转账'),
        content: Text(
            '将向 ${recipientName ?? recipientId} 转账 ${value.toStringAsFixed(2)} 点钻'
            '，手续费 ${_fee(value).toStringAsFixed(2)} 点钻由转出方承担。'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            key: const Key('chat-transfer-confirm-action'),
            isDefaultAction: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认转账'),
          ),
        ],
      ),
    );
    return selected == true;
  }

  Future<void> _alert(String message, {Key? alertKey}) =>
      showCupertinoDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => CupertinoAlertDialog(
          key: alertKey ?? const Key('chat-transfer-error-dialog'),
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

  Future<void> _pickRecipient() async {
    var source = widget.contactsSource;
    if (source == null) {
      await _alert('通讯录暂不可用，无法选择收款用户');
      return;
    }
    if (contacts == null) {
      try {
        final loaded = await source.contacts();
        if (mounted) setState(() => contacts = loaded);
      } catch (_) {
        if (mounted) {
          await _alert('通讯录加载失败，请稍后重试');
          return;
        }
      }
    }
    final list = contacts ?? const <ContactSummary>[];
    if (!mounted) return;
    if (list.isEmpty) {
      await _alert('暂无可转账的好友');
      return;
    }
    final selected = await showCupertinoModalPopup<ContactSummary>(
      context: context,
      builder: (sheetContext) => CupertinoPopupSurface(
        child: SafeArea(
          child: SizedBox(
            height: 400,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('选择收款用户',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                Expanded(
                  child: ListView.builder(
                    key: const Key('chat-transfer-contact-list'),
                    itemCount: list.length,
                    itemBuilder: (context, index) {
                      final contact = list[index];
                      return CupertinoButton(
                        key: Key('chat-transfer-contact-${contact.userId}'),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        onPressed: () => Navigator.pop(sheetContext, contact),
                        child: Row(
                          children: [
                            UserAvatar(
                              nickname: contact.displayName,
                              fallbackSeed: contact.userId,
                              avatarUrl: contact.avatarUrl,
                              size: 36,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(contact.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 16)),
                            ),
                            if (recipientId == contact.userId)
                              const Icon(CupertinoIcons.check_mark,
                                  size: 16,
                                  color: WeChatColors.brandPrimary),
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
        recipientId = selected.userId;
        recipientName = selected.displayName;
        recipientAvatarUrl = selected.avatarUrl;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final busy = state.status == ChatTransferStatus.creating ||
        state.status == ChatTransferStatus.sharing;
    final card = WeChatColors.elevatedSurface(context);
    return WeChatPageScaffold.navigation(
      navigationBar: const CupertinoNavigationBar(middle: Text('转账')),
      child: ListView(padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
        const SizedBox(height: 12),
        Container(
          height: 68,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            Text('转账给',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: WeChatColors.resolveTextPrimary(context))),
            const SizedBox(width: 10),
            if (recipientId != null) ...[
              UserAvatar(
                nickname: recipientName ?? recipientId!,
                fallbackSeed: recipientId!,
                avatarUrl: recipientAvatarUrl,
                size: 36,
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: busy ? null : _pickRecipient,
                child: Text(
                  recipientName ?? '请选择收款用户',
                  key: const Key('chat-transfer-recipient'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 16,
                      color: recipientName == null
                          ? WeChatColors.textTertiary
                          : WeChatColors.resolveTextPrimary(context)),
                ),
              ),
            ),
            const Icon(CupertinoIcons.chevron_right,
                size: 15, color: WeChatColors.textTertiary),
          ]),
        ),
        const SizedBox(height: 10),
        Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            Text('金额',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: WeChatColors.resolveTextPrimary(context))),
            const SizedBox(width: 10),
            Expanded(
              child: CupertinoTextField(
                key: const Key('chat-transfer-amount'),
                controller: amount,
                enabled: !busy,
                textAlign: TextAlign.right,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: const [TwoDecimalAmountFormatter()],
                placeholder: '0.00',
                style: TextStyle(
                    fontSize: 24,
                    color: WeChatColors.resolveTextPrimary(context)),
                decoration: const BoxDecoration(),
              ),
            ),
            const SizedBox(width: 6),
            const Text('点钻',
                style: TextStyle(
                    fontSize: 15, color: WeChatColors.textSecondary)),
          ]),
        ),
        const SizedBox(height: 10),
        Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            Text('转账说明',
                style: TextStyle(
                    fontSize: 16,
                    color: WeChatColors.resolveTextPrimary(context))),
            const SizedBox(width: 10),
            Expanded(
              child: CupertinoTextField(
                key: const Key('chat-transfer-note'),
                controller: note,
                enabled: !busy,
                textAlign: TextAlign.right,
                keyboardType: TextInputType.text,
                placeholder: '点击添加转账说明',
                style: TextStyle(
                    fontSize: 15,
                    color: WeChatColors.resolveTextPrimary(context)),
                maxLength: 64,
                decoration: const BoxDecoration(),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 8),
        Text(
          balance == null
              ? '转账将收取 0.5% 手续费，最低 0.01 点钻'
              : '余额 ${balance!.toStringAsFixed(2)} 点钻 · 收取 0.5% 手续费，最低 0.01 点钻',
          key: const Key('chat-transfer-fee-hint'),
          textAlign: TextAlign.center,
          style: const TextStyle(
              color: WeChatColors.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: 20),
        ModernActionButton(
          key: const Key('chat-transfer-send'),
          icon: ChangliaoIcons.transfer,
          label: '转账',
          loading: busy,
          onPressed: busy ? null : _send,
        ),
        if (state.status == ChatTransferStatus.sent)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Center(
                child: Text('转账已发送',
                    style: TextStyle(
                        color: WeChatColors.brandPrimary, fontSize: 14))),
          ),
        if (state.status == ChatTransferStatus.shareFailed)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Center(
              child: CupertinoButton(
                onPressed: () => widget.controller.retryShare(),
                child: const Text('转账已创建，重新发送到会话',
                    style:
                        TextStyle(color: WeChatColors.socialLink, fontSize: 14)),
              ),
            ),
          ),
      ]),
    );
  }
}
