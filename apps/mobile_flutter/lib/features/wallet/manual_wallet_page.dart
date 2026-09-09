import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'manual_mfa_page.dart';
import 'manual_operation_store.dart';
import 'manual_wallet_api.dart';

final class ManualWalletPage extends StatefulWidget {
  const ManualWalletPage(
      {super.key, required this.client, this.clock = DateTime.now});
  final BusinessApiClient client;
  final DateTime Function() clock;
  @override
  State<ManualWalletPage> createState() => _ManualWalletPageState();
}

final class _ManualWalletPageState extends State<ManualWalletPage> {
  late final api = ManualWalletApi(widget.client);
  late final store = ManualOperationStore(widget.client);
  final address = TextEditingController();
  final amount = TextEditingController();
  final signature = TextEditingController();
  final oldSignature = TextEditingController();
  final otp = TextEditingController();
  ManualBindingStatus? binding;
  ManualBindingChallenge? challenge;
  ManualDepositIntent? deposit;
  ManualPayoutQuote? quote;
  ManualPayout? payout;
  Map<String, dynamic>? bindingOp, depositOp, quoteOp, payoutOp;
  String? message;
  bool messageIsWarning = false;
  bool busy = false, ready = false;
  bool depositEnabled = false, payoutEnabled = false, executionEnabled = false;
  bool capabilitiesKnown = false;
  bool addressOnly = false;
  int tab = 0;
  Timer? depositDeadline;
  Timer? bindingCountdown;
  bool showBindingDetails = false;
  bool showOrderDetails = false;
  String get bindingTimeLeft {
    final seconds = challenge!.expiresAt.difference(widget.clock()).inSeconds;
    if (seconds <= 0) return '验证请求已过期，请刷新状态后重新获取';
    return '请在 ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')} 内完成验证';
  }

  bool get depositOpen =>
      deposit?.status == ManualIntentState.open &&
      widget.clock().isBefore(deposit!.expiresAt);

  void watchDepositDeadline() {
    depositDeadline?.cancel();
    if (depositOpen) {
      depositDeadline =
          Timer(deposit!.expiresAt.difference(widget.clock()), () {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void initState() {
    super.initState();
    run(() async {
      await store.initialize();
      bindingOp = await store.read('binding');
      depositOp = await store.read('deposit');
      quoteOp = await store.read('quote');
      payoutOp = await store.read('payout');
      if (!mounted) return;
      address.text = bindingOp?['address'] as String? ?? '';
      ready = true;
      await refresh();
    });
  }

  Future<void> refresh() async {
    depositEnabled = payoutEnabled = executionEnabled = false;
    capabilitiesKnown = false;
    try {
      final config = await widget.client.walletConfig();
      depositEnabled = config['funding_enabled'] == true;
      payoutEnabled = config['manual_payout_enabled'] == true;
      executionEnabled = config['manual_payout_execution_enabled'] == true;
      capabilitiesKnown = true;
      addressOnly = config['user_auth_mode'] == 'address_only';
    } catch (_) {
      // Status recovery remains available when activation configuration fails.
    }
    binding = await api.bindingStatus();
    if (bindingOp != null &&
        (binding!.pendingId != null ||
            binding!.version > (bindingOp!['version'] as int))) {
      await store.clear('binding');
      bindingOp = null;
      challenge = null;
    }
    if (depositOp?['id'] != null) {
      deposit = await api.depositIntent(depositOp!['id'] as String);
      watchDepositDeadline();
    }
    if (payoutOp?['id'] != null) {
      payout = await api.payout(payoutOp!['id'] as String);
    }
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
      messageIsWarning = false;
    });
    try {
      await action();
    } catch (error) {
      messageIsWarning = true;
      const explanations = {
        'WALLET_ADDRESS_INVALID': '地址格式不正确，请填写有效的 TRON 地址并检查是否复制完整。',
        'WALLET_ADDRESS_OWNED': '该地址已被其他账号登记，请核对地址或联系管理员。',
        'WALLET_REBIND_TOO_SOON': '距离上次修改未满 30 天，请查看下次可修改时间。',
        'WALLET_BINDING_PENDING': '地址正在同步，请稍后刷新状态。',
        'WALLET_WITHDRAWAL_IN_PROGRESS': '还有未完成的提现，请处理完成后再修改地址。',
      };
      message = error is BusinessApiException
          ? explanations[error.code] ?? '${error.message}（${error.code}）'
          : error is FormatException
              ? error.message
              : error is StateError
                  ? error.message.toString()
                  : '结果未确认。保留原操作，请刷新或重试原申请。';
    } finally {
      if (mounted) {
        otp.clear();
        signature.clear();
        oldSignature.clear();
        setState(() => busy = false);
      }
    }
  }

  Future<void> createChallenge() async {
    bindingOp = await store.begin('binding', {
      'address': address.text.trim(),
      'version': binding!.version,
      'confirm_key': widget.client.newIdempotencyKey(),
    });
    challenge = await api.createBindingChallenge(
        address: bindingOp!['address'] as String,
        expectedVersion: bindingOp!['version'] as int,
        idempotencyKey: bindingOp!['key'] as String);
    showBindingDetails = false;
    bindingCountdown?.cancel();
    bindingCountdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || challenge == null) {
        timer.cancel();
        return;
      }
      setState(() {});
      if (!widget.clock().isBefore(challenge!.expiresAt)) timer.cancel();
    });
  }

  Future<void> confirmBinding() async {
    if (otp.text.trim().isEmpty || signature.text.trim().isEmpty) {
      throw const FormatException('请输入钱包签名和当前验证码');
    }
    bindingOp = {...bindingOp!, 'id': challenge!.id};
    await store.save('binding', bindingOp!);
    late final ManualBindingConfirmation result;
    try {
      result = await api.confirmBinding(
          challengeId: challenge!.id,
          signature: signature.text.trim(),
          oldSignature: oldSignature.text.trim().isEmpty
              ? null
              : oldSignature.text.trim(),
          mfaProof: otp.text.trim(),
          idempotencyKey: bindingOp!['confirm_key'] as String);
    } on BusinessApiException catch (error) {
      if (error.code == 'WALLET_CHALLENGE_EXPIRED_OR_CONSUMED') {
        // This is a definitive server rejection, never a local timeout guess.
        binding = await api.bindingStatus();
        await store.clear('binding');
        bindingOp = null;
        challenge = null;
      }
      rethrow;
    }
    message = '绑定待确认：${result.blockedReason}。刷新查看服务端激活结果。';
    binding = await api.bindingStatus();
    await store.clear('binding');
    bindingOp = null;
    challenge = null;
  }

  Future<void> registerAddress() async {
    if (bindingOp != null && bindingOp!['method'] != 'address_only') {
      throw const FormatException('存在旧版绑定请求，请先刷新状态；尚未提交的请求可重新填写地址。');
    }
    bindingOp = await store.begin('binding', {
      'address': address.text.trim(),
      'version': binding!.version,
      'method': 'address_only'
    });
    final result = await api.registerAddress(
        address: bindingOp!['address'] as String,
        expectedVersion: bindingOp!['version'] as int,
        idempotencyKey: bindingOp!['key'] as String);
    bindingOp = {...bindingOp!, 'id': result.id};
    await store.save('binding', bindingOp!);
    await refresh();
    message = binding?.status == ManualBindingState.active
        ? '钱包地址已保存'
        : '地址已登记，正在同步链上起始位置，请稍后刷新。';
  }

  Future<void> createDeposit() async {
    depositOp = await store.begin('deposit',
        {'amount': manualAmount(amount.text), 'version': binding!.version});
    if (depositOp!['id'] != null) {
      deposit = await api.depositIntent(depositOp!['id'] as String);
      watchDepositDeadline();
      return;
    }
    try {
      deposit = await api.createDepositIntent(
          amount: depositOp!['amount'] as String,
          expectedBindingVersion: depositOp!['version'] as int,
          idempotencyKey: depositOp!['key'] as String);
    } on BusinessApiException catch (error) {
      if ({'WALLET_BINDING_VERSION_CONFLICT', 'WALLET_DEPOSIT_INTENT_OPEN'}
          .contains(error.code)) {
        binding = await api.bindingStatus();
        deposit = await api.currentDepositIntent();
        watchDepositDeadline();
        if (deposit == null) {
          await store.clear('deposit');
          depositOp = null;
        } else {
          depositOp = {
            ...depositOp!,
            'id': deposit!.id,
            'amount': deposit!.expectedAmount,
            'version': deposit!.bindingVersion
          };
          await store.save('deposit', depositOp!);
        }
      }
      rethrow;
    }
    depositOp = {...depositOp!, 'id': deposit!.id};
    await store.save('deposit', depositOp!);
    watchDepositDeadline();
  }

  Future<void> createQuote() async {
    quoteOp = await store.begin('quote',
        {'amount': manualAmount(amount.text), 'version': binding!.version});
    quote = await api.createPayoutQuote(
        amount: quoteOp!['amount'] as String,
        expectedBindingVersion: quoteOp!['version'] as int,
        idempotencyKey: quoteOp!['key'] as String);
  }

  Future<void> requestPayout() async {
    if (!addressOnly && otp.text.trim().isEmpty) {
      throw const FormatException('请输入当前六位验证码');
    }
    payoutOp = await store
        .begin('payout', {'quote_id': payoutOp?['quote_id'] ?? quote!.id});
    // MFA is deliberately not persisted. The server replay fingerprint contains
    // quote_id only and authenticates the newly entered code before replay.
    try {
      payout = await api.createPayout(
          quoteId: payoutOp!['quote_id'] as String,
          mfaProof: addressOnly ? null : otp.text.trim(),
          idempotencyKey: payoutOp!['key'] as String);
    } on BusinessApiException catch (error) {
      // Backend checks successful replay before these quote rejections.
      // Network/unknown failures deliberately retain the original operation.
      if ({'WALLET_PAYOUT_QUOTE_EXPIRED', 'WALLET_PAYOUT_QUOTE_CHANGED'}
          .contains(error.code)) {
        await store.clear('payout');
        await store.clear('quote');
        payoutOp = quoteOp = null;
        payout = null;
        quote = null;
      }
      rethrow;
    }
    payoutOp = {...payoutOp!, 'id': payout!.id};
    await store.save('payout', payoutOp!);
  }

  Future<void> cancel() async {
    final confirmed = await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
                title: const Text('取消提现申请？'),
                content: const Text('仅财务尚未领取的申请可以取消，结果以服务端状态为准。'),
                actions: [
                  CupertinoDialogAction(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('保留')),
                  CupertinoDialogAction(
                      isDestructiveAction: true,
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('确认取消'))
                ]));
    if (confirmed != true) return;
    await run(() async {
      final op = await store.begin('cancel', {'id': payout!.id});
      payout = await api.cancelPayout(op['id'] as String,
          idempotencyKey: op['key'] as String);
    });
  }

  @override
  void dispose() {
    depositDeadline?.cancel();
    bindingCountdown?.cancel();
    for (final field in [address, amount, signature, oldSignature, otp]) {
      field.dispose();
    }
    super.dispose();
  }

  Widget button(String text, Future<void> Function() action,
          {String? key, bool enabled = true}) =>
      Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: CupertinoButton(
              color: key == null ? null : WeChatColors.brandPrimary,
              borderRadius: BorderRadius.circular(8),
              onPressed: busy || !ready || !enabled ? null : () => run(action),
              key: key == null ? null : Key(key),
              child: Text(text,
                  style: key != null && !busy && ready && enabled
                      ? const TextStyle(color: CupertinoColors.white)
                      : null)));
  Widget field(String name, TextEditingController controller, String hint,
          {bool secret = false, bool enabled = true}) =>
      Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: CupertinoTextField(
              key: Key(name),
              controller: controller,
              placeholder: hint,
              enabled: enabled && !busy,
              obscureText: secret,
              autocorrect: false,
              enableSuggestions: false,
              padding: const EdgeInsets.all(14)));
  Widget copyIcon(String value, String key,
          {bool enabled = true, bool Function()? canCopy}) =>
      Semantics(
          label: '复制地址',
          child: CupertinoButton(
              key: Key(key),
              padding: const EdgeInsets.all(10),
              onPressed: !enabled || busy || value.isEmpty
                  ? null
                  : () => run(() async {
                        if (canCopy != null && !canCopy()) {
                          throw const FormatException('本次充值申请已过期，请勿转账');
                        }
                        await Clipboard.setData(ClipboardData(text: value));
                        message = '地址已复制';
                      }),
              child: const Icon(CupertinoIcons.doc_on_doc, size: 20)));
  Widget addressRow(String label, String value, String key,
          {bool Function()? canCopy}) =>
      Row(children: [
        SizedBox(
            width: 72,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 13, color: WeChatColors.textSecondary))),
        Expanded(
            child: Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13))),
        copyIcon(value, key, canCopy: canCopy),
      ]);
  String shortDate(DateTime value) =>
      value.toLocal().toIso8601String().substring(0, 16).replaceFirst('T', ' ');
  Widget warningBox(String text, {String? key}) {
    final red = CupertinoColors.systemRed.resolveFrom(context);
    return Semantics(
        liveRegion: true,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: red.withValues(alpha: 0.08),
              border: Border.all(color: red.withValues(alpha: 0.25)),
              borderRadius: BorderRadius.circular(8)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(CupertinoIcons.exclamationmark_triangle_fill,
                size: 17, color: red),
            const SizedBox(width: 8),
            Expanded(
                child: Text(text,
                    key: key == null ? null : Key(key),
                    style: TextStyle(fontSize: 13, height: 1.4, color: red))),
          ]),
        ));
  }

  Widget shortcut(
          String label, IconData icon, Future<void> Function() action) =>
      CupertinoButton(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          color: WeChatColors.elevatedSurface(context),
          borderRadius: BorderRadius.circular(8),
          onPressed: busy || !ready ? null : () => run(action),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 18, color: WeChatColors.brandPrimary),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(
                    fontSize: 15,
                    color: WeChatColors.resolveTextPrimary(context))),
          ]));
  Widget detail(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Text('$label：$value',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, height: 1.4)));

  Widget card(List<Widget> children) => Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: WeChatColors.elevatedSurface(context),
          borderRadius: BorderRadius.circular(12)),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: children));

  Future<void> showHelp() async {
    await showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
                title: const Text('钱包使用说明'),
                content: const Text(
                    '仅支持 TRON 网络 USDT（TRC20）。充值与提现每笔最低 10 USDT，服务费为 0。请先登记地址，再创建充值申请。提现由管理员人工付款。地址每 30 天最多修改一次，请仔细核对。'),
                actions: [
                  CupertinoDialogAction(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('知道了'))
                ]));
  }

  Future<void> showHistory() async {
    final data = await widget.client.walletHistory();
    if (!mounted) return;
    final rows = (data['items'] as List?) ?? [];
    await Navigator.of(context).push(CupertinoPageRoute<void>(
        builder: (context) => WeChatPageScaffold.navigation(
            navigationBar: const CupertinoNavigationBar(middle: Text('钱包记录')),
            child: SafeArea(
                child: ListView(padding: const EdgeInsets.all(20), children: [
              if (rows.isEmpty) const Text('暂无交易记录'),
              for (final row in rows)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                        '${row['kind'] == 'deposit' ? '充值' : '提现'}  ${row['amount'] ?? ''} USDT\n${row['status'] ?? ''}')),
            ])))));
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            middle: const Text('TRON 钱包'),
            trailing: Semantics(
                label: '刷新状态',
                child: CupertinoButton(
                    key: const Key('manual-refresh'),
                    padding: EdgeInsets.zero,
                    onPressed: busy || !ready ? null : () => run(refresh),
                    child: busy
                        ? const CupertinoActivityIndicator()
                        : const Icon(CupertinoIcons.refresh, size: 22)))),
        child: SafeArea(
            child: ListView(padding: const EdgeInsets.all(16), children: [
          Container(
              key: const Key('manual-wallet-summary'),
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                  color: WeChatColors.elevatedSurface(context),
                  borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                const Icon(CupertinoIcons.creditcard,
                    color: WeChatColors.brandPrimary, size: 28),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('USDT · TRC20',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(binding?.maskedAddress ?? '请先添加你的钱包地址',
                          style: const TextStyle(
                              fontSize: 13, color: WeChatColors.textSecondary)),
                      if (binding != null) ...[
                        const SizedBox(height: 4),
                        Text(
                            switch (binding!.status) {
                              ManualBindingState.active => '已登记',
                              ManualBindingState.pending => '同步中',
                              _ => '未登记',
                            },
                            style: const TextStyle(
                                fontSize: 12,
                                color: WeChatColors.textSecondary)),
                        if (binding!.nextRebindAt != null) ...[
                          const SizedBox(height: 4),
                          Text('下次可改绑：${shortDate(binding!.nextRebindAt!)}',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: WeChatColors.textSecondary)),
                        ],
                      ],
                    ])),
                if (binding?.address != null)
                  copyIcon(binding!.address!, 'manual-current-copy'),
              ])),
          Row(children: [
            Expanded(
                child:
                    shortcut('交易记录', CupertinoIcons.list_bullet, showHistory)),
            const SizedBox(width: 12),
            Expanded(
                child:
                    shortcut('使用帮助', CupertinoIcons.question_circle, showHelp)),
          ]),
          const SizedBox(height: 16),
          if (!addressOnly)
            CupertinoButton(
                onPressed: busy
                    ? null
                    : () => Navigator.of(context).push(CupertinoPageRoute<void>(
                        builder: (_) => ManualMfaPage(client: widget.client))),
                child: const Text('设置身份验证器')),
          CupertinoSlidingSegmentedControl<int>(
              groupValue: tab,
              children: const {1: Text('充值'), 2: Text('提现'), 0: Text('钱包绑定')},
              onValueChanged: (value) {
                if (busy || value == null) return;
                setState(() {
                  tab = value;
                  amount.text =
                      (tab == 1 ? depositOp : quoteOp)?['amount'] as String? ??
                          '';
                  otp.clear();
                });
              }),
          const SizedBox(height: 16),
          if (!capabilitiesKnown) warningBox('功能状态暂不可用，请刷新；已有订单仍可查询。'),
          if (binding != null) ...[
            if (!binding!.bindingEnabled) warningBox('绑定暂不可用，请联系管理员'),
          ],
          if (tab == 0)
            card(addressOnly ? registrationFields() : bindingFields()),
          if (tab == 1) card(depositFields()),
          if (tab == 2) card(payoutFields()),
          if (busy) const CupertinoActivityIndicator(),
          if (message != null)
            messageIsWarning
                ? warningBox(message!, key: 'manual-feedback')
                : Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(message!,
                        key: const Key('manual-feedback'),
                        style: const TextStyle(
                            color: WeChatColors.textSecondary))),
        ])),
      );

  List<Widget> registrationFields() => [
        const Text('常用钱包地址',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
              child: field('manual-binding-address', address, '粘贴你的 TRON 地址',
                  enabled: bindingOp == null)),
          ValueListenableBuilder<TextEditingValue>(
              valueListenable: address,
              builder: (_, value, child) =>
                  copyIcon(value.text.trim(), 'manual-binding-copy')),
        ]),
        const Text('仅填本人地址 · 每 30 天可修改一次',
            style: TextStyle(fontSize: 13, color: WeChatColors.textSecondary)),
        button(bindingOp == null ? '保存钱包地址' : '继续原地址登记', registerAddress,
            key: 'manual-register-address',
            enabled: capabilitiesKnown && binding?.bindingEnabled == true),
        if (bindingOp != null &&
            bindingOp!['method'] != 'address_only' &&
            bindingOp!['id'] == null)
          button('重新填写钱包地址', () async {
            await store.clear('binding');
            bindingOp = null;
            challenge = null;
          }),
      ];

  List<Widget> bindingFields() => [
        const Text('1 · 填写私人钱包地址',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Text('用于识别你的充值，并作为提现收款地址。每 30 天最多改绑一次。'),
        field('manual-binding-address', address, '私人 TRON 钱包地址',
            enabled: bindingOp == null),
        if (bindingOp?['id'] != null)
          const Text('绑定结果尚未确认。先刷新状态；重试时粘贴与首次提交完全相同的签名。'),
        button(bindingOp == null ? '开始验证钱包归属' : '恢复本次验证', createChallenge,
            enabled: binding?.bindingEnabled == true, key: 'manual-challenge'),
        if (bindingOp != null && bindingOp?['id'] == null)
          button('重新填写钱包地址', () async {
            await store.clear('binding');
            bindingOp = null;
            challenge = null;
          }),
        if (challenge != null) ...[
          const SizedBox(height: 12),
          const Text('2 · 验证钱包归属',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('证明你能控制这个钱包。本次验证不转账、不收取链上费用，也不授权平台转走资产。'),
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(bindingTimeLeft,
                  key: const Key('manual-binding-countdown'),
                  style: const TextStyle(color: WeChatColors.textSecondary))),
          const Text(
              '当前版本需手动获取钱包签名：复制验证内容，在支持消息签名的钱包中确认，再粘贴返回的签名。请勿填写私钥、助记词或钱包密码。'),
          button('复制验证内容', () async {
            await Clipboard.setData(ClipboardData(text: challenge!.message));
            message = '完整验证内容已复制，请在钱包中核对后签名';
          }),
          CupertinoButton(
              key: const Key('manual-binding-details'),
              onPressed: () =>
                  setState(() => showBindingDetails = !showBindingDetails),
              child: Text(showBindingDetails ? '收起技术详情' : '查看技术详情')),
          if (showBindingDetails) ...[
            const Text('签名协议：signMessageV2。原文中的账号、随机编号和有效期用于防止凭证被替换或重复使用。'),
            Text(challenge!.message,
                key: const Key('manual-challenge-message')),
          ],
          field('manual-binding-signature', signature, '粘贴钱包返回的签名',
              secret: true),
          if (binding?.status == ManualBindingState.active)
            field('manual-binding-old-signature', oldSignature, '原钱包对同一消息的签名',
                secret: true),
          const SizedBox(height: 12),
          const Text('3 · 确认账号身份',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
              '打开为本平台设置的身份验证器，输入当前六位动态码。它不是钱包密码或短信验证码。尚未设置时，请先打开页面上方的「设置身份验证器」。'),
          field('manual-binding-otp', otp, '输入身份验证器当前六位动态码', secret: true),
          button('确认钱包绑定', confirmBinding, key: 'manual-binding-confirm'),
        ],
      ];

  List<Widget> depositFields() => [
        if (!depositEnabled) warningBox('充值入账暂未开放，请勿转账。'),
        const Text('充值金额',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Text('最低 10 USDT · 仅支持 TRC20',
            style: TextStyle(fontSize: 13, color: WeChatColors.textSecondary)),
        field('manual-deposit-amount', amount, '充值金额',
            enabled: depositOp == null),
        button(depositOp == null ? '下一步' : '查看本次充值', createDeposit,
            enabled: depositOp != null ||
                (depositEnabled &&
                    binding?.status == ManualBindingState.active),
            key: 'manual-deposit-create'),
        if (deposit != null) ...[
          detail(
              '状态',
              switch (deposit!.status) {
                ManualIntentState.open => '待转账',
                ManualIntentState.expired => '已过期',
                ManualIntentState.fulfilled => '已完成',
                ManualIntentState.closedByRebind => '已关闭',
              }),
          detail('金额 USDT', deposit!.expectedAmount),
          addressRow('转出钱包', deposit!.sourceAddress, 'manual-source-copy'),
          detail('有效期', shortDate(deposit!.expiresAt)),
          if (depositOpen && depositEnabled) ...[
            addressRow('收款地址', deposit!.officialAddress, 'manual-official-copy',
                canCopy: () => depositOpen && depositEnabled),
            Center(
                child: QrImageView(
                    key: const Key('manual-deposit-qr'),
                    data: deposit!.officialAddress,
                    size: 180,
                    backgroundColor: CupertinoColors.white)),
          ],
          if (deposit!.status == ManualIntentState.expired ||
              (deposit!.status == ManualIntentState.open && !depositOpen))
            warningBox('本次充值申请已过期，请勿转账'),
          if (deposit!.status == ManualIntentState.closedByRebind)
            warningBox('钱包地址已变更，本次充值已关闭，请勿转账'),
          if (deposit!.status != ManualIntentState.open)
            button('再次充值', () async {
              await store.clear('deposit');
              depositOp = null;
              deposit = null;
              if (mounted) amount.clear();
            }),
        ],
      ];

  List<Widget> payoutFields() => [
        if (!payoutEnabled) warningBox('提现申请暂未开放；已有订单可刷新查询或按状态取消。'),
        const Text('提现金额',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (!executionEnabled) warningBox('付款暂未开放，申请后等待处理'),
        if (executionEnabled)
          const Text('最低 10 USDT · 免手续费 · 人工处理',
              style: TextStyle(
                  fontSize: 13, color: WeChatColors.textSecondary)),
        field('manual-payout-amount', amount, '提现金额',
            enabled: quoteOp == null && payoutOp == null),
        if (payoutOp?['id'] == null)
          button(quoteOp == null ? '下一步' : '查看本次提现', createQuote,
              enabled:
                  payoutEnabled && binding?.status == ManualBindingState.active,
              key: 'manual-quote-create'),
        if (quote != null) ...[
          addressRow('收款地址', quote!.targetAddress, 'manual-target-copy'),
          detail('本金 USDT', quote!.amount),
          detail('服务费 USDT', quote!.fee),
          detail('总冻结 USDT', quote!.hold),
          detail('到账 USDT', quote!.receive),
          detail('确认有效期', quote!.expiresAt.toLocal().toString()),
          CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () =>
                  setState(() => showOrderDetails = !showOrderDetails),
              child: Text(showOrderDetails ? '收起详情' : '查看详情')),
          if (showOrderDetails) ...[
            detail('绑定版本', '${quote!.bindingVersion}'),
            detail('订单校验码', quote!.digest),
          ],
        ],
        if (payoutOp?['id'] == null && (quote != null || payoutOp != null)) ...[
          if (payoutOp != null)
            Text(addressOnly
                ? '原申请结果待确认，请刷新或重试同一申请，请勿重复提交。'
                : '原申请结果待确认，请使用新的验证码重试同一申请。'),
          if (!addressOnly)
            field('manual-payout-otp', otp, '身份验证器六位验证码', secret: true),
          button(payoutOp == null ? '确认提现' : '重试本次提现', requestPayout,
              enabled: payoutEnabled || payoutOp != null,
              key: 'manual-payout-confirm'),
        ],
        if (quoteOp != null && payoutOp == null)
          button('重新填写金额', () async {
            await store.clear('quote');
            quoteOp = null;
            quote = null;
          }),
        if (payout != null) ...[
          detail('订单', payout!.id),
          detail('状态', payout!.status.name),
          detail('提现 USDT', payout!.amount),
          if (payout!.reviewReason != null)
            detail('核验说明', payout!.reviewReason!),
          if (payout!.settlementTxid != null)
            detail('已结算链上交易', payout!.settlementTxid!),
          if (payout!.status == ManualPayoutState.unknown)
            warningBox('付款结果待核验，资金继续冻结，请勿重复申请。'),
          if (payout!.status == ManualPayoutState.requested)
            CupertinoButton(
                onPressed: busy ? null : cancel, child: const Text('取消提现申请')),
          if ({ManualPayoutState.settled, ManualPayoutState.cancelled}
              .contains(payout!.status))
            button('开始新的提现', () async {
              await store.clear('payout');
              await store.clear('quote');
              await store.clear('cancel');
              payoutOp = null;
              quoteOp = null;
              payout = null;
              quote = null;
              if (mounted) amount.clear();
            }),
        ],
      ];
}
