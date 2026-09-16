# Mi 6 Debug 0.3.92/2122 交付记录（清空聊天记录修复）

日期：2026-09-16 22:18:11 +08（Asia/Hong_Kong）
关联任务：[2026-09-16-clear-chat-history-room-visibility](../workflow/tasks/2026-09-16-clear-chat-history-room-visibility.md)
关联计划：[2026-09-16-clear-chat-history-room-visibility](../../superpowers/plans/2026-09-16-clear-chat-history-room-visibility.md)
关联验证：[2026-09-16-clear-chat-history-room-visibility](2026-09-16-clear-chat-history-room-visibility.md)

本记录只覆盖本次交付，不改变 iOS 与正式版 Android 的发布状态。

## 1. 产物身份

| 项 | 值 |
| --- | --- |
| 最终交付包 | `artifacts/2026-09-16/android-0.3.92-debug-2122/ChatFlow-0.3.92-debug-2122-arm64-rebuilt.apk` |
| 最终包 SHA256 | `5153073e12df8868e4f500924a537c816dfb02051fc814923aedb43adfcf519d` |
| 源码中间包 SHA256 | `8d9229828439e2e23efa468514278ff00002945e21ab75cb21227f219dd94d28` |
| 包名 / 版本 | `com.liuhetong.mobile` / `0.3.92-debug` (2122) |
| ABI | `arm64-v8a` 单架构，debuggable |
| 签名身份 | `CN=ChatFlow Local Diagnostic, OU=Local Testing, O=ChatFlow, C=CN` |
| 证书 SHA256 | `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`（RSA 3072，与设备既有安装一致，未更换密钥） |
| 源码基线 | `8ef5cbac4c80b49a9ad43f54f84a01bedf8dc9c8` + 本次工作树改动 |

构建参数：`flutter build apk --debug --flavor standard --target-platform android-arm64
--build-name 0.3.92-debug --build-number 2122`，保留三个 HTTPS dart-define、
`chatflowParallelDebug=false`。工具：Apktool 2.12.1、Android build-tools 36.0.0、
zipalign `-P 16 -f 4`、Flutter 3.44.9 stable、JDK 17.0.20.8。

## 2. 重建验证

`verify-debug-rebuild.py` 报告（`android-0.3.92-debug-2122/rebuild-verification.json`）：

| 检查 | 结果 |
| --- | --- |
| `manifest_semantics_identical` | true |
| `changed_native_or_flutter_assets` | 空 |
| `unexpected_native_or_flutter_assets` | 空 |
| `changed_smali_classes` | 空 |
| 类数（source / final） | 27313 / 27313 |
| ZIP 条目（source / final） | 948 / 951 |

另通过：`zipalign -c -P 16 4`、`aapt dump badging`（versionCode 2122 / versionName
0.3.92-debug / application-debuggable / native-code arm64-v8a）、
`apksigner verify --verbose --print-certs`（v2 与 v3 方案均通过，证书指纹等于固定身份）。

日志：`artifacts/2026-09-16/build-2122.log`；脚本：
`artifacts/2026-09-16/clear-history-2122-build.ps1`。

## 3. 设备安装

| 项 | 值 |
| --- | --- |
| 设备 | Xiaomi MI 6（`sagit`），adb 序列号 `cbd0156b` |
| 安装方式 | `adb -s cbd0156b install -r`（保留数据覆盖安装，未卸载、未清数据、未降级） |
| 安装结果 | `Success` |
| 设备版本 | `versionCode=2122`、`versionName=0.3.92-debug`、targetSdk 36 |
| `firstInstallTime` | `2026-09-11 00:42:05`（安装前后未变 → 原应用数据保留） |
| `lastUpdateTime` | `2026-09-16 22:18:11` |
| 回读校验 | `pm path` 拉回 `base.apk`，SHA256 等于候选包 `5153073e…fcf519d`；其签名证书 SHA256 等于固定身份 |
| 安装前版本 | `0.3.90-debug` / 2118 |

日志：`artifacts/2026-09-16/install-2122.log`。临时拉回文件已删除，未保留在证据目录。

## 4. 本次包含的改动

1. 「清空聊天记录」不再把会话移出消息列表（新增 `history-cleared-through` 键，
   `_snapshotRoom` 的 `locallyDeleted` 只读「删除该聊天」的截止时间）。
2. 「聊天信息」页（私聊与群聊）「清空聊天记录」文字改为居中。

详见 [验证记录](2026-09-16-clear-chat-history-room-visibility.md)。

## 5. 待用户真机验收

本包已安装但**未由我启动**。建议按以下路径验收：

1. 打开一个私聊 → 右上角进入「聊天信息」→ 确认「清空聊天记录」文字居中。
2. 点击「清空聊天记录」→ 确认 → 返回「消息」列表，**该会话必须仍然存在**
   （修复前会消失）。
3. 进入该会话，确认聊天记录已清空；退出重进确认仍是空。
4. 让对方发一条新消息，确认会话与新消息正常出现。
5. 在消息列表长按另一会话选「删除该聊天」，确认该会话**仍然会**从列表移除
   （既有行为未被破坏）。
6. 群聊「聊天信息(N)」页重复第 1–2 步。

## 6. 已知限制

- **升级兼容**：本次改动前，若某会话已经用「清空聊天记录」清过历史（老版本写入的是
  删除信号键），该会话仍会保持隐藏，直到收到新消息才恢复。升级不会自动把这类会话
  放回列表——这是为了避免把用户真正「删除该聊天」的会话重新显示出来。
- 未构建 iOS 包，未改动服务端，未做任何生产发布。
- 本次为 debug 包（versionName 带 `-debug`、debuggable），不能作为正式发布产物。
