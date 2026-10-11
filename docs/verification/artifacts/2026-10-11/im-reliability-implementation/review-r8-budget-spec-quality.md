# R8 活动媒体预算独立复审

对象作者82a8eca515b81a8747d2a45ea6992a3b0af8a8d8 → 集成9b9ab4d7，root非作者；先规格/领域、再质量安全。实际检查完整预算状态机及全部生产diff、作者边界/限制与关键测试。

规格：PASS（活动执行预算这一有界子任务）。192MiB全局完整峰值准入，源/密文/下载/估算解码分类，4N普通Uint8List和5N普通List适配。超过单任务上限立即可操作失败，排队64上限；状态取消不等于底层future结束。bounded file/openRead、无Content-Length分块流硬限额、实际SDK direct/lease send和emoji通路接线，转码后检查，保留服务器更小上限及同txid。

质量安全：PASS（源码候选）。父子整峰值复用与retain直到实际settle；并行子任务拒绝代替自等待死锁；source Zone显式捕获，旧owner Zone不复用。账号generation/lease/room权限及SDK密文完整性继续检查；ADR-0060加密算法/服务器明文边界未变。缓存损坏重载清理旧强引用后读取；lease.cancel未释放实际仍运行的工作额度。

独立实际运行5个测试文件46PASS、exit0，日志r8-budget-independent.txt（budget/admission/download/content_addressed/native_download）。含SDK密文与同txid、未知长度溢出、pending传输取消、权限/lease路径、容量限制和源增长；作者127项与analyze0为补充。执行在本轮复审期间完成，单步精确起止未完整记录。

交付限制：普通文件约48MiB、图片/视频约31.5MiB（还取现有20MiB图片等更小业务限制）是用户可感知变化；最终包必须包含RoomPage明确提示及durable不可重试映射。native相册originalBytes与prepared队列持有源仍属后续，不能把本提交称为完整OOM修复。固定64MiB解码是准入估计，非原生/GPU/GC/RSS硬封顶；驻留缓存另有预算。100MiB流式加密/上传、帧率和50次设备生命周期未测。
