# 发送方本地排序修复与 Mi 6 debug 验证

用户授权：修复发送方消息错位、退出重进恢复的问题，推送同 debug 签名测试包到 Mi 6，保留数据。

Root owns room_timeline_controller.dart、对应排序测试及必要接线；不改钱包、业务 API、消息正文或 E2EE。
根因确认后的必要接线范围增加 matrix_room_timeline_adapter.dart 的 SDK 本地回声标志、定制 SDK timeline.dart 的低状态回包覆盖保护及 CHATFLOW_PATCH.md。不修改实际发出的消息正文。
1. 对照 SDK 时间戳、乐观消息与服务器回声合并，先复现手机时钟偏差下的乱序。
2. 待确认气泡保持本次插入位置；服务器确认后以服务器时间为准，不能会话内永久覆盖为手机时间。保留稳定 transaction key 和失败消息原位。
3. 执行回归、静态分析、仓库检查与独立审查；从当前含钱包的源码构建 ARM64 debug。
4. 核对 Mi 6 包版本与证书，固定 debug 密钥重建、签名、资源/DEX/资产核验后 adb install -r，不能卸载或清数据。记录启动结果及未做真实收发的验收边界。
