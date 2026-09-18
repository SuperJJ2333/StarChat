import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../ui/components/wechat_date_picker.dart';
import '../../ui/components/wechat_empty_state.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'ledger_controller.dart';
import '../matrix/profile_repository.dart';
import 'ledger_gateway.dart';
import '../../ui/motion/motion_page_route.dart';

const _kinds = <String?, String>{
  null: '全部',
  'redpacket': '红包',
  'transfer': '转账',
  'withdrawal': '提现',
  'deposit': '充值',
  'other': '其他',
};

String formatLedgerAmount(Object? value) {
  if (value is! String || value.isEmpty) return '--';
  final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d{1,2}))?$').firstMatch(value);
  if (match == null) return '--';
  final fraction = (match.group(3) ?? '').padRight(2, '0');
  return '${match.group(1)}${match.group(2)}.$fraction 点钻';
}

/// Formats an API decimal for the list without binary floating-point parsing.
String formatLedgerRowAmount(Object? value) {
  final formatted = formatLedgerAmount(value);
  if (formatted == '--') return '--';
  final number = formatted.substring(0, formatted.length - 3);
  return number.startsWith('-') || number.startsWith('+') ? number : '+$number';
}

String formatLedgerSignedAmount(Object? value) {
  final amount = formatLedgerRowAmount(value);
  return amount == '--' ? amount : '$amount 点钻';
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
  final date = switch (value) {
    DateTime() => value,
    String() => DateTime.tryParse(value)?.toLocal(),
    _ => null,
  };
  if (date == null) return '--';
  String two(int part) => part.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
}

/// 筛选条上的日期：只需要到「日」，不再显示 `00:00:00`（BUG-06 展示优化）。
String formatLedgerFilterDate(DateTime value) {
  String two(int part) => part.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)}';
}

/// 列表日期分组标题：今天/昨天/M月d日（跨年补年份）。
String formatLedgerDayLabel(DateTime value, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final date = DateTime(value.year, value.month, value.day);
  final reference = DateTime(today.year, today.month, today.day);
  final difference = reference.difference(date).inDays;
  if (difference == 0) return '今天';
  if (difference == 1) return '昨天';
  final base = '${value.month}月${value.day}日';
  return value.year == today.year ? base : '${value.year}年$base';
}

/// 列表行的本地自然日（用于分组）。
DateTime? ledgerRowDay(Object? createdAt) {
  final parsed = switch (createdAt) {
    DateTime() => createdAt,
    String() => DateTime.tryParse(createdAt),
    _ => null,
  };
  if (parsed == null) return null;
  final local = parsed.toLocal();
  return DateTime(local.year, local.month, local.day);
}

String _transferStatus(Object? value) => switch (value) {
      'ACCEPTED' => '已收款',
      'DECLINED' => '已拒收',
      'EXPIRED' => '已过期',
      'PENDING' => '待收款',
      _ => '状态未知',
    };

/// 列表条目：日期分组标题或一行账单（仅用于展示层分组）。
sealed class _LedgerEntry {
  const _LedgerEntry();
}

final class _LedgerDayHeader extends _LedgerEntry {
  const _LedgerDayHeader(this.label);
  final String label;
}

final class _LedgerRowEntry extends _LedgerEntry {
  const _LedgerRowEntry(this.row);
  final Map<String, dynamic> row;
}

final class LedgerListPage extends StatefulWidget {
  const LedgerListPage({super.key, required this.gateway, this.identityCache});
  final LedgerGateway gateway;

  /// 账单名称后缀的对手方名（备注优先）查询源；缺省时不带后缀。
  final ProfileRepository? identityCache;
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
    unawaited(_loadIdentity());
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 160) unawaited(_controller.loadMore());
    });
  }

  Future<void> _loadIdentity() async {
    final cache = widget.identityCache;
    if (cache == null) return;
    try {
      await cache.hydrate();
      await cache.preload();
    } catch (_) {
      // The financial API data is still usable when identity refresh fails.
    }
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
            listenable: Listenable.merge([
              _controller,
              if (widget.identityCache != null) widget.identityCache!,
            ]),
            builder: (context, _) => Column(children: [
                  _filters(),
                  Expanded(child: _body()),
                ])),
      );

  bool get _hasFilters => _controller.hasFilters;

  void _clearFilters() {
    _search.clear();
    _controller.clearFilters();
  }

  /// 筛选摘要 + 重置入口：只在存在筛选条件时出现，
  /// 不占用默认状态的空间，也不与导航栏标题重复。
  Widget _filterSummary() {
    if (!_hasFilters) return const SizedBox.shrink();
    final parts = <String>[
      if (_controller.kind != null) _kinds[_controller.kind] ?? '其他',
      if (_controller.startAt != null || _controller.endAt != null)
        '${_controller.startAt == null ? '不限' : formatLedgerFilterDate(_controller.startAt!)}'
            ' 至 '
            '${_controller.endAt == null ? '不限' : formatLedgerFilterDate(DateTime(_controller.endAt!.year, _controller.endAt!.month, _controller.endAt!.day - 1))}',
      if ((_controller.query ?? '').trim().isNotEmpty)
        '“${_controller.query!.trim()}”',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: WeChatSpacing.sm),
      child: Row(children: [
        const Icon(CupertinoIcons.line_horizontal_3_decrease,
            size: 14, color: WeChatColors.textTertiary),
        const SizedBox(width: WeChatSpacing.xs),
        Expanded(
          child: Text(
            '已筛选：${parts.join(' · ')}',
            key: const Key('ledger-filter-summary'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 12, color: WeChatColors.textTertiary),
          ),
        ),
        CupertinoButton(
            key: const Key('ledger-filter-reset'),
            padding: const EdgeInsets.symmetric(horizontal: WeChatSpacing.sm),
            minimumSize: const Size(0, 28),
            onPressed: _clearFilters,
            child: const Text('重置', style: TextStyle(fontSize: 13))),
      ]),
    );
  }

  Widget _filters() => Padding(
        padding: const EdgeInsets.all(WeChatSpacing.md),
        child: Column(children: [
          CupertinoSearchTextField(
              controller: _search,
              onChanged: _controller.search,
              placeholder: '搜索账单'),
          const SizedBox(height: WeChatSpacing.sm),
          Row(children: [
            Expanded(child: _dateButton(false)),
            const SizedBox(width: WeChatSpacing.xs),
            Expanded(child: _dateButton(true)),
            CupertinoButton(
                key: const Key('ledger-clear-date'),
                padding: EdgeInsets.zero,
                onPressed: _controller.hasFilters &&
                        (_controller.startAt != null ||
                            _controller.endAt != null)
                    ? () => _controller.setDateRange(null, null)
                    : null,
                child: Icon(CupertinoIcons.clear,
                    color: _controller.startAt != null ||
                            _controller.endAt != null
                        ? WeChatColors.textSecondary
                        : WeChatColors.textTertiary)),
          ]),
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                  children: _kinds.entries
                      .map((entry) {
                        // 对比度修复：选中=品牌绿底+白字；未选中=浅表面+
                        // 细边框+品牌绿字（此前绿底叠默认绿字不可辨）。
                        final selected = _controller.kind == entry.key;
                        return Padding(
                          padding: const EdgeInsets.only(right: WeChatSpacing.xs),
                          child: CupertinoButton(
                              key: Key('ledger-kind-${entry.value}'),
                              color: selected
                                  ? WeChatColors.brandPrimary
                                  : WeChatColors.elevatedSurface(context),
                              borderRadius: BorderRadius.circular(8),
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              minimumSize: const Size(0, 32),
                              onPressed: () => _controller.setKind(entry.key),
                              child: Text(
                                entry.value,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: selected ? FontWeight.w600 : null,
                                  color: selected
                                      ? CupertinoColors.white
                                      : WeChatColors.brandPrimary,
                                ),
                              )),
                        );
                      })
                      .toList())),
          const SizedBox(height: WeChatSpacing.sm),
          _filterSummary(),
        ]),
      );

  /// demo 美化：白底圆角日期胶囊 + 日历 icon + 箭头，
  /// 选择器复用 WeChatDatePicker（与「查找聊天记录」同款日历）。
  Widget _dateButton(bool isEnd) {
    final date = isEnd ? _controller.endAt : _controller.startAt;
    final shown = isEnd && date != null
        ? DateTime(date.year, date.month, date.day - 1)
        : date;
    final active = date != null;
    return CupertinoButton(
        key: Key(isEnd ? 'ledger-end-date' : 'ledger-start-date'),
        padding: EdgeInsets.zero,
        onPressed: () => _chooseDate(isEnd),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: WeChatColors.elevatedSurface(context),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active
                  ? WeChatColors.brandPrimary.withValues(alpha: .4)
                  : WeChatColors.resolve(context, WeChatColors.divider),
              width: active ? 1.2 : .5,
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(CupertinoIcons.calendar,
                size: 14,
                color: active
                    ? WeChatColors.brandPrimary
                    : WeChatColors.textTertiary),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                // 只显示到日；带时分秒的筛选胶囊在移动端不可读（BUG-06）。
                shown == null
                    ? (isEnd ? '结束日期' : '开始日期')
                    : formatLedgerFilterDate(shown),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: active
                      ? WeChatColors.resolveTextPrimary(context)
                      : WeChatColors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 3),
            const Icon(CupertinoIcons.chevron_down,
                size: 10, color: WeChatColors.textTertiary),
          ]),
        ));
  }

  Widget _body() {
    if (_controller.items.isEmpty) {
      if (_controller.loading) {
        return const Center(child: CupertinoActivityIndicator());
      }
      if (_controller.error != null) return _retry(_controller.error!);
      return _emptyState();
    }
    final entries = _listEntries(_controller.items);
    return ListView.builder(
        controller: _scroll,
        itemCount: entries.length + 1,
        itemBuilder: (context, index) {
          if (index == entries.length) return _tail();
          final entry = entries[index];
          return switch (entry) {
            _LedgerDayHeader(:final label) => _dayHeader(label),
            _LedgerRowEntry(:final row) => _row(row),
          };
        });
  }

  /// 空状态：区分「一条账单都没有」与「当前筛选没有结果」，
  /// 后者给出一键清除筛选（BUG-06）。
  Widget _emptyState() {
    if (_hasFilters) {
      return WeChatEmptyState(
        key: const Key('ledger-empty-filtered'),
        icon: CupertinoIcons.line_horizontal_3_decrease,
        title: '没有符合条件的账单',
        description: '试试调整时间范围、账单类型或关键词',
        actionLabel: '清除筛选',
        onAction: _clearFilters,
      );
    }
    return const WeChatEmptyState(
      key: Key('ledger-empty'),
      icon: CupertinoIcons.doc_text,
      title: '暂无账单',
      description: '转账、红包、充值、提现记录都会显示在这里',
    );
  }

  /// 列表布局：按自然日分组，插入日期标题（今天/昨天/M月d日）。
  List<_LedgerEntry> _listEntries(List<Map<String, dynamic>> rows) {
    final entries = <_LedgerEntry>[];
    DateTime? currentDay;
    for (final row in rows) {
      final day = ledgerRowDay(row['created_at']);
      if (day != null && day != currentDay) {
        currentDay = day;
        entries.add(_LedgerDayHeader(formatLedgerDayLabel(day)));
      }
      entries.add(_LedgerRowEntry(row));
    }
    return entries;
  }

  Widget _dayHeader(String label) => Container(
        key: Key('ledger-day-$label'),
        color: WeChatColors.pageBackground(context),
        padding: const EdgeInsets.fromLTRB(
            WeChatSpacing.lg, WeChatSpacing.md, WeChatSpacing.lg, WeChatSpacing.xs),
        child: Text(label,
            style: const TextStyle(
                fontSize: 12, color: WeChatColors.textTertiary)),
      );

  Widget _row(Map<String, dynamic> row) {
    final kind = '${row['kind'] ?? ''}';
    final amount = formatLedgerRowAmount(row['amount']);
    final (icon, iconBg, title) = switch (kind) {
      'redpacket' => (CupertinoIcons.gift_fill, const Color(0xFFFA5151), '红包'),
      'transfer' => (
          CupertinoIcons.arrow_left_right,
          WeChatColors.brandPrimary,
          '转账'
        ),
      'deposit' => (CupertinoIcons.arrow_up, const Color(0xFFFA9D3B), '充值'),
      'withdrawal' => (
          CupertinoIcons.arrow_down,
          const Color(0xFF5F7BF7),
          '提现'
        ),
      _ => (CupertinoIcons.circle, WeChatColors.textTertiary, '其他'),
    };
    final description = ledgerDisplayDescription(row);
    return CupertinoButton(
      key: Key('ledger-row-${row['id']}'),
      padding: const EdgeInsets.symmetric(
          horizontal: WeChatSpacing.lg, vertical: WeChatSpacing.md),
      onPressed: () => Navigator.of(context).push(MotionPageRoute<void>(
          builder: (_) => LedgerDetailPage(
              gateway: widget.gateway,
              transactionId: row['id'] as String,
              identityCache: widget.identityCache,
              fromList: true))),
      child: Row(children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
          child: Icon(icon, color: CupertinoColors.white, size: 16),
        ),
        const SizedBox(width: WeChatSpacing.md),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_billTitle(row, title), style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 2),
          Text(
            '${_shortTime(row['created_at'])}${description.isEmpty ? '' : ' · $description'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                const TextStyle(fontSize: 12, color: WeChatColors.textTertiary),
          ),
        ])),
        SizedBox(
          width: 112,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              FittedBox(
                alignment: Alignment.centerRight,
                fit: BoxFit.scaleDown,
                child: Text(
                  amount,
                  key: Key('ledger-row-amount-${row['id']}'),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: !amount.startsWith('-')
                        ? WeChatColors.brandPrimary
                        : WeChatColors.resolveTextPrimary(context),
                  ),
                ),
              ),
              Text(_statusText(row),
                  style: const TextStyle(
                      fontSize: 11, color: WeChatColors.textTertiary)),
            ],
          ),
        ),
      ]),
    );
  }

  /// 账单名称后缀：对手方备注→昵称→畅聊号（identityCache 通讯录优先）。
  String _billTitle(Map<String, dynamic> row, String kindTitle) {
    final counterparty = '${row['counterparty_id'] ?? ''}';
    final reason = '${row['reason_code'] ?? ''}';
    final peer = _counterpartyName(row, counterparty);
    switch (reason) {
      case 'RED_PACKET_CREATE':
        if (row['packet_mode'] == 'EXCLUSIVE' && peer != null) {
          return '红包-转给$peer';
        }
        if (row['packet_room'] != null) return '红包-发出群红包';
        if (peer != null) return '红包-转给$peer';
        return '红包-发出';
      case 'RED_PACKET_CLAIM':
        return peer != null ? '红包-领取$peer的红包' : '领取红包';
      case 'RED_PACKET_REFUND':
      case 'RED_PACKET_EXPIRED':
        return '红包-退回';
      case 'CHAT_TRANSFER_DECLINED':
        return peer != null ? '转账-$peer（已拒收）' : '转账-已拒收';
      case 'CHAT_TRANSFER_ACCEPTED':
        return peer != null ? '转账-$peer（已收款）' : '转账-已收款';
    }
    if (row['kind'] == 'transfer') {
      return peer != null ? '转账-$peer' : '转账';
    }
    return kindTitle;
  }

  String? _counterpartyName(Map<String, dynamic> row, String counterparty) {
    final candidates = <String?>[
      counterparty.isEmpty
          ? null
          : widget.identityCache?.contactsByUserId[counterparty]?.displayName,
      row['counterparty_remark']?.toString(),
      row['counterparty_nickname']?.toString(),
      row['counterparty_username']?.toString(),
    ];
    for (final candidate in candidates) {
      final trimmed = candidate?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  /// 账单状态→展示文案（金额下方行）。
  String _statusText(Map<String, dynamic> row) {
    final status = '${row['status'] ?? ''}';
    final reason = '${row['reason_code'] ?? ''}';
    if (reason == 'RED_PACKET_CLAIM') return '领取红包';
    if (reason == 'RED_PACKET_CREATE') return '发出红包';
    if (reason == 'RED_PACKET_REFUND' || reason == 'RED_PACKET_EXPIRED') {
      return '退回';
    }
    return switch (status) {
      'ACCEPTED' => '已接受',
      'DECLINED' => '已拒收',
      'PENDING' => '待处理',
      'COMPLETED' => '已完成',
      'EXPIRED' => '已过期',
      _ => status.isEmpty ? '已入账' : status,
    };
  }

  String _shortTime(dynamic value) {
    final parsed = DateTime.tryParse('$value');
    if (parsed == null) return '';
    final local = parsed.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

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
      this.identityCache,
      this.fromList = false});
  final LedgerGateway gateway;
  final String transactionId;
  final ProfileRepository? identityCache;
  final bool fromList;
  @override
  State<LedgerDetailPage> createState() => _LedgerDetailPageState();
}

final class _LedgerDetailPageState extends State<LedgerDetailPage> {
  Map<String, dynamic>? _item;
  String? _error, _feedback;
  bool _loading = true, _sessionEnded = false;
  int _generation = 0;
  final _identityRefresh = ValueNotifier<int>(0);
  late final int _epoch = widget.gateway.sessionEpoch;
  late final StreamSubscription<void> _invalidations;
  @override
  void initState() {
    super.initState();
    _invalidations =
        widget.gateway.sessionInvalidations.listen((_) => _endSession());
    unawaited(_load());
    unawaited(_loadIdentity());
  }

  Future<void> _loadIdentity() async {
    final cache = widget.identityCache;
    if (cache == null) return;
    try {
      await cache.hydrate();
      await cache.preload();
    } catch (_) {}
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
    _identityRefresh.dispose();
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
        child: ListenableBuilder(
            listenable: widget.identityCache ?? _identityRefresh,
            builder: (context, _) => _loading
                ? const Center(child: CupertinoActivityIndicator())
                : _error != null
                    ? Center(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          Text(_error!),
                          if (!_sessionEnded &&
                              _epoch == widget.gateway.sessionEpoch)
                            CupertinoButton(
                                onPressed: _load, child: const Text('重试')),
                        ]),
                      )
                    : _detail()),
      );
  Widget _detail() {
    final data = _item!;
    final transfer = data['kind'] == 'transfer';
    final peer = _peerName(data);
    final username = _peerUsername(data);
    final rows = <(String, String)>[
      ('实际收支', formatLedgerSignedAmount(data['amount'])),
      ('当前状态', _detailStatusText(data)),
      ('说明', ledgerDisplayDescription(data)),
      if (transfer) ('转账本金', formatLedgerAmount(data['transfer_amount'])),
      if (transfer) ('付款方手续费', formatLedgerAmount(data['fee'])),
      if (data['kind'] == 'redpacket') ('红包类型', _packetType(data)),
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
      _detailHero(data, peer),
      const SizedBox(height: WeChatSpacing.md),
      for (final row in rows.take(2)) _detailRow(row.$1, row.$2),
      if (peer != null) _detailCounterpartyRow(peer, username),
      for (final row in rows.skip(2)) _detailRow(row.$1, row.$2),
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
      const Padding(
        padding: EdgeInsets.only(top: WeChatSpacing.lg),
        child: Center(
          child: Text('• 本账单由畅聊点钻系统生成',
              style: TextStyle(fontSize: 12, color: WeChatColors.textTertiary)),
        ),
      ),
    ]);
  }

  String? _peerName(Map<String, dynamic> data) {
    final id = data['counterparty_id']?.toString();
    if (id == null || id.isEmpty) return null;
    final values = <String?>[
      widget.identityCache?.contactsByUserId[id]?.displayName,
      data['counterparty_remark']?.toString(),
      data['counterparty_nickname']?.toString(),
      data['counterparty_username']?.toString(),
    ];
    return values.firstWhere(
        (value) => value != null && value.trim().isNotEmpty,
        orElse: () => null);
  }

  String? _peerUsername(Map<String, dynamic> data) {
    final id = data['counterparty_id']?.toString();
    if (id == null || id.isEmpty) return null;
    final values = <String?>[
      widget.identityCache?.contactsByUserId[id]?.username,
      data['counterparty_username']?.toString(),
    ];
    return values.firstWhere(
        (value) => value != null && value.trim().isNotEmpty,
        orElse: () => null);
  }

  String _packetType(Map<String, dynamic> data) {
    if (data['packet_mode'] == 'EXCLUSIVE') return '专属红包';
    if (data['packet_mode'] == 'RANDOM') return '拼手气群红包';
    if (data['packet_room'] != null) return '普通群红包';
    return '普通红包';
  }

  String _detailStatusText(Map<String, dynamic> data) {
    final reason = '${data['reason_code'] ?? ''}';
    if (reason == 'RED_PACKET_CLAIM') return '领取红包';
    if (reason == 'RED_PACKET_CREATE') return '发出红包';
    if (reason == 'RED_PACKET_REFUND' || reason == 'RED_PACKET_EXPIRED') {
      return '退回';
    }
    if (data['kind'] == 'transfer') {
      return data['status'] == 'ACCEPTED'
          ? '已接受'
          : _transferStatus(data['status']);
    }
    return '${data['status'] ?? '已入账'}';
  }

  Widget _detailHero(Map<String, dynamic> data, String? peer) {
    final isPacket = data['kind'] == 'redpacket';
    final isTransfer = data['kind'] == 'transfer';
    final accepted = data['status'] == 'ACCEPTED';
    final status = _detailStatusText(data);
    final reversed = status == '退回';
    final iconColor = isPacket
        ? const Color(0xFFFA5151)
        : isTransfer
            ? const Color(0xFFFA9D3B)
            : WeChatColors.brandPrimary;
    final statusColor = reversed
        ? WeChatColors.textTertiary
        : accepted
            ? const Color(0xFFFA9D3B)
            : isPacket && status == '领取红包'
                ? WeChatColors.brandPrimary
                : WeChatColors.brandPrimary;
    final title = isPacket
        ? _packetHeroTitle(data, peer)
        : isTransfer
            ? (peer == null ? '转账' : '转账-$peer')
            : (_kinds[data['kind']] ?? '其他');
    return Container(
      key: const Key('ledger-detail-hero'),
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
      decoration: BoxDecoration(
          color: CupertinoTheme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(8)),
      child: Column(children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: iconColor, shape: BoxShape.circle),
          child: Icon(
              isPacket
                  ? CupertinoIcons.gift_fill
                  : isTransfer
                      ? CupertinoIcons.arrow_left_right
                      : CupertinoIcons.doc_text_fill,
              color: CupertinoColors.white,
              size: 26),
        ),
        const SizedBox(height: 10),
        Text(title,
            key: const Key('ledger-detail-title'),
            style: const TextStyle(
                fontSize: 14, color: WeChatColors.textSecondary)),
        const SizedBox(height: 4),
        Text(formatLedgerSignedAmount(data['amount']),
            style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.w700,
                color: WeChatColors.resolveTextPrimary(context))),
        const SizedBox(height: 8),
        Container(
          key: const Key('ledger-detail-status-pill'),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4)),
          child: Text(status,
              style: TextStyle(fontSize: 12, color: statusColor)),
        ),
      ]),
    );
  }

  String _packetHeroTitle(Map<String, dynamic> data, String? peer) {
    final reason = '${data['reason_code'] ?? ''}';
    if (reason == 'RED_PACKET_CLAIM' && peer != null) return '红包-领取$peer的红包';
    if (reason == 'RED_PACKET_CREATE' && peer != null) return '红包-转给$peer';
    if (reason == 'RED_PACKET_REFUND' || reason == 'RED_PACKET_EXPIRED') {
      return '红包-退回';
    }
    return '红包';
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

  Widget _detailCounterpartyRow(String name, String? username) => Padding(
      padding: const EdgeInsets.symmetric(vertical: WeChatSpacing.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(
            width: 96,
            child: Text('交易对方',
                style: TextStyle(color: WeChatColors.textSecondary))),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(name, textAlign: TextAlign.right),
          if (username != null)
            Text('畅聊号：$username',
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 12, color: WeChatColors.textTertiary)),
        ])),
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
    Navigator.of(context).pushReplacement(MotionPageRoute<void>(
        builder: (_) => LedgerListPage(
            gateway: widget.gateway, identityCache: widget.identityCache)));
  }
}
