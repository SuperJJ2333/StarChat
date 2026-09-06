# 冷启动推送唤醒补发

## 范围和发现

承接用户“请你继续”，按 `docs/superpowers/plans/2026-09-05-incoming-call-permission-dedup.md` 的 continuation 执行。

原生 `NativePushBridge` 在无 Flutter 引擎时只尝试启动 Activity，没有保留唤醒；有引擎但 Dart 尚未注册监听时直接发送且不检查回执。MainActivity 销毁引擎时也未清理推送桥。这些是推送已到达 SDK 后仍可能丢失同步机会的独立缺陷。

## 实现

- 主进程的 Getui 回调只暂存 `pushMessage` / `friendRequest` 两类同步信号。同类合并、最多两个条目、两分钟有效期；SharedPreferences 仅含类别和时间戳。
- Dart 注册处理器后发 `pushListenerReady`，原生才发送；成功回执才移除对应条目。失败保留到下一次就绪/新唤醒；没有无限重试循环。
- 新唤醒不会被旧回执删除；监听停止、引擎替换使用代次隔离过期回调。引擎重建可重新读取暂存信号。
- MainActivity 传入 applicationContext，并在引擎清理时销毁桥接监听。后台启动 Activity 抛出运行时异常时不使 SDK 回调崩溃。
- Flutter 旧页面销毁不会取消新页面已经注册的监听。未知事件不返回成功确认。

## 验证和评审

先运行新测试：Dart 冷启动补发预期 1 次、实际 0 次；原生 3 项测试均失败，记录 `artifacts/2026-09-05/incoming-call-permission-dedup/push-wake-red.log`。

修复后：原生冷启动推送 6 项及既有通话 8 项全部通过；Flutter push 目录 27 项全部通过；修改的 Dart 文件定向 analyze 无问题。原生与 Dart 日志分别为同目录 `push-wake-green.log`、`push-wake-dart.log`。

完整仓库校验首轮邀请码测试 `test_referral_validate_endpoint_limiting_and_behavior` 出现 valid=false（337 passed / 1 failed / 19 skipped），该测试单独复跑通过；不改该业务代码，再次完整执行 `scripts/verify.ps1` 最终 `Verification: PASS`。两轮结果均保留，不能把首次失败解释为已证实的时钟边界问题。记录为 `push-wake-repository-verify.log`、`push-wake-referral-recheck.log`、`push-wake-repository-recheck.log`。

规格符合性自审：唤醒只启动本地同步，不建立通话、不请求媒体权限；与现有权限拒绝后保持响铃的修复兼容。有效期防止长时间后回放旧兜底提醒；正常启动仍执行 Matrix 同步。

质量/安全自审（规格审查之后）：缓存无账号、房间、消息、来电身份或密钥；类型白名单固定；内存有界；失败回执不会循环；退出/替换的延迟回执不能清除新事件。本次未改变服务器推送协议、E2EE、权限声明或签名。

## 仍未完成的外部条件

这不是“杀进程后必达”的完整解决方案。厂商通道缺口仍见 `docs/PUSH_SETUP.md` §0.2：目前项目没有完成 MiPush 等 SDK/应用标识集成，也没有已验证的个推控制台 OEM 通道配置。用户已被询问是否有对应配置位置，不能伪造凭据。

个推官方接入指南说明：CID 离线时须有对应厂商通道配置，未开通时消息存入个推离线队列，待 CID 重新在线后再发。参考 https://docs.getui.com/getui/start/accessGuide/ 。系统展示的厂商通用通知可能先于设备解密；本地通知 ID 42001 的去重并不能据此撤销任意厂商通知。新增事件关联前还需核实 SDK 对 notify_id 的映射并审查最小元数据协议，不能 cancelAll 清掉其他聊天提醒。

## ARM64 测试包

已按 `docs/runbooks/android-apk-rebuild.md` 完成 0.3.42+45 的源码构建、Apktool 2.12.1 常规重建、16 KiB zipalign、固定签名、再次解包核验。未启用 Dart 混淆、R8、资源缩减或加壳。

- 最终文件：`artifacts/2026-09-06/push-cold-start/rebuild-0342/ChatFlow-0.3.42-arm64.apk`
- Android versionCode：2045；ABI：arm64-v8a；大小：75,273,156 字节。
- SHA256：`3cb1ff75404863fe7bd089bf6406bd28aa92812ac53e0f502ff98382b4510fea`
- 证书 SHA256：`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`；v2/v3 签名有效；签名后对齐检查通过。
- 24,573 个类 smali 核对一致（仅严格归一化静态默认值）；331 个原生库/资产条目逐字节一致；完整清单语义一致；5 个 DEX 和资源表重建。

构建参数、可重现脚本、签名核验、badging 和逐项检查见该产物目录及其上一级 `source-build.log`。最终包包含此前 0.3.41 的通话权限与本地通知去重修复，以及本次冷启动补发。未安装或上线，未发布更新弹窗；尚未进行 MI 6 / HyperOS 进程退出后的真机来电测试。此前交付的 0.3.41 APK 不包含本次新增修改。
