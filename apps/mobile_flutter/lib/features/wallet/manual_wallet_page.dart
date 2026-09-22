import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/wechat_gradient_divider.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/components/wechat_secondary_button.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../finance/wallet_entry_store.dart';
import 'manual_mfa_page.dart';
import 'manual_operation_store.dart';
import 'manual_payout_status_store.dart';
import 'manual_wallet_api.dart';
import 'wallet_display.dart';
import 'wallet_notice_store.dart';
import 'wallet_payment_flow.dart';
import 'wallet_qr_exporter.dart';
import '../../ui/motion/motion_page_route.dart';

Widget walletStepIndicator(
    BuildContext context, List<String> steps, int current,
    {String keyPrefix = 'manual-wallet-step'}) {
  final duration = MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : WeChatMotion.actionPressDuration;
  final idleSurface = WeChatColors.elevatedSurface(context);
  final idleLine = WeChatColors.resolve(context, WeChatColors.divider);
  return Padding(
      key: Key('$keyPrefix-steps'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        for (var index = 0; index < steps.length; index++) ...[
          if (index > 0)
            Expanded(
                child: AnimatedContainer(
                    key: Key('$keyPrefix-bar-${index - 1}'),
                    duration: duration,
                    height: 2,
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    color: index <= current
                        ? WeChatColors.brandPrimary
                        : idleLine)),
          Row(mainAxisSize: MainAxisSize.min, children: [
            AnimatedContainer(
                key: Key('$keyPrefix-dot-$index'),
                duration: duration,
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: index <= current
                        ? WeChatColors.brandPrimary
                        : idleSurface,
                    shape: BoxShape.circle),
                child: index < current
                    ? Icon(CupertinoIcons.checkmark_alt,
                        key: Key('$keyPrefix-check-$index'),
                        size: 14,
                        color: CupertinoColors.white)
                    : Text('${index + 1}',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: index <= current
                                ? CupertinoColors.white
                                : WeChatColors.textSecondary))),
            const SizedBox(width: 6),
            Text(steps[index],
                style: TextStyle(
                    fontSize: 11,
                    color: index <= current
                        ? WeChatColors.resolveTextPrimary(context)
                        : WeChatColors.textSecondary)),
          ]),
        ],
      ]));
}

enum ManualWalletSection { overview, binding, deposit, payout }

final class ManualWalletPage extends StatefulWidget {
  const ManualWalletPage(
      {super.key,
      required this.client,
      this.clock = DateTime.now,
      this.section = ManualWalletSection.overview,
      this.embedded = false,
      this.qrExporter = const GalleryQrExporter()});
  final BusinessApiClient client;
  final DateTime Function() clock;
  final ManualWalletSection section;
  final bool embedded;

  /// 收款二维码导出（申请权限 + 写入系统相册）。测试注入假实现覆盖失败/无权限态。
  final WalletQrExporter qrExporter;
  @override
  State<ManualWalletPage> createState() => _ManualWalletPageState();
}

final class _ManualWalletPageState extends State<ManualWalletPage>
    with WidgetsBindingObserver {
  late final api = ManualWalletApi(widget.client);
  late final store = ManualOperationStore(widget.client);

  /// 提现申请状态的本地快照：断网时状态卡（订单/金额/「处理中」）仍要可见。
  late final payoutStatusStore = ManualPayoutStatusStore(widget.client);

  /// 钱包进入态共享 Store（缓存优先 + 后台刷新）。持有者是会话级
  /// [WalletEntryStores]；页面只借用，[dispose] 里只 removeListener。
  late final _entryGateway = _WalletEntryGateway(widget.client, api);
  WalletEntryStore? entry;

  /// 申请提醒「不再通知」标记的持久化存储与已忽略的申请身份。
  late final noticeStore = WalletNoticeStore(widget.client);
  String? ignoredDepositNotice;
  String? ignoredPayoutNotice;
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

  /// 只有在「从未拿到过能力配置且确实加载失败」时才为真：加载中或刷新中
  /// 一律沿用上一次已知状态，避免每次进入钱包都闪一下「功能状态暂不可用」。
  bool capabilitiesUnavailable = false;
  bool addressOnly = false;
  bool bindingFresh = false;
  String? walletScope;
  String? paymentScope;
  bool pointsPayoutEnabled = false;
  bool conversionEnabled = false;
  String? pointsAvailable;
  String? pointsError;
  Map<String, dynamic>? referenceFx;
  String? referenceFxError;
  bool referenceFxRequested = false;
  bool cnyPricing = false;
  List<Map<String, dynamic>> rechargeContacts = [];
  List<Map<String, dynamic>> rechargeHistory = [];
  Map<String, dynamic>? rechargeOp;
  String? rechargeError;
  bool depositCancellationPending = false;

  Future<void> loadRecharges() async {
    try {
      await ensureCurrentScope();
      rechargeOp = await store.read('recharge');
      final contacts = await widget.client.rechargeDirectory();
      final history = await widget.client.myRecharges();
      await ensureCurrentScope();
      if (!mounted) return;
      setState(() {
        rechargeContacts = contacts;
        rechargeHistory = history;
        rechargeError = null;
        if (rechargeOp?['amount'] is String) {
          amount.text = rechargeOp!['amount'] as String;
        }
      });
    } catch (_) {
      if (mounted) setState(() => rechargeError = '充值信息加载失败，请重试');
    }
  }

  Future<void> submitManualRecharge() async {
    await ensureCurrentScope();
    rechargeOp ??=
        await store.begin('recharge', {'amount': manualAmount(amount.text)});
    final result = await widget.client.submitRecharge(
      amountUsdt: rechargeOp!['amount'] as String,
      idempotencyKey: rechargeOp!['key'] as String,
    );
    await ensureCurrentScope();
    rechargeOp = {...rechargeOp!, 'id': result['id']};
    await store.save('recharge', rechargeOp!);
    rechargeHistory = [
      result,
      ...rechargeHistory.where((row) => row['id'] != result['id'])
    ];
  }

  Future<void> cancelManualRecharge(String id) async {
    await ensureCurrentScope();
    // Cancellation is not replayable. Always reconcile the authoritative list
    // after success or an uncertain response before another user action.
    try {
      await widget.client.cancelRecharge(id);
    } finally {
      await loadRecharges();
    }
  }

  Future<void> cancelLegacyDeposit() async {
    await ensureCurrentScope();
    final current = deposit;
    if (current == null || current.status != ManualIntentState.open) return;
    final command = await store.begin('deposit_cancel', {'id': current.id});
    if (command['id'] != current.id) {
      throw StateError('请先刷新确认上一笔充值申请状态');
    }
    depositCancellationPending = true;
    final result =
        await api.cancelDepositIntent(current.id, command['key'] as String);
    await ensureCurrentScope();
    deposit = result;
    depositCancellationPending = false;
    watchDepositDeadline();
  }

  Future<void> loadReferenceFx() async {
    try {
      final snapshot = await widget.client.fxRate();
      final rate = snapshot['rate'];
      if (rate is! String ||
          _referenceUnits(rate) == null ||
          _referenceUnits(rate) == BigInt.zero) {
        throw const FormatException('参考汇率不可用');
      }
      if (!mounted) return;
      setState(() {
        referenceFx = snapshot;
        referenceFxError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => referenceFxError = '参考汇率暂不可用，实际结算以客服确认为准');
    }
  }

  // Reference display only: fixed 18-place integers avoid binary floating point.
  // These estimates never enter a request, quote, balance or ledger calculation.
  static BigInt? _referenceUnits(String value) {
    if (!RegExp(r'^(0|[1-9][0-9]{0,23})(\.[0-9]{1,18})?$').hasMatch(value)) {
      return null;
    }
    final parts = value.split('.');
    return BigInt.parse(
        parts.first + (parts.length == 2 ? parts.last : '').padRight(18, '0'));
  }

  String? get referenceEstimate {
    final input = amount.text.trim().isNotEmpty
        ? amount.text.trim()
        : deposit?.expectedAmount ?? '';
    final inputUnits = _referenceUnits(input);
    final rate = referenceFx?['rate'];
    final rateUnits = rate is String ? _referenceUnits(rate) : null;
    if (inputUnits == null || rateUnits == null || rateUnits <= BigInt.zero) {
      return null;
    }
    final payoutReference = widget.section == ManualWalletSection.payout;
    final digits = payoutReference ? 6 : 2;
    final scale = BigInt.from(10).pow(18);
    final displayScale = BigInt.from(10).pow(digits);
    final numerator = payoutReference
        ? inputUnits * displayScale
        : inputUnits * rateUnits * displayScale;
    final denominator = payoutReference ? rateUnits : scale * scale;
    final rounded = (numerator + denominator ~/ BigInt.two) ~/ denominator;
    final text = rounded.toString().padLeft(digits + 1, '0');
    return '${text.substring(0, text.length - digits)}.${text.substring(text.length - digits)}';
  }

  Widget referenceFxCard() => rowsCard([
        detail('点钻计价', '1 点钻 = ¥1.00'),
        if (referenceFx?['rate'] is String)
          detail('参考汇率', '1 USDT ≈ ¥${referenceFx!['rate']}'),
        if (referenceEstimate != null)
          detail(
              widget.section == ManualWalletSection.payout
                  ? '参考可兑 USDT'
                  : '预计到账点钻',
              '≈ $referenceEstimate ${widget.section == ManualWalletSection.payout ? 'USDT' : '点钻'}'),
        detail(
            '结算说明',
            referenceFxError ??
                (referenceFx?['stale'] == true
                    ? '参考汇率已过期，实际结算以客服确认为准'
                    : '参考估算，最终以客服结算为准')),
      ]);

  /// 距离上次改绑未满 30 天：服务端会拒绝，界面必须先讲清楚而不是让用户撞错。
  bool get rebindCoolingDown {
    final next = binding?.nextRebindAt;
    return next != null && widget.clock().isBefore(next);
  }

  bool get activeBinding =>
      ready &&
      capabilitiesKnown &&
      bindingFresh &&
      binding?.status == ManualBindingState.active;
  bool get canDeposit =>
      !busy &&
      ready &&
      capabilitiesKnown &&
      (cnyPricing || (activeBinding && depositEnabled));
  bool get canWithdraw =>
      !busy &&
      activeBinding &&
      payoutEnabled &&
      executionEnabled &&
      pointsPayoutEnabled;

  /// 是否已有可展示的本地数据（进入态快照）。有数据时所有"刷新"都按缓存优先处理：
  /// 不显示整页 busy、失败不弹错、数据不清空。
  bool get hasLocalData => entry?.state.hasData ?? false;
  Timer? depositDeadline;
  Timer? bindingCountdown;
  Timer? balanceRefresh;
  Future<void>? balanceLoad;
  bool showBindingDetails = false;

  /// 当前报价绑定的输入金额：金额被改过之后旧报价不得再用于提交。
  String? quoteInputAmount;
  bool savingQr = false;
  String? dismissingNotice;

  /// 终局失败：用同一份草稿重试永远不会成功，必须立刻释放输入框。
  static const _terminalBindingFailures = {
    'WALLET_ADDRESS_OWNED',
    'WALLET_ADDRESS_INVALID',
    'WALLET_ALREADY_BOUND',
    'WALLET_REBIND_TOO_SOON',
    'WALLET_BINDING_PENDING',
    'WALLET_WITHDRAWAL_IN_PROGRESS',
    'WALLET_ACCOUNT_RESTRICTED',
    'WALLET_ADDRESS_REGISTRATION_DISABLED',
    'WALLET_BINDING_VERSION_CONFLICT',
  };
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
    WidgetsBinding.instance.addObserver(this);
    if (widget.section == ManualWalletSection.overview ||
        widget.section == ManualWalletSection.payout) {
      balanceRefresh = Timer.periodic(const Duration(seconds: 15), (_) {
        if (!mounted ||
            !ready ||
            busy ||
            balanceLoad != null ||
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed ||
            ModalRoute.of(context)?.isCurrent != true) {
          return;
        }
        unawaited(refreshVisibleBalance());
      });
    }
    unawaited(_bootstrap());
  }

  /// 进入钱包：**先展示缓存 → 再后台刷新**（不再「先清空再等接口」）。
  ///
  /// 本地部分（作用域、草稿、提醒设置）必须先就位，因此放在 [run] 里以复用
  /// 既有错误提示；网络部分走 [WalletEntryStore.enter]：命中缓存时立即渲染
  /// 缓存数据并在后台刷新，不再让整页进入 busy 禁用态（按钮/余额不再闪）。
  Future<void> _bootstrap() async {
    await run(() async {
      walletScope = await widget.client.walletIntentScope();
      paymentScope = await widget.client.paymentIntentScope();
      final shared =
          WalletEntryStores.of(scope: walletScope!, gateway: _entryGateway);
      entry = shared;
      shared.view.addListener(_applyEntryState);
      _applyEntryState(); // 命中缓存：能力配置/余额立刻就位，不等网络
      await store.initialize();
      await payoutStatusStore.initialize();
      try {
        await noticeStore.initialize();
        ignoredDepositNotice = await noticeStore.ignoredIdentity('deposit');
        ignoredPayoutNotice = await noticeStore.ignoredIdentity('payout');
      } catch (_) {
        // 提醒设置不可用不阻塞钱包主流程：提醒照常展示（不静默丢失），
        // 「不再通知」保存失败时会显式报错。
      }
      bindingOp = await store.read('binding');
      depositOp = await store.read('deposit');
      quoteOp = await store.read('quote');
      payoutOp = await store.read('payout');
      if (!mounted) return;
      address.text = bindingOp?['address'] as String? ?? '';
      amount.text = (widget.section == ManualWalletSection.deposit
              ? depositOp
              : quoteOp)?['amount'] as String? ??
          '';
      ready = true; // 到这里才允许交互（本地读，毫秒级）
      setState(() {});
    });
    final shared = entry;
    if (!mounted || shared == null) return;
    // 有缓存时 enter() 立即返回、刷新在后台；无缓存时才等待首次加载。
    await shared.enter();
    if (!mounted) return;
    // 快照刚由 enter() 取回：这里的 refresh 只补绑定状态与草稿恢复，
    // 不再重复请求一次能力配置/余额。
    await run(() => refresh(refreshEntry: false),
        cacheFirst: shared.state.hasData);
  }

  /// 命中缓存或后台刷新落地时，用快照刷新能力配置与点钻余额。
  ///
  /// **没有数据时绝不清空已有显示**（余额变 `—`、错误条闪现的根因）；只有
  /// 「从未成功过」的失败（[WalletEntryState.fatalError]）才允许提示。
  void _applyEntryState() {
    final state = entry?.state;
    final snapshot = state?.data;
    if (snapshot != null) {
      final config = snapshot['config'];
      if (config is Map) {
        cnyPricing = config['caibi_pricing_version'] == 'caibi-cny-v1';
        depositEnabled = config['funding_enabled'] == true;
        payoutEnabled = config['manual_payout_enabled'] == true;
        executionEnabled = config['manual_payout_execution_enabled'] == true;
        conversionEnabled = config['conversion_enabled'] == true;
        pointsPayoutEnabled = config['caibi_payout_enabled'] == true &&
            (cnyPricing || conversionEnabled);
        capabilitiesKnown = true;
        capabilitiesUnavailable = false;
        addressOnly = config['user_auth_mode'] == 'address_only';
      }
      final balance = snapshot['caibi_available'];
      if (balance is String) {
        try {
          pointsAvailable = pointsText(balance);
          pointsError = null;
        } on FormatException {
          // 服务端返回的余额不合法：必须可见，不能静默沿用旧值。
          pointsError = '点钻余额加载失败，请刷新重试';
        }
      } else {
        pointsError = '点钻余额加载失败，请刷新重试';
      }
    }
    if (state != null) {
      if (state.fatalError) {
        // 唯一允许提示的失败：从未成功过、没有任何数据可展示。
        capabilitiesUnavailable = !capabilitiesKnown;
        pointsError ??= '点钻余额加载失败，请刷新重试';
      } else if (state.hasData) {
        capabilitiesUnavailable = false;
      }
    }
    // 绑定状态：本地快照优先。断网时「绑定地址与钱包信息」必须仍可见，且
    // activeBinding（进而充值/提现入口）不能因为一次网络失败整体失效。
    if (!bindingFresh && snapshot != null) {
      final cachedBinding = snapshot['binding'];
      if (cachedBinding is Map) {
        try {
          binding = ManualBindingStatus.fromJson(
              Map<String, dynamic>.from(cachedBinding));
          bindingFresh = true;
        } catch (_) {
          // 快照损坏：保持未刷新，交给接下来的网络刷新。
        }
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> refresh({bool refreshEntry = true}) async {
    await ensureCurrentScope();
    bindingFresh = false;
    depositOp = await store.read('deposit');
    final cancelOp = await store.read('deposit_cancel');
    depositCancellationPending =
        cancelOp != null && cancelOp['id'] == depositOp?['id'];
    quoteOp = await store.read('quote');
    payoutOp = await store.read('payout');
    if (depositOp == null) deposit = null;
    if (widget.section == ManualWalletSection.deposit &&
        depositOp?['id'] != null) {
      depositDeadline?.cancel();
      depositDeadline = null;
      deposit = null;
      if (mounted) setState(() {});
    }
    if (quoteOp == null && payoutOp == null) quote = null;
    if (payoutOp == null) payout = null;
    // 能力配置 + 点钻余额：统一走进入态 Store（缓存优先 + 后台刷新）。
    // 有缓存时刷新失败只留弱失败信号：保留数据、不显示错误条、不闪。
    if (refreshEntry) await entry?.refresh();
    _applyEntryState();
    binding = await api.bindingStatus();
    bindingFresh = true;
    if (bindingOp != null &&
        (binding!.pendingId != null ||
            binding!.version > (bindingOp!['version'] as int))) {
      await store.clear('binding');
      bindingOp = null;
      challenge = null;
    }
    if (widget.section == ManualWalletSection.deposit &&
        depositOp?['id'] != null) {
      deposit = await api.depositIntent(depositOp!['id'] as String);
      watchDepositDeadline();
    }
    if (widget.section == ManualWalletSection.payout &&
        payoutOp?['id'] != null) {
      final payoutId = payoutOp!['id'].toString();
      // 本地优先 / 立即展示：本次申请的状态卡先用上次成功的快照渲染（断网冷启动
      // 也能看到「管理员人工付款处理中 / 订单 / 提现 USDT」），再后台刷新。
      if (payout == null || payout!.id != payoutId) {
        final cached = await payoutStatusStore.read(payoutId);
        if (cached != null && mounted) {
          setState(() => payout = cached);
        }
      }
      try {
        final fresh = await api.payout(payoutId);
        payout = fresh;
        await payoutStatusStore.save(fresh);
      } catch (_) {
        // 失败不覆盖：有本地状态卡就保留它；没有本地数据时保持原行为
        // （异常继续上抛，由 run() 统一呈现失败）。
        if (payout == null) rethrow;
      }
    }
    if (widget.section == ManualWalletSection.payout && payout == null) {
      final quoteId = payoutOp?['quote_id'] ?? quoteOp?['id'];
      if (quoteId is String) {
        quote = await api.payoutQuote(quoteId);
        adoptQuoteAmount();
        if (payoutOp == null && !widget.clock().isBefore(quote!.expiresAt)) {
          await clearDefinitivelyInvalidPayout();
        }
      }
    }
    // 点钻余额已由进入态快照应用（见 _applyEntryState）：此处不再单独请求，
    // 避免「先清空再等接口」造成的余额/错误条闪烁。
    if (cnyPricing && widget.section == ManualWalletSection.deposit) {
      await loadRecharges();
    }
    if (!referenceFxRequested &&
        (widget.section == ManualWalletSection.deposit ||
            widget.section == ManualWalletSection.payout)) {
      referenceFxRequested = true;
      unawaited(loadReferenceFx());
    }
  }

  /// 记录报价绑定的输入金额；若输入框为空（例如服务端恢复的报价）则补齐。
  ///
  /// 已有绑定时不因刷新而改写：否则用户改了金额再刷新，旧报价会重新「匹配」。
  void adoptQuoteAmount() {
    final loaded = quote;
    if (loaded == null) return;
    if (quoteInputAmount != null) return;
    final current = normalizedPayoutInput();
    if (current != null) {
      quoteInputAmount = current;
      return;
    }
    final raw =
        loaded.fundingAsset == 'CAIBI' ? loaded.fundingAmount : loaded.amount;
    amount.text = raw;
    quoteInputAmount = normalizedPayoutInput() ?? raw;
  }

  /// 当前输入框金额归一化后的值；非法输入返回 null（不得用于任何提交）。
  String? normalizedPayoutInput() {
    try {
      return manualAmount(pointsText(amount.text));
    } catch (_) {
      return null;
    }
  }

  /// 报价是否仍然对应当前输入金额。用户在确认前可以随时改金额，改过之后旧报价
  /// 一律不得再用于展示或提交（提交以最终输入为准）。
  bool get payoutQuoteMatchesInput {
    final bound = quoteInputAmount;
    if (bound == null) return true;
    return normalizedPayoutInput() == bound;
  }

  Future<void> ensureCurrentScope() async {
    if (walletScope == null ||
        paymentScope == null ||
        await widget.client.walletIntentScope() != walletScope ||
        await widget.client.paymentIntentScope() != paymentScope) {
      bindingFresh = false;
      pointsAvailable = null;
      throw StateError('登录状态已变化，请重新打开钱包');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        mounted &&
        ready &&
        !busy &&
        ModalRoute.of(context)?.isCurrent == true) {
      unawaited(run(refresh, cacheFirst: hasLocalData));
    }
  }

  /// CAIBI stays decimal text throughout the form; zero-only extra precision
  /// from old USDT-shaped drafts may be displayed without rounding.
  String pointsText(String value) {
    final match = RegExp(r'^(0|[1-9][0-9]{0,23})(?:\.([0-9]{1,6}))?$')
        .firstMatch(value.trim());
    if (match == null) throw const FormatException('点钻金额格式不正确');
    final fraction = match.group(2) ?? '';
    if (fraction.length > 2 &&
        fraction.substring(2).contains(RegExp('[1-9]'))) {
      throw const FormatException('点钻金额最多两位小数，请重新填写');
    }
    return '${match.group(1)}.${fraction.padRight(2, '0').substring(0, 2)}';
  }

  Future<void> refreshVisibleBalance() async {
    await loadPointsBalance();
    if (mounted) setState(() {});
  }

  Future<void> loadPointsBalance() async {
    final existing = balanceLoad;
    if (existing != null) return existing;
    final loading = readPointsBalance();
    balanceLoad = loading;
    try {
      await loading;
    } finally {
      if (identical(balanceLoad, loading)) balanceLoad = null;
    }
  }

  /// 刷新点钻余额（「重新加载余额」按钮 / 余额兜底路径）。
  ///
  /// 缓存优先：成功才更新，失败保留旧值（有钱包快照时绝不把余额清空或弹错）。
  Future<void> readPointsBalance() async {
    final shared = entry;
    if (walletScope == null || shared == null) {
      throw StateError('账户尚未就绪');
    }
    await ensureCurrentScope(); // 作用域校验仍在，失败照旧报错
    await shared.refresh();
    _applyEntryState();
    final value = shared.state.data?['caibi_available'];
    if (value is String && !shared.state.fatalError) {
      return; // 快照已由 _applyEntryState 写入
    }
    pointsAvailable = null;
    pointsError = '点钻余额加载失败，请刷新重试';
  }

  Future<void> fillAll() async {
    if (payoutOp != null ||
        !activeBinding ||
        !payoutEnabled ||
        !executionEnabled ||
        !pointsPayoutEnabled) {
      return;
    }
    await loadPointsBalance();
    if (pointsAvailable == null) throw StateError(pointsError!);
    if (mounted) amount.text = pointsAvailable!;
  }

  Future<void> openSection(ManualWalletSection section,
      {bool recover = false}) async {
    // Disabled shortcuts never navigate or issue an HTTP request.
    final existing = section == ManualWalletSection.deposit
        ? depositOp != null
        : quoteOp != null || payoutOp != null;
    if (!recover || !existing) {
      if (section == ManualWalletSection.deposit && !canDeposit) return;
      if (section == ManualWalletSection.payout && !canWithdraw) return;
    }
    if (busy || !ready) return;
    await Navigator.of(context).push(MotionPageRoute<void>(
        builder: (_) => ManualWalletPage(
            client: widget.client,
            clock: widget.clock,
            section: section,
            qrExporter: widget.qrExporter)));
    if (mounted) await run(refresh, cacheFirst: hasLocalData);
  }

  Future<void> run(Future<void> Function() action,
      {bool cacheFirst = false}) async {
    if (busy) return;
    if (!cacheFirst) {
      setState(() {
        busy = true;
        message = null;
        messageIsWarning = false;
      });
    }
    try {
      if (ready) await ensureCurrentScope();
      await action();
    } catch (error) {
      // 有缓存的后台刷新失败：保留数据，不弹错误（弱失败信号由 entry 状态持有）。
      if (cacheFirst && (entry?.state.hasData ?? false)) return;
      messageIsWarning = true;
      const explanations = {
        'WALLET_ADDRESS_INVALID': '地址格式不正确，请填写有效的 TRON 地址并检查是否复制完整。',
        'WALLET_ADDRESS_OWNED': '该地址已被其他账号登记，请更换一个属于你的钱包地址。',
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
        if (!cacheFirst) {
          otp.clear();
          signature.clear();
          oldSignature.clear();
          setState(() => busy = false);
        }
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
    final ManualBindingConfirmation result;
    try {
      result = await api.registerAddress(
          address: bindingOp!['address'] as String,
          expectedVersion: bindingOp!['version'] as int,
          idempotencyKey: bindingOp!['key'] as String);
    } catch (error) {
      // 终局校验失败（地址已被他人登记、格式错误、未满 30 天、有待处理提现…）：
      // 这份草稿重试多少次都不会成功，继续保留会把地址输入框永久锁死
      // （真机 BUG：被拒地址删不掉、一直提示「已被其他账号登记」）。
      // 网络/超时等不确定失败仍保留草稿，以便用同一幂等键安全重试。
      if (error is BusinessApiException &&
          _terminalBindingFailures.contains(error.code)) {
        await discardBindingDraft();
      }
      rethrow;
    }
    bindingOp = {...bindingOp!, 'id': result.id};
    await store.save('binding', bindingOp!);
    await refresh();
    message = binding?.status == ManualBindingState.active
        ? '钱包地址已保存'
        : '地址已登记，正在同步链上起始位置，请稍后刷新。';
  }

  /// 丢弃尚未产生服务端结果的登记草稿，把地址输入框还给用户。
  Future<void> discardBindingDraft() async {
    await store.clear('binding');
    bindingOp = null;
    challenge = null;
    if (mounted) setState(() {});
  }

  Future<void> createDeposit() async {
    if (depositOp == null && (!activeBinding || !depositEnabled)) {
      throw StateError('充值暂不可用，请刷新钱包状态');
    }
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
    // 金额被改过：旧报价不再对应当前输入，丢弃后按最终金额重新报价
    // （不重放旧报价，也不允许用旧报价提交）。
    if (quoteOp?['id'] is String && !payoutQuoteMatchesInput) {
      await store.clear('quote');
      quoteOp = null;
      quote = null;
      quoteInputAmount = null;
    }
    if (quoteOp == null) {
      if (!activeBinding ||
          !payoutEnabled ||
          !executionEnabled ||
          !pointsPayoutEnabled) {
        throw StateError('提现暂不可用，请刷新钱包状态');
      }
      final value = pointsText(amount.text);
      final normalized = manualAmount(value);
      await loadPointsBalance();
      if (pointsAvailable == null) throw StateError(pointsError!);
      if (BigInt.parse(value.replaceAll('.', '')) >
          BigInt.parse(pointsAvailable!.replaceAll('.', ''))) {
        throw const FormatException('点钻余额不足');
      }
      quoteOp = await store.begin('quote', {
        'amount': normalized,
        'version': binding!.version,
        'funding_asset': 'CAIBI'
      });
    }
    if (quoteOp!['id'] is String) {
      quote = await api.payoutQuote(quoteOp!['id'] as String);
      adoptQuoteAmount();
      return;
    }
    quote = await api.createPayoutQuote(
        amount: quoteOp!['amount'] as String,
        fundingAsset: quoteOp!['funding_asset'] as String? ?? 'USDT',
        expectedBindingVersion: quoteOp!['version'] as int,
        idempotencyKey: quoteOp!['key'] as String);
    quoteOp = {
      ...quoteOp!,
      'id': quote!.id,
      'funding_asset': quote!.fundingAsset
    };
    await store.save('quote', quoteOp!);
    quoteInputAmount = quoteOp!['amount'] as String?;
  }

  String maskedAddress(String value) => value.length <= 12
      ? value
      : '${value.substring(0, 6)}…${value.substring(value.length - 6)}';

  Future<void> recordPayout() async {
    payoutOp = {...payoutOp!, 'id': payout!.id};
    await store.save('payout', payoutOp!);
    await loadPointsBalance();
  }

  Future<void> clearDefinitivelyInvalidPayout() async {
    await store.clear('payout');
    await store.clear('quote');
    payoutOp = quoteOp = null;
    payout = null;
    quote = null;
    quoteInputAmount = null;
  }

  Future<void> requestPayout() async {
    await ensureCurrentScope();
    final quoteId = payoutOp?['quote_id'] ?? quote?.id ?? quoteOp?['id'];
    if (quoteId is! String) throw StateError('请先获取提现报价');
    final recovering = payoutOp != null;
    if (recovering) {
      // The server resolves successful same-key replay before requiring PIN.
      // Without proof it cannot create a new financial operation.
      try {
        payout = await api.createPayout(
            quoteId: quoteId,
            expectedPaymentScope: paymentScope,
            idempotencyKey: payoutOp!['key'] as String);
        await recordPayout();
        return;
      } on BusinessApiException catch (error) {
        if ({'WALLET_PAYOUT_QUOTE_EXPIRED', 'WALLET_PAYOUT_QUOTE_CHANGED'}
            .contains(error.code)) {
          await clearDefinitivelyInvalidPayout();
        }
        if (!{'PAYMENT_PIN_REQUIRED', 'PAYMENT_PIN_SETUP_REQUIRED'}
            .contains(error.code)) {
          rethrow;
        }
      }
    }
    if (!addressOnly && otp.text.trim().isEmpty) {
      throw const FormatException('请输入当前六位验证码');
    }
    // Display only immutable server quote data, never an edited amount or
    // a newly rebound destination from the current wallet card.
    quote = await api.payoutQuote(quoteId);
    if (!widget.clock().isBefore(quote!.expiresAt)) {
      await clearDefinitivelyInvalidPayout();
      throw const FormatException('本次报价已过期，请重新填写金额');
    }
    if (!mounted) return;
    await ensureCurrentScope();
    payoutOp = await store.begin('payout', {'quote_id': quoteId});
    if (!mounted) return;
    final proof = await authorizeWalletPayment(context,
        api: widget.client,
        action: 'wallet.payout.create',
        payload: {'quote_id': quoteId},
        idempotencyKey: payoutOp!['key'] as String,
        amount:
            '${quote!.fundingAmount} ${quote!.fundingAsset == 'CAIBI' ? '点钻' : 'USDT'}',
        recipient: maskedAddress(quote!.targetAddress),
        expectedWalletScope: walletScope!);
    if (proof == null) {
      if (!recovering) {
        await store.clear('payout');
        payoutOp = null;
      }
      return;
    }
    await ensureCurrentScope();
    if (proof.walletScope != walletScope ||
        proof.sessionScope != paymentScope) {
      throw StateError('登录状态已变化，请重新打开钱包');
    }
    try {
      payout = await api.createPayout(
          quoteId: payoutOp!['quote_id'] as String,
          mfaProof: addressOnly ? null : otp.text.trim(),
          paymentAuthorization: proof.authorization,
          expectedPaymentScope: proof.sessionScope,
          idempotencyKey: payoutOp!['key'] as String);
    } on BusinessApiException catch (error) {
      if ({'WALLET_PAYOUT_QUOTE_EXPIRED', 'WALLET_PAYOUT_QUOTE_CHANGED'}
          .contains(error.code)) {
        await clearDefinitivelyInvalidPayout();
      }
      rethrow;
    }
    await recordPayout();
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
      await loadPointsBalance();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    depositDeadline?.cancel();
    bindingCountdown?.cancel();
    balanceRefresh?.cancel();
    // 共享 Store 的持有者是 WalletEntryStores（会话级），页面只退订，绝不 dispose。
    entry?.view.removeListener(_applyEntryState);
    for (final field in [address, amount, signature, oldSignature, otp]) {
      field.dispose();
    }
    super.dispose();
  }

  /// 「不再通知」：把**这一笔申请的身份**持久化忽略；出现新的一笔（身份不同）
  /// 时提醒自然重新出现。保存失败必须可见，不得假装成功。
  Future<void> dismissNotice(String kind, String identity) async {
    if (dismissingNotice != null) return;
    setState(() => dismissingNotice = kind);
    try {
      await noticeStore.ignore(kind, identity);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        messageIsWarning = true;
        message =
            error is StateError ? error.message.toString() : '无法保存提醒设置，请稍后重试';
      });
      return;
    } finally {
      if (mounted) setState(() => dismissingNotice = null);
    }
    if (!mounted) return;
    setState(() {
      if (kind == 'deposit') {
        ignoredDepositNotice = identity;
      } else {
        ignoredPayoutNotice = identity;
      }
      messageIsWarning = false;
      message = '已不再提醒这笔申请；出现新的申请时会再次提醒';
    });
  }

  /// 保存收款二维码到系统相册：申请权限 → 渲染 PNG → 写入相册，成败都可见。
  Future<void> saveDepositQr() async {
    final current = deposit;
    if (current == null || savingQr) return;
    setState(() {
      savingQr = true;
      message = null;
      messageIsWarning = false;
    });
    try {
      await widget.qrExporter.saveQrCode(current.officialAddress);
      if (!mounted) return;
      message = '收款二维码已保存到相册';
    } catch (error) {
      if (!mounted) return;
      messageIsWarning = true;
      message = walletQrExportErrorMessage(error);
    } finally {
      if (mounted) setState(() => savingQr = false);
    }
  }

  Widget button(String text, Future<void> Function() action,
      {String? key, bool enabled = true}) {
    final onPressed = busy || !ready || !enabled ? null : () => run(action);
    // 没有背景色的动作按钮必须有边框：否则用户难以分辨按钮与普通文本。
    if (key == null) {
      return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: WeChatSecondaryButton(label: text, onPressed: onPressed));
    }
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: CupertinoButton(
            color: WeChatColors.brandPrimary,
            borderRadius: BorderRadius.circular(8),
            onPressed: onPressed,
            key: Key(key),
            child: Text(text,
                style: onPressed != null
                    ? const TextStyle(color: CupertinoColors.white)
                    : null)));
  }

  Widget field(String name, TextEditingController controller, String hint,
          {bool secret = false, bool enabled = true}) =>
      Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: CupertinoTextField(
              key: Key(name),
              controller: controller,
              onChanged:
                  identical(controller, amount) ? (_) => setState(() {}) : null,
              placeholder: hint,
              enabled: enabled && !busy,
              obscureText: secret,
              autocorrect: false,
              enableSuggestions: false,
              padding: const EdgeInsets.all(14)));
  Widget copyIcon(String value, String key,
          {bool enabled = true,
          bool Function()? canCopy,
          String label = '复制地址',
          String copiedMessage = '地址已复制'}) =>
      Semantics(
          label: label,
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
                        message = copiedMessage;
                      }),
              child: const Icon(CupertinoIcons.doc_on_doc, size: 20)));

  /// 地址行：[label] 定宽左对齐，地址**压缩展示**后靠左对齐，复制 icon 右端对齐。
  ///
  /// 复制动作始终使用 [value]（完整地址）；展示用压缩值，因此不同长度的地址都
  /// 落在同一列、复制 icon 不再错位。
  Widget addressRow(String label, String value, String key,
          {bool Function()? canCopy}) =>
      Padding(
          // 与 detail() 单元格同一水平内边距：地址列与其它单元格对齐。
          padding: const EdgeInsets.symmetric(
              horizontal: WeChatSpacing.lg, vertical: 8),
          child: Row(children: [
            SizedBox(
                width: 72,
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 13, color: WeChatColors.textSecondary))),
            Expanded(
                child: Text(compactWalletAddress(value),
                    key: Key('$key-display'),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                    textAlign: TextAlign.left,
                    style: TextStyle(
                        fontSize: 13,
                        color: WeChatColors.resolveTextPrimary(context)))),
            copyIcon(value, key, canCopy: canCopy),
          ]));

  /// 订单/校验码行：字号更小 + 复制完整值（替代原「查看详情」折叠按钮）。
  Widget codeRow(String label, String value, String key) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        SizedBox(
            width: 72,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 13, color: WeChatColors.textSecondary))),
        Expanded(
            child: Text(compactWalletCode(value),
                key: Key('$key-display'),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                textAlign: TextAlign.left,
                style: TextStyle(
                    fontSize: WeChatTypography.caption,
                    color: WeChatColors.resolveTextPrimary(context)))),
        copyIcon(value, key, label: '复制订单码', copiedMessage: '订单码已复制'),
      ]));

  /// 带图形 icon 的次级动作按钮（与 [WeChatSecondaryButton] 同一套 token）。
  Widget iconActionButton(
      {required Key key,
      required IconData icon,
      required String label,
      required VoidCallback? onPressed,
      bool loading = false}) {
    final enabled = onPressed != null;
    final tone =
        enabled ? WeChatColors.brandPrimary : WeChatColors.textTertiary;
    return Semantics(
        button: true,
        enabled: enabled,
        label: label,
        child: Container(
            decoration: BoxDecoration(
                border: Border.all(
                    color: enabled
                        ? WeChatColors.controlBorder
                        : WeChatColors.resolve(context, WeChatColors.divider)),
                borderRadius: BorderRadius.circular(WeChatRadius.actionButton)),
            child: CupertinoButton(
                key: key,
                padding: const EdgeInsets.symmetric(
                    horizontal: WeChatSpacing.actionButtonHorizontal,
                    vertical: 10),
                minimumSize:
                    const Size.square(WeChatDimensions.minimumTouchTarget),
                onPressed: onPressed,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (loading)
                    const CupertinoActivityIndicator(radius: 8)
                  else
                    Icon(icon, size: 18, color: tone),
                  const SizedBox(width: WeChatSpacing.actionButtonIconGap),
                  Text(label,
                      style: TextStyle(
                          fontSize: WeChatTypography.callout, color: tone)),
                ]))));
  }

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

  /// 三步指示器（充值/提现共用）：与 design-demo 的「填写金额 → 转账/确认报价 → 到账」一致。
  ///
  /// 点击「下一步」后**保留**，并用 [AnimatedContainer] 做进度过渡：已完成步骤
  /// 高亮 + 勾号，当前步骤高亮，未完成步骤次级色。系统「减少动态效果」开启时
  /// 过渡时长归零（[MediaQuery.disableAnimationsOf]）。
  Widget stepIndicator(List<String> steps, int current,
          {String keyPrefix = 'manual-wallet-step'}) =>
      walletStepIndicator(context, steps, current, keyPrefix: keyPrefix);

  /// 状态主卡：金额/状态/倒计时是这一屏的主语（design-demo 的 status-hero）。
  Widget statusHero({
    required IconData icon,
    required String amount,
    String unit = 'USDT',
    required String subtitle,
    String? countdown,
    Color tone = WeChatColors.brandPrimary,
    String? key,
  }) =>
      Container(
          key: key == null ? null : Key(key),
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
              color: WeChatColors.elevatedSurface(context),
              borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: tone.withValues(alpha: 0.10),
                    shape: BoxShape.circle),
                child: Icon(icon, size: 26, color: tone)),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              // 极端金额（测试与真实上限都可能很长）必须缩放而不是溢出。
              Flexible(
                  child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(amount,
                          maxLines: 1,
                          style: const TextStyle(
                              fontSize: 32, fontWeight: FontWeight.w700)))),
              const SizedBox(width: 4),
              Text(unit,
                  style: const TextStyle(
                      fontSize: 14, color: WeChatColors.textSecondary)),
            ]),
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13, color: WeChatColors.textSecondary)),
            if (countdown != null) ...[
              const SizedBox(height: 10),
              Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                      color: WeChatColors.warning.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999)),
                  child: Text(countdown,
                      style: const TextStyle(
                          fontSize: 12,
                          color: WeChatColors.warning,
                          fontFeatures: [FontFeature.tabularFigures()]))),
            ],
          ]));

  /// 键值分组卡片：明细行成组呈现，避免散落的单行文本。
  Widget rowsCard(List<Widget> cells) => Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
          color: WeChatColors.elevatedSurface(context),
          borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var index = 0; index < cells.length; index++) ...[
          // §19：卡片内相邻区块的分隔线一律用共享渐隐分割线，
          // 不得再自建 Container + color 的实心线。
          if (index > 0) const WeChatGradientDivider(indent: WeChatSpacing.lg),
          cells[index],
        ],
      ]));

  Widget detail(String label, String value, {String? key}) => Padding(
      key: key == null ? null : Key(key),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(children: [
        Text(label,
            style: const TextStyle(
                fontSize: 14, color: WeChatColors.textSecondary)),
        const SizedBox(width: 12),
        Expanded(
            child: Text(value,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 15))),
      ]));

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
                    '仅支持 TRON 网络 USDT（TRC20）。充值与提现每笔最低 10 USDT。提现使用点钻余额，1 点钻 = 1 USDT，服务费为 0。请先绑定地址，再创建充值或提现申请。提现由管理员人工付款。地址每 30 天最多修改一次，请仔细核对。'),
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
    await Navigator.of(context).push(MotionPageRoute<void>(
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

  String get pageTitle => switch (widget.section) {
        ManualWalletSection.overview => '钱包',
        ManualWalletSection.binding =>
          binding?.status == ManualBindingState.active ? '更换钱包地址' : '绑定钱包',
        ManualWalletSection.deposit => '充值',
        ManualWalletSection.payout => '提现',
      };

  Widget refreshControl() => Semantics(
      label: '刷新状态',
      child: CupertinoButton(
          key: const Key('manual-refresh'),
          padding: EdgeInsets.zero,
          onPressed: busy ? null : () => run(refresh),
          child: busy
              ? const CupertinoActivityIndicator()
              : const Icon(CupertinoIcons.refresh, size: 22)));

  Widget overview() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          key: const Key('manual-wallet-summary'),
          padding: const EdgeInsets.all(20),
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
              color: WeChatColors.elevatedSurface(context),
              borderRadius: BorderRadius.circular(12)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(CupertinoIcons.creditcard,
                  color: WeChatColors.brandPrimary, size: 28),
              const SizedBox(width: 12),
              const Expanded(
                  child: Text('USDT · TRC20',
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w600))),
              Semantics(
                  label: binding?.status == ManualBindingState.active
                      ? '更改绑定'
                      : '绑定钱包地址',
                  child: CupertinoButton(
                      key: const Key('manual-wallet-rebind'),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      onPressed: busy ||
                              !ready ||
                              !bindingFresh ||
                              !capabilitiesKnown ||
                              binding?.bindingEnabled != true
                          ? null
                          : () => openSection(ManualWalletSection.binding),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(CupertinoIcons.pencil,
                            size: 16, color: WeChatColors.brandPrimary),
                        const SizedBox(width: 4),
                        Text(
                            binding?.status == ManualBindingState.active
                                ? '更改绑定'
                                : '绑定钱包',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: WeChatColors.brandPrimary)),
                      ]))),
            ]),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                  child: Text(binding?.maskedAddress ?? '请先绑定你的钱包地址',
                      key: const Key('manual-wallet-bound-address'),
                      style: TextStyle(
                          fontSize: 16,
                          color: WeChatColors.resolveTextPrimary(context)))),
              // 复制 icon 紧贴钱包地址本体（此前误放在「当前点钻余额」行）。
              if (binding?.address != null)
                copyIcon(binding!.address!, 'manual-current-copy'),
            ]),
            const SizedBox(height: 8),
            Text(
                switch (binding?.status) {
                  ManualBindingState.active => '已绑定',
                  ManualBindingState.pending => '地址正在同步，请稍后刷新',
                  _ => '绑定后可使用充值与提现',
                },
                style: const TextStyle(
                    fontSize: 13, color: WeChatColors.textSecondary)),
            if (binding?.nextRebindAt != null) ...[
              const SizedBox(height: 8),
              Text('下次可改绑：${shortDate(binding!.nextRebindAt!)}',
                  style: const TextStyle(
                      fontSize: 12, color: WeChatColors.textSecondary)),
            ],
            const SizedBox(height: 16),
            Text('当前点钻余额：${pointsAvailable ?? '—'}',
                style: const TextStyle(fontSize: 14)),
          ]),
        ),
        Row(children: [
          Expanded(
              child: fundingShortcut('充值', CupertinoIcons.arrow_down_circle,
                  ManualWalletSection.deposit, canDeposit)),
          const SizedBox(width: 12),
          Expanded(
              child: fundingShortcut('提现', CupertinoIcons.arrow_up_circle,
                  ManualWalletSection.payout, canWithdraw)),
        ]),
        const SizedBox(height: 8),
        const Text('仅支持 TRON 网络 · 1 点钻 = 1 USDT · 手续费 0',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: WeChatColors.textSecondary)),
        if (pointsError != null) warningBox(pointsError!),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(
              child: shortcut('交易记录', CupertinoIcons.list_bullet, showHistory)),
          const SizedBox(width: 12),
          Expanded(
              child:
                  shortcut('使用帮助', CupertinoIcons.question_circle, showHelp)),
        ]),
        // 「查看已有充值/提现申请」不再散落在卡片下方：统一由顶部导航栏下方的
        // 通知栏承担（见 noticeBars / 需求 14）。
      ]);

  /// 需要跟进的申请提醒身份（null = 没有）。
  String? get depositNotice => depositNoticeIdentity(depositOp);

  String? get payoutNotice => payoutNoticeIdentity(payoutOp, quoteOp);

  /// 顶部导航栏下方的通知栏：点击直达对应申请页，最右侧「不再通知」按
  /// **申请身份**持久化忽略（新的一笔会重新出现）。
  List<Widget> noticeBars() {
    final bars = <Widget>[];
    final depositId = depositNotice;
    if (depositId != null && depositId != ignoredDepositNotice) {
      bars.add(noticeBar(
          kind: 'deposit',
          identity: depositId,
          icon: CupertinoIcons.arrow_down_circle,
          label: '查看已有充值申请',
          open: () => openSection(ManualWalletSection.deposit, recover: true)));
    }
    final payoutId = payoutNotice;
    if (payoutId != null && payoutId != ignoredPayoutNotice) {
      bars.add(noticeBar(
          kind: 'payout',
          identity: payoutId,
          icon: CupertinoIcons.arrow_up_circle,
          label: '查看已有提现申请',
          open: () => openSection(ManualWalletSection.payout, recover: true)));
    }
    return bars;
  }

  Widget noticeBar(
          {required String kind,
          required String identity,
          required IconData icon,
          required String label,
          required Future<void> Function() open}) =>
      Container(
          key: Key('manual-$kind-notice'),
          margin: const EdgeInsets.fromLTRB(
              WeChatSpacing.lg, WeChatSpacing.md, WeChatSpacing.lg, 0),
          decoration: BoxDecoration(
              color: WeChatColors.brandTint,
              borderRadius: BorderRadius.circular(WeChatRadius.bubble)),
          child: Row(children: [
            Expanded(
                child: CupertinoButton(
                    key: Key('manual-$kind-notice-open'),
                    padding: const EdgeInsets.symmetric(
                        horizontal: WeChatSpacing.md,
                        vertical: WeChatSpacing.md),
                    // 直接导航（不能包进 run：run 会先置 busy，openSection 的
                    // busy 守卫会因此拒绝跳转）。
                    onPressed: busy || !ready ? null : () => unawaited(open()),
                    child: Row(children: [
                      Icon(icon, size: 18, color: WeChatColors.brandPrimary),
                      const SizedBox(width: WeChatSpacing.sm),
                      Expanded(
                          child: Text(label,
                              key: Key('manual-$kind-notice-label'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: WeChatTypography.subhead,
                                  fontWeight: FontWeight.w500,
                                  color: WeChatColors.resolveTextPrimary(
                                      context)))),
                      Icon(CupertinoIcons.chevron_right,
                          size: 14, color: WeChatColors.textSecondary),
                    ]))),
            Semantics(
                button: true,
                label: '不再通知',
                child: CupertinoButton(
                    key: Key('manual-$kind-notice-dismiss'),
                    padding: const EdgeInsets.all(WeChatSpacing.md),
                    minimumSize:
                        const Size.square(WeChatDimensions.minimumTouchTarget),
                    onPressed: busy || dismissingNotice != null
                        ? null
                        : () => dismissNotice(kind, identity),
                    child: dismissingNotice == kind
                        ? const CupertinoActivityIndicator(radius: 8)
                        : const Icon(CupertinoIcons.bell_slash,
                            size: 18, color: WeChatColors.textSecondary))),
          ]));

  Widget fundingShortcut(String label, IconData icon,
          ManualWalletSection section, bool enabled) =>
      CupertinoButton(
          key: Key(section == ManualWalletSection.deposit
              ? 'manual-deposit-open'
              : 'manual-payout-open'),
          padding: const EdgeInsets.symmetric(vertical: 20),
          color: WeChatColors.brandPrimary,
          disabledColor: CupertinoColors.systemGrey5.resolveFrom(context),
          borderRadius: BorderRadius.circular(12),
          onPressed: enabled ? () => openSection(section) : null,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon,
                size: 24,
                color: enabled
                    ? CupertinoColors.white
                    : WeChatColors.textSecondary),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: enabled
                        ? CupertinoColors.white
                        : WeChatColors.textSecondary)),
          ]));

  @override
  Widget build(BuildContext context) {
    final content = SafeArea(
        top: !widget.embedded,
        child: Column(children: [
          // 通知栏固定在顶部导航栏下方（不随列表滚动）。
          if (widget.section == ManualWalletSection.overview) ...noticeBars(),
          Expanded(
              child: ListView(
                  key: const Key('wallet-page-list'),
                  padding: const EdgeInsets.all(16),
                  children: [
                if (widget.embedded)
                  Align(
                      alignment: Alignment.centerRight,
                      child: refreshControl()),
                if (widget.section == ManualWalletSection.overview) overview(),
                if (capabilitiesUnavailable)
                  warningBox('功能状态暂不可用，请刷新；已有订单仍可查询。'),
                if (widget.section == ManualWalletSection.binding) ...[
                  if (!addressOnly)
                    CupertinoButton(
                        onPressed: busy
                            ? null
                            : () => Navigator.of(context).push(
                                MotionPageRoute<void>(
                                    builder: (_) =>
                                        ManualMfaPage(client: widget.client))),
                        child: const Text('设置身份验证器')),
                  if (binding?.bindingEnabled != true)
                    warningBox('绑定暂不可用，请联系管理员'),
                  card(addressOnly ? registrationFields() : bindingFields()),
                ],
                if (widget.section == ManualWalletSection.deposit)
                  card(depositFields()),
                if (widget.section == ManualWalletSection.payout)
                  card(payoutFields()),
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
        ]));
    if (widget.embedded) return content;
    return WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text(pageTitle),
            trailing: refreshControl()),
        child: content);
  }

  List<Widget> registrationFields() => [
        const Text('常用钱包地址',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
              child: field('manual-binding-address', address, '粘贴你的 TRON 地址',
                  // 只有服务端已经受理（拿到了 id）才锁定地址；被拒的草稿必须可改。
                  enabled: bindingOp?['id'] == null)),
          ValueListenableBuilder<TextEditingValue>(
              valueListenable: address,
              builder: (_, value, child) =>
                  copyIcon(value.text.trim(), 'manual-binding-copy')),
        ]),
        const Text('仅填本人地址 · 每 30 天可修改一次',
            style: TextStyle(fontSize: 13, color: WeChatColors.textSecondary)),
        if (rebindCoolingDown)
          warningBox(
              '距离上次修改未满 30 天，下次可修改时间：${shortDate(binding!.nextRebindAt!)}'),
        button(bindingOp == null ? '保存钱包地址' : '继续原地址登记', registerAddress,
            key: 'manual-register-address',
            enabled: capabilitiesKnown &&
                binding?.bindingEnabled == true &&
                !rebindCoolingDown),
        if (bindingOp?['id'] == null && bindingOp != null)
          button('重新填写钱包地址', discardBindingDraft),
      ];

  List<Widget> bindingFields() => [
        const Text('1 · 填写私人钱包地址',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Text('用于识别你的充值，并作为提现收款地址。每 30 天最多改绑一次。'),
        field('manual-binding-address', address, '私人 TRON 钱包地址',
            enabled: bindingOp?['id'] == null),
        if (bindingOp?['id'] != null)
          const Text('绑定结果尚未确认。先刷新状态；重试时粘贴与首次提交完全相同的签名。'),
        if (rebindCoolingDown)
          warningBox(
              '距离上次修改未满 30 天，下次可修改时间：${shortDate(binding!.nextRebindAt!)}'),
        button(bindingOp == null ? '开始验证钱包归属' : '恢复本次验证', createChallenge,
            enabled: binding?.bindingEnabled == true && !rebindCoolingDown,
            key: 'manual-challenge'),
        if (bindingOp != null && bindingOp?['id'] == null)
          button('重新填写钱包地址', discardBindingDraft),
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

  List<Widget> manualRechargeFields() => [
        stepIndicator(
            const ['填写金额', '客服处理', '到账'],
            rechargeOp?['id'] == null
                ? 0
                : rechargeHistory.any((row) =>
                        row['id'] == rechargeOp?['id'] &&
                        row['status'] == 'CREDITED')
                    ? 2
                    : 1,
            keyPrefix: 'manual-deposit-step'),
        referenceFxCard(),
        warningBox('请先联系官方客服确认收款信息。提交申请不代表到账。'),
        if (rechargeError != null) ...[
          warningBox(rechargeError!),
          button('重新加载充值信息', loadRecharges),
        ],
        for (final contact
            in rechargeContacts.where((row) => row['enabled'] == true))
          rowsCard([
            detail('官方客服', contact['display_name']?.toString() ?? ''),
            codeRow('客服账号', contact['cs_user_id']?.toString() ?? '',
                'recharge-contact-${contact['id']}'),
            if (contact['payment_address'] is String)
              addressRow('客服收款地址', contact['payment_address'] as String,
                  'recharge-address-${contact['id']}'),
            if (contact['note'] is String)
              detail('说明', contact['note'] as String),
          ]),
        if (rechargeContacts.isEmpty && rechargeError == null)
          const Text('暂无可用官方客服，请稍后重试'),
        field('manual-deposit-amount', amount, '充值金额 USDT',
            enabled: rechargeOp == null),
        if (rechargeOp?['id'] == null)
          button(rechargeOp == null ? '提交充值申请' : '重试同一申请', submitManualRecharge,
              enabled: ready &&
                  capabilitiesKnown &&
                  rechargeError == null &&
                  rechargeContacts.any((row) => row['enabled'] == true),
              key: 'manual-recharge-submit'),
        if (rechargeOp?['id'] != null)
          button('填写新的充值申请', () async {
            await store.clear('recharge');
            rechargeOp = null;
            amount.clear();
          }),
        for (final request in rechargeHistory)
          rowsCard([
            codeRow('申请单号', request['id'].toString(),
                'recharge-id-${request['id']}'),
            detail('充值 USDT', request['amount_usdt']?.toString() ?? '—'),
            if (request['final_caibi_amount'] is String)
              detail('最终到账点钻', request['final_caibi_amount'] as String),
            if (request['final_rate'] is String)
              detail('结算汇率', request['final_rate'] as String),
            detail(
                '状态',
                switch (request['status']) {
                  'SUBMITTED' => '待客服处理，尚未到账',
                  'CREDITED' => '已到账',
                  'CANCELLED' => '已取消',
                  'REJECTED' => '已拒绝',
                  _ => '状态待核验，请刷新',
                }),
            if (request['status'] == 'SUBMITTED')
              button(
                  '取消充值申请', () => cancelManualRecharge(request['id'] as String),
                  enabled: rechargeError == null,
                  key: 'recharge-cancel-${request['id']}'),
          ]),
      ];

  List<Widget> depositFields() => cnyPricing && depositOp == null
      ? manualRechargeFields()
      : [
          if (!activeBinding || !depositEnabled) warningBox('充值入账暂不可用，请勿转账。'),
          // 步骤指示器始终保留（有申请时停在「转账」步）。
          stepIndicator(const ['填写金额', '转账', '到账'],
              deposit == null ? 0 : (depositOpen ? 1 : 2),
              keyPrefix: 'manual-deposit-step'),
          referenceFxCard(),
          const Text('充值金额',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text('最低 10 USDT · 仅支持 TRC20',
              style:
                  TextStyle(fontSize: 13, color: WeChatColors.textSecondary)),
          field('manual-deposit-amount', amount, '充值金额',
              enabled: depositOp == null),
          if (deposit == null)
            rowsCard([
              detail('到账金额', '按实际转账金额入账'),
              detail('手续费', '0.00 USDT'),
              detail('到账网络', 'TRON（TRC20）'),
            ]),
          // 「查看本次充值」已删除：申请生成后由本页自动恢复展示（见 refresh）。
          // 只有「结果未确认」的草稿保留同键重试入口（幂等重试，不是查看）。
          if (depositOp == null ||
              (depositOp!['id'] == null && deposit == null))
            button(depositOp == null ? '下一步' : '重试本次充值', createDeposit,
                enabled: depositOp != null || (depositEnabled && activeBinding),
                key: 'manual-deposit-create'),
          if (deposit != null) ...[
            if (deposit!.status == ManualIntentState.open)
              statusHero(
                  key: 'manual-deposit-hero',
                  icon: CupertinoIcons.arrow_down_circle,
                  amount: deposit!.expectedAmount,
                  subtitle: depositCancellationPending
                      ? '取消结果待确认，请勿转账'
                      : '待转账 · 请向下方地址转入',
                  countdown: depositOpen
                      ? '有效期至 ${shortDate(deposit!.expiresAt)}'
                      : null),
            rowsCard([
              detail(
                  '状态',
                  switch (deposit!.status) {
                    ManualIntentState.open => '待转账',
                    ManualIntentState.expired => '已过期',
                    ManualIntentState.fulfilled => '已完成',
                    ManualIntentState.closedByRebind => '已关闭',
                    ManualIntentState.cancelled => '已取消',
                  }),
              detail('金额 USDT', deposit!.expectedAmount),
              addressRow('转出钱包', deposit!.sourceAddress, 'manual-source-copy'),
              detail('有效期', shortDate(deposit!.expiresAt)),
            ]),
            if (depositOpen &&
                depositEnabled &&
                activeBinding &&
                !depositCancellationPending) ...[
              // 需求 4：收款地址与上方文字信息之间必须有明显分割线，
              // 且只能使用仓库统一的渐隐分割线共享组件（§19）。
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: WeChatSpacing.md),
                  child: WeChatGradientDivider(
                      key: Key('manual-deposit-address-divider'))),
              rowsCard([
                addressRow(
                    '收款地址', deposit!.officialAddress, 'manual-official-copy',
                    canCopy: () =>
                        depositOpen && depositEnabled && activeBinding),
                Padding(
                    padding: const EdgeInsets.all(WeChatSpacing.lg),
                    child: Column(children: [
                      QrImageView(
                          key: const Key('manual-deposit-qr'),
                          data: deposit!.officialAddress,
                          size: 180,
                          backgroundColor: CupertinoColors.white),
                      const SizedBox(height: WeChatSpacing.md),
                      iconActionButton(
                          key: const Key('manual-deposit-qr-save'),
                          icon: CupertinoIcons.square_arrow_down,
                          label: '保存到本地',
                          loading: savingQr,
                          onPressed: savingQr || busy
                              ? null
                              : () => unawaited(saveDepositQr())),
                    ])),
              ]),
            ],
            if (deposit!.status == ManualIntentState.expired ||
                (deposit!.status == ManualIntentState.open && !depositOpen))
              warningBox('本次充值申请已过期，请勿转账'),
            if (deposit!.status == ManualIntentState.closedByRebind)
              warningBox('钱包地址已变更，本次充值已关闭，请勿转账'),
            if (deposit!.status == ManualIntentState.cancelled)
              warningBox('取消申请不代表链上转账已撤销或退款；如已转账请联系客服核验。'),
            if (depositOpen)
              button(depositCancellationPending ? '重试取消申请' : '取消充值申请',
                  cancelLegacyDeposit,
                  key: 'manual-deposit-cancel'),
            if (deposit!.status != ManualIntentState.open)
              button('再次充值', () async {
                await store.clear('deposit_cancel');
                await store.clear('deposit');
                depositOp = null;
                deposit = null;
                if (mounted) amount.clear();
                await loadPointsBalance();
              }),
          ],
        ];

  /// 当前提现所处的步骤：0 填写金额 / 1 确认报价 / 2 到账。
  int get payoutStep {
    if (payout != null || payoutOp?['id'] != null) return 2;
    if (quote != null) return 1;
    return 0;
  }

  /// 是否还需要（重新）获取报价：没有报价、报价结果未确认，或金额已被修改。
  bool get needsPayoutQuote =>
      quoteOp == null || quoteOp!['id'] == null || !payoutQuoteMatchesInput;

  String get payoutQuoteActionLabel {
    if (quoteOp == null) return '下一步';
    if (quoteOp!['id'] == null) return '重试本次提现报价';
    return '按新金额重新报价';
  }

  /// 点钻余额 hero：余额数字更大更醒目，副信息用次级色（微信式层级）。
  Widget pointsBalanceHero() {
    final amountText = pointsAvailable ?? '—';
    return Container(
      key: const Key('manual-payout-points-balance'),
      margin: const EdgeInsets.only(bottom: WeChatSpacing.md),
      padding: const EdgeInsets.all(WeChatSpacing.lg),
      decoration: BoxDecoration(
          color: WeChatColors.elevatedSurface(context),
          borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('当前点钻余额',
            style: TextStyle(
                fontSize: WeChatTypography.subhead,
                color:
                    WeChatColors.resolve(context, WeChatColors.textSecondary))),
        const SizedBox(height: WeChatSpacing.xs),
        Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              // 极端金额（超长小数）必须缩放而不是溢出。
              Flexible(
                  child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(amountText,
                          key: const Key('manual-payout-points-value'),
                          maxLines: 1,
                          style: TextStyle(
                              fontSize: WeChatTypography.brand,
                              fontWeight: FontWeight.w700,
                              height: 1.1,
                              color:
                                  WeChatColors.resolveTextPrimary(context))))),
              const SizedBox(width: WeChatSpacing.xs),
              Text('点钻',
                  style: TextStyle(
                      fontSize: WeChatTypography.callout,
                      color: WeChatColors.resolve(
                          context, WeChatColors.textSecondary))),
            ]),
        const SizedBox(height: WeChatSpacing.xs),
        Text('1 点钻 = ¥1.00 · 实际提现金额以报价为准',
            style: TextStyle(
                fontSize: WeChatTypography.caption,
                color:
                    WeChatColors.resolve(context, WeChatColors.textTertiary))),
      ]),
    );
  }

  List<Widget> payoutFields() => [
        if (!activeBinding ||
            !payoutEnabled ||
            !executionEnabled ||
            !pointsPayoutEnabled)
          warningBox('点钻提现暂不可用；已有订单可刷新查询或按状态取消。'),
        // 需求 5：步骤指示器在点「下一步」后保留，并用动效表达进度变化。
        stepIndicator(const ['填写金额', '确认报价', '到账'], payoutStep,
            keyPrefix: 'manual-payout-step'),
        pointsBalanceHero(),
        referenceFxCard(),
        if (pointsError != null) ...[
          warningBox(pointsError!),
          button('重新加载余额', loadPointsBalance),
        ],
        const SizedBox(height: 16),
        const Text('提现金额',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        const Text('1 点钻 = ¥1.00 · 到账金额与费用以报价为准',
            style: TextStyle(fontSize: 13, color: WeChatColors.textSecondary)),
        Row(children: [
          Expanded(
              child: field('manual-payout-amount', amount, '输入点钻金额',
                  // 需求 11：确认提现前输入框始终可改（提交以最终输入为准）。
                  enabled: payoutOp == null)),
          // 需求 6：输入框与「全部提现」之间保留设计网格间距（≥12dp）。
          const SizedBox(width: WeChatSpacing.md),
          WeChatSecondaryButton(
              key: const Key('manual-payout-all'),
              label: '全部提现',
              onPressed: busy ||
                      !ready ||
                      !activeBinding ||
                      !payoutEnabled ||
                      !executionEnabled ||
                      !pointsPayoutEnabled ||
                      pointsAvailable == null ||
                      payoutOp != null
                  ? null
                  : () => run(fillAll)),
        ]),
        if (quoteOp != null && (quoteOp!['funding_asset'] ?? 'USDT') != 'CAIBI')
          warningBox('这是此前保存的 USDT 提现申请，将按原资金来源恢复。'),
        if (quote != null && !payoutQuoteMatchesInput)
          Padding(
              padding: const EdgeInsets.only(top: WeChatSpacing.sm),
              child: Text('金额已修改，请重新点击「下一步」按最终金额获取报价。',
                  key: const Key('manual-payout-amount-changed'),
                  style: TextStyle(
                      fontSize: WeChatTypography.caption,
                      color: WeChatColors.resolve(
                          context, WeChatColors.textSecondary)))),
        // 「查看本次提现」已删除：报价由本页自动恢复展示；只有结果未确认
        // （同键重试）或金额被改过（重新报价）时才需要再点一次。
        if (payoutOp?['id'] == null && needsPayoutQuote)
          button(payoutQuoteActionLabel, createQuote,
              enabled: (quoteOp != null && quoteOp!['id'] == null) ||
                  (activeBinding &&
                      payoutEnabled &&
                      executionEnabled &&
                      pointsPayoutEnabled &&
                      pointsAvailable != null),
              key: 'manual-quote-create'),
        if (quote != null && payout == null && payoutQuoteMatchesInput) ...[
          statusHero(
              key: 'manual-payout-hero',
              icon: CupertinoIcons.arrow_up_circle,
              amount: quote!.amount,
              subtitle: '确认后由管理员人工付款',
              countdown: widget.clock().isBefore(quote!.expiresAt)
                  ? '报价有效期至 ${shortDate(quote!.expiresAt)}'
                  : null),
          rowsCard([
            addressRow('收款地址', quote!.targetAddress, 'manual-target-copy'),
            detail(quote!.fundingAsset == 'CAIBI' ? '扣除点钻' : '扣除 USDT',
                quote!.fundingAmount),
            detail('提现 USDT', quote!.amount),
            detail('服务费 USDT', quote!.fee),
            if (quote!.fundingAsset != 'CAIBI') detail('总冻结 USDT', quote!.hold),
            detail('到账 USDT', quote!.receive),
            // 需求 12：确认有效期只展示服务端权威值（本地过期校验用同一个
            // expires_at），前端不自己编造 5 分钟/24 小时。
            detail('确认有效期', shortDate(quote!.expiresAt)),
            detail('绑定版本', '${quote!.bindingVersion}'),
          ]),
          // 需求 10：删除「查看详情」，订单展示码直接展示（字号更小 + 复制）。
          codeRow('订单校验码', quote!.digest, 'manual-quote-digest'),
          if (!widget.clock().isBefore(quote!.expiresAt) && payoutOp == null)
            warningBox('本次报价已过期，请重新填写金额'),
        ],
        if (payoutOp?['id'] == null &&
            payout == null &&
            // 结果未确认的同一笔申请：即使报价读不到也必须允许同键重试
            // （否则用户会被困在「结果未确认」状态里）。
            (payoutOp != null ||
                (quote != null && payoutQuoteMatchesInput))) ...[
          if (payoutOp != null)
            Text(addressOnly
                ? '原申请结果待确认，请刷新或重试同一申请，请勿重复提交。'
                : '原申请结果待确认，请使用新的验证码重试同一申请。'),
          if (!addressOnly)
            field('manual-payout-otp', otp, '身份验证器六位验证码', secret: true),
          button(payoutOp == null ? '确认提现' : '重试本次提现', requestPayout,
              enabled: payoutOp != null ||
                  (activeBinding &&
                      payoutEnabled &&
                      executionEnabled &&
                      quote != null &&
                      widget.clock().isBefore(quote!.expiresAt) &&
                      (quote?.fundingAsset != 'CAIBI' || pointsPayoutEnabled)),
              key: 'manual-payout-confirm'),
        ],
        if (quoteOp != null && payoutOp == null)
          button('重新填写金额', () async {
            await store.clear('quote');
            quoteOp = null;
            quote = null;
            quoteInputAmount = null;
          }),
        if (payout != null) ...[
          statusHero(
              key: 'manual-payout-status-hero',
              icon: switch (payout!.status) {
                ManualPayoutState.settled => CupertinoIcons.checkmark_alt,
                ManualPayoutState.unknown => CupertinoIcons.question,
                _ => CupertinoIcons.clock,
              },
              amount: payout!.amount,
              subtitle: switch (payout!.status) {
                ManualPayoutState.settled => '已结算 · 请在钱包内确认到账',
                ManualPayoutState.unknown => '付款结果待核验，资金继续冻结',
                ManualPayoutState.cancelled => '已取消',
                _ => '管理员人工付款处理中',
              },
              tone: switch (payout!.status) {
                ManualPayoutState.settled => WeChatColors.brandPrimary,
                ManualPayoutState.unknown => WeChatColors.warning,
                _ => WeChatColors.brandPrimary,
              }),
          rowsCard([
            codeRow('订单', payout!.id, 'manual-payout-id'),
            detail('状态', payout!.status.name),
            detail('提现 USDT', payout!.amount),
            if (payout!.reviewReason != null)
              detail('核验说明', payout!.reviewReason!),
            if (payout!.settlementTxid != null)
              detail('已结算链上交易', payout!.settlementTxid!),
          ]),
          if (payout!.status == ManualPayoutState.unknown)
            warningBox('付款结果待核验，资金继续冻结，请勿重复申请。'),
          if (payout!.status == ManualPayoutState.requested)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: WeChatSecondaryButton(
                    key: const Key('manual-payout-cancel'),
                    label: '取消提现申请',
                    tone: WeChatButtonTone.danger,
                    onPressed: busy ? null : cancel)),
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
              quoteInputAmount = null;
              if (mounted) amount.clear();
            }),
        ],
      ];
}

/// 钱包进入快照网关：把「能力配置 + 点钻余额」合并成一份权威快照。
///
/// 绑定状态与草稿仍走既有 ManualWalletApi / ManualOperationStore，不放进快照，
/// 因此它们的失败语义（会话变化、终局失败）保持不变。金融数据绝不跨账号展示：
/// 作用域变化时直接抛错，让本次刷新失败而不是返回别的账号的数据。
final class _WalletEntryGateway implements WalletEntryGateway {
  _WalletEntryGateway(this.client, this.api);

  final BusinessApiClient client;
  final ManualWalletApi api;

  @override
  int get sessionEpoch => client.sessionEpoch;

  @override
  Future<Map<String, dynamic>> load() async {
    final scope = await client.walletIntentScope();
    final config = await client.walletConfig();
    final balances =
        await client.getJson('/wallet/balances/me', expectedWalletScope: scope);
    // 绑定状态一并进快照：断网时"绑定地址与钱包信息"必须仍然可见，且
    // activeBinding（进而充值/提现入口）不能因为一次网络失败就整体失效。
    final binding = await api.bindingStatus();
    if (await client.walletIntentScope() != scope) {
      throw StateError('账户已切换，请重新打开钱包');
    }
    return {
      'config': config,
      'caibi_available': balances['caibi_available'],
      'binding': binding.toJson(),
    };
  }
}
