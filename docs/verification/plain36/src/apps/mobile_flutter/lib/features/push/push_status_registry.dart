import 'matrix_pusher_service.dart';

/// 推送状态注册表：AppHome 装配 pusher 后登记，通知诊断页读取。
///
/// 登出/账号切换必须 [clear]（诊断页不得看到旧账号通道）。
/// 脱敏：本表不持有 CID/token 原值——只透出服务对象的脱敏 getter，
/// 渲染层负责只显示存在性（已获取/未获取），绝显示原值。
final class PushStatusRegistry {
  PushStatusRegistry();

  static final PushStatusRegistry shared = PushStatusRegistry();

  final List<MatrixPusherService> _services = [];

  List<MatrixPusherService> get services => List.unmodifiable(_services);

  void register(MatrixPusherService service) => _services.add(service);

  void clear() => _services.clear();
}
