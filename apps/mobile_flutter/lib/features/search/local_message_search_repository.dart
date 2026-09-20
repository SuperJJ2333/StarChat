import 'package:flutter/foundation.dart';

import 'global_search_index.dart';
import 'global_search_models.dart';

/// 单房间默认回填上限（本机读取条数，**不是**网络分页）。
///
/// 必须显著高于旧实现的 4000，否则本机已有的更早历史会被静默丢弃。
const int kLocalSearchDefaultPerRoomLimit = 8000;

/// 每处理多少个房间让出一次事件循环（资源边界，防止长同步段卡 UI）。
const int kLocalSearchBatchRooms = 8;

/// 单次回填默认允许索引的总记录数（内存/时间安全阀）。
///
/// 这不是产品语义上限：被它截断时 [LocalMessageSearchRepository
/// .isBackfillComplete] 保持 false，后续调用会继续推进。
const int kLocalSearchDefaultTotalRecordBudget = 200000;

/// 一条**已经在本机解密完成、且用户可见**的本地聊天记录。
///
/// 只承载文本正文与展示用 metadata：没有图片/视频/音频字节，没有 room key，
/// 没有会话密钥，也没有任何附件句柄。阅后即焚消息必须带
/// [isFlashPhoto] = true（仓库层会在入库前丢弃）。
@immutable
final class LocalSearchMessage {
  const LocalSearchMessage({
    required this.eventId,
    required this.senderId,
    required this.senderName,
    required this.timestamp,
    required this.body,
    required this.roomId,
    required this.roomName,
    this.senderIsSelf = false,
    this.isFlashPhoto = false,
    this.isGroup = false,
    this.roomAvatarSeed,
    this.roomAvatarUrl,
  });

  final String eventId;
  final String senderId;
  final String senderName;
  final DateTime timestamp;

  /// 已解密、用户可见的**纯文本**正文（仅本机内存参与匹配，绝不上传）。
  final String body;
  final String roomId;
  final String roomName;
  final bool senderIsSelf;

  /// 阅后即焚（闪照）：内容不可检索，仓库层在入库前过滤。
  final bool isFlashPhoto;
  final bool isGroup;
  final String? roomAvatarSeed;
  final String? roomAvatarUrl;
}

/// 本机历史（device-local）只读视图。
///
/// 实现约定（**硬性**）：
/// - 只读本机已经存在的数据，通常是 Matrix SDK 的 SQLCipher 加密本地库；
/// - **绝不发起任何网络请求**：不得调用 `/messages` 之类的 Matrix 分页接口，
///   不得访问 Business API，不得上传查询词或正文；
/// - 只返回**已经解密完成**的事件；未解密/被锁定的加密正文必须跳过；
/// - 阅后即焚消息必须置 [LocalSearchMessage.isFlashPhoto]，并只填纯文本正文。
///
/// 生产适配器（由上层注入，本仓库不在此任务内直连数据库）示例：
/// ```dart
/// // 仅本机读取，无网络：
/// final events = await client.database.getEventList(room, start: 0, limit: limit);
/// // 过滤掉未解密/加密事件后，用 room.getEventById(...) 补齐 metadata；
/// // msgtype == m.image / m.video / m.audio / m.file 一律不进入索引。
/// ```
abstract interface class LocalHistorySearchSource {
  /// 本机库中该房间最近的本地事件（新→旧，最多 [limit] 条，越界不算失败）。
  Future<List<LocalSearchMessage>> readRecentMessages(
      {required String roomId, required int limit});

  /// 本机库中已经存在的房间 id（不联网枚举）。
  Future<List<String>> localRoomIds();
}

/// 假数据/测试友好的内存实现：不触网、不落盘。
///
/// 生产环境请注入真实的 [LocalHistorySearchSource]（读取本机加密 Matrix 库）。
final class InMemoryLocalHistorySource implements LocalHistorySearchSource {
  InMemoryLocalHistorySource(
      [Iterable<LocalSearchMessage> messages = const []]) {
    for (final message in messages) {
      _rooms
          .putIfAbsent(message.roomId, () => <LocalSearchMessage>[])
          .add(message);
    }
    for (final list in _rooms.values) {
      list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    }
  }

  final Map<String, List<LocalSearchMessage>> _rooms =
      <String, List<LocalSearchMessage>>{};

  @override
  Future<List<String>> localRoomIds() async => _rooms.keys.toList();

  @override
  Future<List<LocalSearchMessage>> readRecentMessages(
      {required String roomId, required int limit}) async {
    final all = _rooms[roomId] ?? const <LocalSearchMessage>[];
    return all.length > limit ? all.sublist(0, limit) : List.of(all);
  }
}

/// 未注入真实数据源时的安全默认：本机库「读不到」任何内容。
///
/// 保留它以让页面在父级完成注入之前依旧可用（只搜索本进程增量投影），
/// 且永远不会因为缺少适配器而触网或抛错。
final class UnavailableLocalHistorySource implements LocalHistorySearchSource {
  const UnavailableLocalHistorySource();

  @override
  Future<List<String>> localRoomIds() async => const [];

  @override
  Future<List<LocalSearchMessage>> readRecentMessages(
          {required String roomId, required int limit}) async =>
      const [];
}

/// 账号维度的**本机聊天记录搜索仓库**。
///
/// 产品语义：搜索「本机已经存在、已经解密、用户可见」的聊天记录，
/// 而不是服务端全量历史，也不是「本次进程内打开过的房间」。
///
/// 安全与隐私边界（全部为硬约束）：
/// - **零网络**：本类不 import 任何网络库，只通过注入的
///   [LocalHistorySearchSource] 读取本机数据；查询词与明文永不出设备。
/// - **不新增明文落盘存储**：本机索引只存在于内存。它由**已经加密**的
///   Matrix 本地库（SQLCipher）重建，因此没有任何新的明文数据库/
///   SharedPreferences 键值；进程重启后从同一加密库重新回填即可。
///   （这是本任务采用的正确回退方案：不做新的明文缓存。）
/// - **闪照不索引**：`isFlashPhoto` 与媒体占位正文在入库前被过滤，
///   仓库持有的状态里不存在任何图片/媒体正文。
/// - **账号隔离**：重新 [attachAccount] 会清空索引并推进
///   [accountEpoch]，迟到的旧账号回填结果会被代次校验丢弃。
final class LocalMessageSearchRepository extends ChangeNotifier {
  LocalMessageSearchRepository({
    LocalHistorySearchSource? source,
    GlobalSearchIndex? index,
    this.maxRooms = 200,
    this.defaultPerRoomLimit = kLocalSearchDefaultPerRoomLimit,
    this.batchRooms = kLocalSearchBatchRooms,
    this.defaultTotalRecordBudget = kLocalSearchDefaultTotalRecordBudget,
  })  : source = source ?? const UnavailableLocalHistorySource(),
        index = index ?? GlobalSearchIndex.shared;

  /// 默认共享实例：使用 [GlobalSearchIndex.shared]，与 RoomPage 现有投影同源。
  ///
  /// 上层需要在启动后注入真实数据源（`LocalMessageSearchRepository.shared
  /// .source = ...`），登录/切号时 `attachAccount`，同步完成后
  /// `backfillLocalHistory()`，登出时 `clear()`。
  static LocalMessageSearchRepository shared = LocalMessageSearchRepository();

  final GlobalSearchIndex index;
  final int maxRooms;
  final int defaultPerRoomLimit;

  /// 每处理多少个房间让出一次事件循环（避免长同步段卡住首屏/发送/通话）。
  final int batchRooms;

  /// 单次回填允许索引的总记录数（内存/时间安全阀；不是产品语义上限）。
  final int defaultTotalRecordBudget;

  /// 本机只读历史源。账号切换时应替换为对应账号的本地库视图。
  LocalHistorySearchSource source;

  String? _accountKey;
  bool _backfillComplete = false;
  bool _cancelRequested = false;
  Future<int>? _inFlight;

  /// 当前绑定的账号 key（通常是 Matrix userId）；未登录时为 null。
  String? get accountKey => _accountKey;
  bool get isAttached => _accountKey != null;

  /// 是否已经**完整**扫过本机已有历史。
  ///
  /// 只有完整扫完才为 true；被房间上限/记录预算/取消/账号切换截断时为
  /// false，因此后续 [ensureBackfilled] 仍会继续推进（历史不会被永久截断）。
  bool get isBackfillComplete => _backfillComplete;

  /// 账号代次：切换/登出即推进；用于丢弃迟到的旧账号结果。
  int get accountEpoch => index.accountEpoch;

  /// 绑定账号：**完全重置**内存索引并推进代次，杜绝跨账号泄漏。
  ///
  /// 无 I/O，可在登录/切号/登出的同步路径里直接调用。重复绑定同一账号
  /// 不会清空已经回填的索引（幂等）。
  void attachAccount(String accountKey) {
    if (accountKey.isEmpty) {
      clear();
      return;
    }
    if (_accountKey == accountKey) return;
    _accountKey = accountKey;
    _backfillComplete = false;
    _cancelRequested = false;
    _inFlight = null;
    index.clear();
    notifyListeners();
  }

  /// 从**本机加密库**回填历史索引；返回本次索引的记录条数。
  ///
  /// 资源边界（本轮收口：绝不能阻塞 AppHome 首屏 / 登录 / 打开聊天 / 发消息 /
  /// 通话等关键路径）：
  /// - 只调用注入的 [source]（本机读取），不产生任何网络请求；
  /// - [perRoomLimit] 限制每个房间从本机库读取的条数；
  /// - [maxRooms] 限制本次回填的房间数；
  /// - [totalRecordBudget] 限制**本次**索引的总记录数（安全阀）；
  /// - 每 [batchRooms] 个房间主动 `yield` 一次事件循环，避免长同步段卡住 UI；
  /// - 被预算/取消/账号切换截断时**不**标记为已完成回填（[isBackfillComplete]
  ///   保持 false），后续调用可以继续推进，历史不会被永久截断。
  Future<int> backfillLocalHistory({
    int? perRoomLimit,
    int? maxRooms,
    int? totalRecordBudget,
  }) async {
    final account = _accountKey;
    if (account == null) return 0;
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final future = _backfill(
      account: account,
      epoch: index.accountEpoch,
      limit: perRoomLimit ?? defaultPerRoomLimit,
      roomLimit: maxRooms ?? this.maxRooms,
      budget: totalRecordBudget ?? defaultTotalRecordBudget,
    );
    _inFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight, future)) _inFlight = null;
    }
  }

  Future<int> _backfill({
    required String account,
    required int epoch,
    required int limit,
    required int roomLimit,
    required int budget,
  }) async {
    bool sameAccount() =>
        epoch == index.accountEpoch &&
        account == _accountKey &&
        !_cancelRequested;

    final roomIds = await source.localRoomIds();
    if (!sameAccount()) return 0;
    // 本次回填开始的取消代次：只有取消发生在开始之后就放弃。
    _cancelRequested = false;
    var indexed = 0;
    var roomsRead = 0;
    var completed = true;
    for (final roomId in roomIds) {
      if (roomId.isEmpty) continue;
      if (_cancelRequested || !sameAccount()) return indexed;
      if (roomsRead >= roomLimit) {
        completed = false; // 房间上限截断：还有房间未扫
        break;
      }
      if (indexed >= budget) {
        completed = false;
        break;
      }
      roomsRead++;
      final messages =
          await source.readRecentMessages(roomId: roomId, limit: limit);
      if (!sameAccount()) return indexed; // 账号已切换/已取消：丢弃迟到结果
      indexed += _ingest(messages, replace: false);
      // 批次之间让出事件循环：本机库读取与正文投影可能很重，
      // 长时间霸占会让首屏/发送/通话掉帧。
      if (roomsRead % batchRooms == 0) await _yieldToEventLoop();
    }
    if (!sameAccount()) return indexed;
    // 只有真的扫完整个范围才认为「回填完成」——否则后续 ensureBackfilled
    // 仍会继续推进，历史不会被永久截断。
    if (completed) _backfillComplete = true;
    notifyListeners();
    return indexed;
  }

  Future<void> _yieldToEventLoop() => Future<void>.delayed(Duration.zero);

  /// 幂等回填：完成前可重复调用（每次推进一批）。
  Future<int> ensureBackfilled({int? perRoomLimit, int? maxRooms}) async {
    if (_accountKey == null || _backfillComplete) return 0;
    return backfillLocalHistory(perRoomLimit: perRoomLimit, maxRooms: maxRooms);
  }

  /// 显式取消当前回填（账号切换/登出/资源紧张时调用）。
  ///
  /// 语义：放弃**在途**回填并允许下次重新开始。已经索引的内容**保留**
  /// （它仍然来自本机加密库，没有安全影响）；如需彻底清空请用 [clear]。
  /// 在途结果由代次校验丢弃。
  void cancelBackfill() {
    _backfillComplete = false;
    _inFlight = null;
    _cancelRequested = true;
    notifyListeners();
  }

  /// 增量投影（live sync / RoomPage 时间线）：与既有历史**合并**，不重读本机库。
  ///
  /// [replace] = true 时用同一房间的这批消息覆盖该房间已有记录（例如
  /// RoomPage 投影「整条时间线」的场景）；默认合并以保留更早的本机历史。
  int recordRoomMessages(Iterable<LocalSearchMessage> messages,
      {bool replace = false}) {
    final indexed = _ingest(messages, replace: replace);
    if (indexed > 0) notifyListeners();
    return indexed;
  }

  /// E1：按 eventId 删除（消息撤回联动）。命中删除时通知监听者。
  void removeMessages(Iterable<String> eventIds) {
    if (index.removeMessages(eventIds) > 0) notifyListeners();
  }

  /// 账号维度的检索：完全走内存索引，有界且无 I/O。
  List<GlobalSearchMessageHit> search(String query, {int limit = 200}) =>
      index.search(query, limit: limit);

  /// 登出/切号：清空并解绑。
  void clear() {
    _accountKey = null;
    _backfillComplete = false;
    _cancelRequested = false;
    _inFlight = null;
    index.clear();
    notifyListeners();
  }

  int _ingest(Iterable<LocalSearchMessage> messages, {required bool replace}) {
    final byRoom = <String, List<LocalSearchMessage>>{};
    final roomOrder = <String>[];
    for (final message in messages) {
      if (!isIndexableMessage(message)) continue;
      final bucket = byRoom.putIfAbsent(message.roomId, () {
        roomOrder.add(message.roomId);
        return <LocalSearchMessage>[];
      });
      bucket.add(message);
    }
    var indexed = 0;
    for (final roomId in roomOrder) {
      final bucket = byRoom[roomId]!;
      final first = bucket.first;
      index.recordRoom(
        roomId: roomId,
        roomName: first.roomName,
        isGroup: first.isGroup,
        roomAvatarSeed: first.roomAvatarSeed,
        roomAvatarUrl: first.roomAvatarUrl,
        replace: replace,
        messages: [
          for (final message in bucket)
            GlobalSearchMessageRecord(
              eventId: message.eventId,
              senderId: message.senderId,
              senderName: message.senderName,
              timestamp: message.timestamp,
              body: message.body,
              senderIsSelf: message.senderIsSelf,
            ),
        ],
      );
      indexed += bucket.length;
    }
    return indexed;
  }

  /// 该条本地消息是否允许进入索引：文本、非闪照、非媒体占位。
  static bool isIndexableMessage(LocalSearchMessage message) =>
      message.roomId.isNotEmpty &&
      message.eventId.isNotEmpty &&
      !message.isFlashPhoto &&
      isIndexableText(message.body);

  /// 正文是否为可索引的**纯文本**（排除媒体占位正文/裸 mime/data URI）。
  static bool isIndexableText(String body) {
    final text = body.trim();
    if (text.isEmpty) return false;
    if (_mediaPlaceholder.hasMatch(text)) return false;
    if (_rawMediaBody.hasMatch(text)) return false;
    return true;
  }

  /// 用户可见的媒体占位正文（微信/畅聊风格），整条正文完全等于占位符时才算媒体。
  static final RegExp _mediaPlaceholder =
      RegExp(r'^\[(图片|视频|语音|文件|动画表情|表情|位置|名片|链接|音乐|闪照|语音通话|视频通话|通话)\]$');

  /// 裸 mime / data URI 正文（`image/png`、`video/mp4`、`data:image/...;base64,...`）。
  static final RegExp _rawMediaBody = RegExp(
      r'^(data:)?(image|video|audio)/[A-Za-z0-9.+-]*(;base64,[A-Za-z0-9+/=]*)?$',
      caseSensitive: false);
}
