/// 投诉提交网关（中立定义，便于页面与业务客户端解耦测试）。
abstract interface class ComplaintGateway {
  Future<Map<String, dynamic>> submitComplaint({
    required String category,
    required String description,
  });
}
