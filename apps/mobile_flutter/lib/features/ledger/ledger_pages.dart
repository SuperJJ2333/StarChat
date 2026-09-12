import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../ui/components/wechat_date_picker.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'ledger_controller.dart';
import 'ledger_gateway.dart';

const _kinds = <String?, String>{
  null: '全部',
  'redpacket': '红包',
  'transfer': '转账',
  'withdrawal': '提现',
  'deposit': '充值',
  'other': '其他',
};

sealed class _LedgerListEntry {
  const _LedgerListEntry();
}

final class _LedgerDayEntry extends _LedgerListEntry {
  const _LedgerDayEntry(this.day);
  final String day;
}

final class _LedgerRowEntry extends _LedgerListEntry {
  const _LedgerRowEntry(this.row,
      {required this.showDivider, required this.isLastInDay});
  final Map<String, dynamic> row;
  final bool showDivider;
  final bool isLastInDay;
}

String formatLedgerAmount(Object? value) {
  if (value is! String || value.isEmpty) return '--';
  final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d{1,2}))?$').firstMatch(value);
  if (match == null) return '--';
  final fraction = (match.group(3) ?? '').padRight(2, '0');
  return '${match.group(1)}${match.group(2)}.$fraction 点钻';
}

/// Compact list amounts use the same string-only parser as the detail page.
/// A positive entry gains the demo's explicit plus sign without converting a
/// potentially large CAIBI integer through binary floating point.
String formatLedgerListAmount(Object? value) {
  if (value is! String || value.isEmpty) return '--';
  final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d{1,2}))?$').firstMatch(value);
  if (match == null) return '--';
  final fraction = (match.group(3) ?? '').padRight(2, '0');
  final sign = match.group(1) == '-' ? '-' : '+';
  return '$sign${match.group(2)}.$fraction';
}

/// Produces user-facing copy without exposing server-side reason-code names.
String ledgerDisplayDescription(Map<String, dynamic> data) {
  final note = data['note'];
  if (note is String && note.trim().isNotEmpty) return note;
  if (data['kind'] == 'transfer') return '转账';
  return switch (data['reason_code']) {
    'RED_PACKET_CREATE' => '发出红包',
    'RED_PACKET_CLAIM' => '领取红包',
    'RED_PACKET_REFUND' => '红包退回',
    'RED_PACKET_EXPIRED' => '红包退回',
    'MANUAL_PAYOUT_CANCELLED' => '提现退回',
    _ => data['kind'] == 'redpacket'
        ? '红包'
        : data['kind'] == 'withdrawal'
            ? '提现'
            : data['kind'] == 'deposit'
                ? '充值'
                : '其他',
  };
}

String _time(Object? value) {
  final date = _localDate(value);
  if (date == null) return '--';
  String two(int part) => part.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
}

DateTime? _localDate(Object? value) => switch (value) {
      DateTime() => value.toLocal(),
      String() => DateTime.tryParse(value)?.toLocal(),
      _ => null,
    };

String _transferStatus(Object? value) => switch (value) {
      'ACCEPTED' => '已收款',
      'DECLINED' => '已拒收',
      'EXPIRED' => '已过期',
      'PENDING' => '待收款',
      _ => '状态未知',
    };

final class LedgerListPage extends StatefulWidget {
  const LedgerListPage({super.key, required this.gateway});
  final LedgerGateway gateway;
  @override
  State<LedgerListPage> createState() => _LedgerListPageState();
}

final class _LedgerListPageState extends State<LedgerListPage> {
  late final LedgerController _controller = LedgerController(widget.gateway);
  final _search = TextEditingController();
  final _scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    unawaited(_controller.load());
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 160) unawaited(_controller.loadMore());
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _chooseDate(bool isEnd) async {
    final current = isEnd && _controller.endAt != null
        ? DateTime(_controller.endAt!.year, _controller.endAt!.month,
            _controller.endAt!.day - 1)
        : (isEnd ? _controller.endAt : _controller.startAt);
    final picked = await WeChatDatePicker.show(context,
        initialDate: current ?? DateTime.now());
    if (!mounted || picked == null) return;
    final start = DateTime(picked.year, picked.month, picked.day);
    // The API end value is exclusive; calendar construction stays DST-safe.
    final end = DateTime(picked.year, picked.month, picked.day + 1);
    _controller.setDateRange(
        isEnd ? _controller.startAt : start, isEnd ? end : _controller.endAt);
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold(
        title: '全部账单',
        child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => Column(children: [
                  _filters(),
                  Expanded(child: _body()),
                ])),
      );
  Widget _filters() {
    final isDark = CupertinoTheme.of(context).brightness == Brightness.dark;
    return Padding(
      key: const Key('ledger-filter-bar'),
      padding: const EdgeInsets.fromLTRB(WeChatSpacing.lg, WeChatSpacing.lg,
          WeChatSpacing.lg, WeChatSpacing.sm),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CupertinoSearchTextField(
            controller: _search,
            onChanged: _controller.search,
            backgroundColor: CupertinoColors.white,
            placeholder: '搜索账单'),
        const SizedBox(height: WeChatSpacing.sm),
        SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
                children: _kinds.entries
                    .map((entry) => Padding(
                          padding:
                              const EdgeInsets.only(right: WeChatSpacing.xs),
                          child: CupertinoButton(
                              key: Key('ledger-kind-${entry.value}'),
                              color: _controller.kind == entry.key
                                  ? WeChatColors.brandPrimary
                                  : isDark
                                      ? WeChatColors.darkElevated
                                      : WeChatColors.lightElevated,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 6),
                              borderRadius: BorderRadius.circular(14),
                              onPressed: () => _controller.setKind(entry.key),
                              child: Text(entry.value,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: _controller.kind == entry.key
                                          ? CupertinoColors.white
                                          : WeChatColors.resolveTextPrimary(
                                              context)))),
                        ))
                    .toList())),
        Row(children: [
          Expanded(child: _dateButton(false)),
          const SizedBox(width: WeChatSpacing.xs),
          Expanded(child: _dateButton(true)),
          CupertinoButton(
              key: const Key('ledger-clear-date'),
              padding: EdgeInsets.zero,
              onPressed: () => _controller.setDateRange(null, null),
              child: const Icon(CupertinoIcons.clear)),
        ]),
      ]),
    );
  }

  Widget _dateButton(bool isEnd) {
    final date = isEnd ? _controller.endAt : _controller.startAt;
    final shown = isEnd && date != null
        ? DateTime(date.year, date.month, date.day - 1)
        : date;
    return CupertinoButton(
        key: Key(isEnd ? 'ledger-end-date' : 'ledger-start-date'),
        padding: EdgeInsets.zero,
        onPressed: () => _chooseDate(isEnd),
        child: Text(
          shown == null ? (isEnd ? '结束日期' : '开始日期') : _dateText(shown),
          style: const TextStyle(
            fontSize: 13,
            color: WeChatColors.textSecondary,
          ),
        ));
  }

  String _dateText(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)}';
  }

  Widget _body() {
    if (_controller.items.isEmpty) {
      if (_controller.loading) {
        return const Center(child: CupertinoActivityIndicator());
      }
      if (_controller.error != null) return _retry(_controller.error!);
      return const Center(child: Text('暂无点钻流水'));
    }
    final rows = _controller.items;
    final entries = <_LedgerListEntry>[];
    String? previousDay;
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      final day = _dayKey(row['created_at']);
      final newDay = day != previousDay;
      if (newDay) {
        entries.add(_LedgerDayEntry(day));
      }
      previousDay = day;
      final isLastInDay = index == rows.length - 1 ||
          _dayKey(rows[index + 1]['created_at']) != day;
      entries.add(
          _LedgerRowEntry(row, showDivider: !newDay, isLastInDay: isLastInDay));
    }
    return ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.only(bottom: WeChatSpacing.lg),
        itemCount: entries.length + 1,
        itemBuilder: (context, index) {
          if (index == entries.length) return _tail();
          return switch (entries[index]) {
            _LedgerDayEntry(:final day) => _dayGroup(day),
            _LedgerRowEntry(
              :final row,
              :final showDivider,
              :final isLastInDay
            ) =>
              _row(row, showDivider: showDivider, isLastInDay: isLastInDay),
          };
        });
  }

  Widget _dayGroup(String day) => Container(
      key: Key('ledger-day-$day'),
      margin: const EdgeInsets.symmetric(horizontal: WeChatSpacing.md),
      decoration: BoxDecoration(
        color: WeChatColors.elevatedSurface(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            WeChatSpacing.lg, WeChatSpacing.md, WeChatSpacing.lg, 4),
        child: Text(_dayLabel(day),
            style: const TextStyle(
                color: WeChatColors.textSecondary,
                fontSize: WeChatTypography.caption)),
      ));

  Widget _row(Map<String, dynamic> row,
      {bool showDivider = false, bool isLastInDay = true}) {
    final id = row['id'] as String;
    final status = _displayStatus(row);
    return CupertinoButton(
      key: Key('ledger-row-$id'),
      padding: EdgeInsets.zero,
      onPressed: () => Navigator.of(context).push(CupertinoPageRoute<void>(
          builder: (_) => LedgerDetailPage(
              gateway: widget.gateway, transactionId: id, fromList: true))),
      child: Container(
        margin: EdgeInsets.fromLTRB(WeChatSpacing.md, 0, WeChatSpacing.md,
            isLastInDay ? WeChatSpacing.md : 0),
        decoration: BoxDecoration(
            color: WeChatColors.elevatedSurface(context),
            borderRadius: BorderRadius.vertical(
                top: const Radius.circular(0),
                bottom: Radius.circular(isLastInDay ? 8 : 0))),
        padding: const EdgeInsets.symmetric(
            horizontal: WeChatSpacing.lg, vertical: WeChatSpacing.md),
        foregroundDecoration: showDivider
            ? BoxDecoration(
                border: Border(
                    top: BorderSide(
                        color: CupertinoTheme.of(context).brightness ==
                                Brightness.dark
                            ? WeChatColors.darkDivider
                            : WeChatColors.divider)))
            : null,
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Container(
            key: Key('ledger-row-icon-$id'),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _kindColor(row['kind']),
              shape: BoxShape.circle,
            ),
            child: Icon(_kindIcon(row['kind']),
                size: 17, color: CupertinoColors.white),
          ),
          const SizedBox(width: WeChatSpacing.md),
          Expanded(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(_kindTitle(row['kind']),
                    style: TextStyle(
                        color: WeChatColors.resolveTextPrimary(context),
                        fontSize: WeChatTypography.body,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: WeChatSpacing.xs),
                Text(_listSubtitle(row),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: WeChatTypography.caption,
                        color: WeChatColors.textTertiary)),
              ])),
          const SizedBox(width: WeChatSpacing.sm),
          Flexible(
              flex: 2,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(formatLedgerListAmount(row['amount']),
                        key: Key('ledger-amount-$id'),
                        softWrap: true,
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            color: _isIncoming(row['amount'])
                                ? WeChatColors.brandPrimary
                                : WeChatColors.resolveTextPrimary(context),
                            fontSize: WeChatTypography.callout,
                            fontWeight: FontWeight.w700)),
                    if (status != null)
                      Text(status,
                          style: const TextStyle(
                              fontSize: 11, color: WeChatColors.textTertiary)),
                  ])),
        ]),
      ),
    );
  }

  String _dayKey(Object? value) {
    final date = _localDate(value);
    if (date == null) return 'unknown';
    String two(int part) => part.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)}';
  }

  String _dayLabel(String day) {
    if (day == 'unknown') return '日期未知';
    final date = DateTime.tryParse(day);
    if (date == null) return '日期未知';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (date == today) return '今天';
    if (date == DateTime(now.year, now.month, now.day - 1)) return '昨天';
    return '${date.year}年${date.month}月${date.day}日';
  }

  String _listSubtitle(Map<String, dynamic> row) {
    final time = _localDate(row['created_at']);
    if (time == null) return ledgerDisplayDescription(row);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)} · ${ledgerDisplayDescription(row)}';
  }

  String? _displayStatus(Map<String, dynamic> row) {
    final status = row['status'];
    if (status is! String || status.isEmpty) return null;
    return row['kind'] == 'transfer' ? _transferStatus(status) : status;
  }

  bool _isIncoming(Object? value) {
    final text = value is String ? value : '';
    return RegExp(r'^\+?(?:0|[1-9]\d*)(?:\.\d{1,2})?$').hasMatch(text);
  }

  String _kindTitle(Object? kind) => switch (kind) {
        'redpacket' => '红包',
        'transfer' => '转账',
        'withdrawal' => '提现',
        'deposit' => '充值',
        _ => '其他',
      };

  IconData _kindIcon(Object? kind) => switch (kind) {
        'redpacket' => CupertinoIcons.gift_fill,
        'transfer' => CupertinoIcons.arrow_left_right,
        'withdrawal' => CupertinoIcons.arrow_down,
        'deposit' => CupertinoIcons.arrow_up,
        _ => CupertinoIcons.circle,
      };

  Color _kindColor(Object? kind) => switch (kind) {
        'redpacket' => const Color(0xFFFA5151),
        'transfer' => WeChatColors.brandPrimary,
        'withdrawal' => const Color(0xFF5F7BF7),
        'deposit' => const Color(0xFFFA9D3B),
        _ => WeChatColors.textTertiary,
      };
  Widget _tail() {
    if (_controller.loadingMore) {
      return const Padding(
          padding: EdgeInsets.all(WeChatSpacing.lg),
          child: Center(child: CupertinoActivityIndicator()));
    }
    if (_controller.error != null) return _retry(_controller.error!);
    return const SizedBox(height: WeChatSpacing.xl);
  }

  Widget _retry(String label) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(label),
        if (!_controller.sessionEnded)
          CupertinoButton(
              onPressed: _controller.retry, child: const Text('重试')),
      ]));
}

final class LedgerDetailPage extends StatefulWidget {
  const LedgerDetailPage(
      {super.key,
      required this.gateway,
      required this.transactionId,
      this.fromList = false});
  final LedgerGateway gateway;
  final String transactionId;
  final bool fromList;
  @override
  State<LedgerDetailPage> createState() => _LedgerDetailPageState();
}

final class _LedgerDetailPageState extends State<LedgerDetailPage> {
  Map<String, dynamic>? _item;
  String? _error, _feedback;
  bool _loading = true, _sessionEnded = false;
  int _generation = 0;
  late final int _epoch = widget.gateway.sessionEpoch;
  late final StreamSubscription<void> _invalidations;
  @override
  void initState() {
    super.initState();
    _invalidations =
        widget.gateway.sessionInvalidations.listen((_) => _endSession());
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!mounted || _sessionEnded) return;
    if (_epoch != widget.gateway.sessionEpoch) {
      _endSession();
      return;
    }
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _feedback = null;
    });
    try {
      final value =
          await widget.gateway.ledgerTransactionDetail(widget.transactionId);
      if (!mounted || generation != _generation || _sessionEnded) return;
      if (_epoch != widget.gateway.sessionEpoch) {
        _endSession();
        return;
      }
      if (value['id'] is! String ||
          (value['id'] as String).isEmpty ||
          value['asset'] != 'CAIBI') {
        throw const FormatException('invalid ledger detail');
      }
      setState(() {
        _item = Map<String, dynamic>.from(value);
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation || _sessionEnded) return;
      if (_epoch != widget.gateway.sessionEpoch) {
        _endSession();
        return;
      }
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '账单加载失败，请重试';
        });
      }
    }
  }

  void _endSession() {
    if (_sessionEnded) return;
    _generation++;
    _sessionEnded = true;
    if (mounted) {
      setState(() {
        _loading = false;
        _item = null;
        _error = '会话已结束，请重新打开账单';
      });
    }
  }

  @override
  void dispose() {
    _invalidations.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold(
        title: '账单详情',
        trailing: CupertinoButton(
            key: const Key('ledger-all-bills'),
            padding: EdgeInsets.zero,
            onPressed: _showAllBills,
            child: const Text('全部账单')),
        child: _loading
            ? const Center(child: CupertinoActivityIndicator())
            : _error != null
                ? Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(_error!),
                      if (!_sessionEnded &&
                          _epoch == widget.gateway.sessionEpoch)
                        CupertinoButton(
                            onPressed: _load, child: const Text('重试')),
                    ]),
                  )
                : _detail(),
      );
  Widget _detail() {
    final data = _item!;
    final transfer = data['kind'] == 'transfer';
    final rows = <(String, String)>[
      ('实际收支', formatLedgerAmount(data['amount'])),
      ('说明', ledgerDisplayDescription(data)),
      if (transfer) ('转账状态', _transferStatus(data['status'])),
      if (!transfer) ('账单状态', '${data['status'] ?? '已入账'}'),
      if (transfer) ('转账本金', formatLedgerAmount(data['transfer_amount'])),
      if (transfer) ('付款方手续费', formatLedgerAmount(data['fee'])),
      if (transfer)
        ('转账时间', _time(data['transfer_created_at'] ?? data['created_at'])),
      if (transfer)
        (
          '收款时间',
          data['accepted_at'] == null ? '尚未收款' : _time(data['accepted_at'])
        ),
      if (!transfer) ('入账时间', _time(data['created_at'])),
      ('账单ID', '${data['id'] ?? '--'}'),
    ];
    return ListView(padding: const EdgeInsets.all(WeChatSpacing.lg), children: [
      for (final row in rows) _detailRow(row.$1, row.$2),
      CupertinoButton(
          key: const Key('ledger-copy-id'),
          onPressed: _copyId,
          child: Semantics(
              label: '复制账单ID',
              button: true,
              child: Icon(CupertinoIcons.doc_on_doc))),
      if (_feedback != null)
        Center(
            child: Text(_feedback!,
                style: const TextStyle(color: WeChatColors.textSecondary))),
    ]);
  }

  Widget _detailRow(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: WeChatSpacing.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
            width: 96,
            child: Text(label,
                style: const TextStyle(color: WeChatColors.textSecondary))),
        Expanded(child: Text(value, textAlign: TextAlign.right)),
      ]));
  Future<void> _copyId() async {
    final id = _item?['id'];
    if (_sessionEnded ||
        _epoch != widget.gateway.sessionEpoch ||
        id is! String) {
      if (mounted) setState(() => _feedback = '无法复制账单ID');
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: id));
      if (mounted && !_sessionEnded && _epoch == widget.gateway.sessionEpoch) {
        setState(() => _feedback = '账单ID已复制');
      }
    } catch (_) {
      if (mounted) setState(() => _feedback = '无法复制账单ID');
    }
  }

  void _showAllBills() {
    if (_sessionEnded || _epoch != widget.gateway.sessionEpoch) {
      _endSession();
      return;
    }
    if (widget.fromList) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pushReplacement(CupertinoPageRoute<void>(
        builder: (_) => LedgerListPage(gateway: widget.gateway)));
  }
}
