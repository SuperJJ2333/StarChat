import 'package:permission_handler/permission_handler.dart';

import 'call_controller.dart';

/// 系统权限 API 实现的通话权限网关。
///
/// 此前实现（0.3.32 及之前）用 getUserMedia 创建一个真实 WebRTC 媒体流
/// 来触发系统弹窗、随即销毁——既浪费媒体设备（视频探测会点亮摄像头
/// 指示灯），又与 SDK 在 invite 阶段的 getUserMedia 叠加成两次探测。
/// 现在改为纯系统权限 API（permission_handler），不再触碰媒体流。
final class SystemCallPermissionGateway implements CallPermissionGateway {
  const SystemCallPermissionGateway();

  @override
  Future<bool> request({required bool video}) async {
    final requests = <Permission>[
      Permission.microphone,
      if (video) Permission.camera,
    ];
    try {
      final statuses = await requests.request();
      final granted = statuses.values
          .every((status) => status.isGranted || status.isLimited);
      return granted;
    } catch (_) {
      // 权限服务异常按拒绝处理：绝不在无麦克风权限时继续通话。
      return false;
    }
  }
}
