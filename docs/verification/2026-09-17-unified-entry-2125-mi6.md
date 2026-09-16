# Mi 6 Debug 0.3.92/2125 交付记录（好友资料「发消息」统一入口）

日期：2026-09-17 02:11:13 +08（Asia/Hong_Kong）
关联验证：[2026-09-17-unified-direct-message-entry](2026-09-17-unified-direct-message-entry.md)
源码：`e0fa42c0`（统一入口）+ `21cb52b5` / `457896c4`（2124 的三项聊天修复）；基线 `5d43ce34`
工作树 `D:\pythonProject\outsource\StarChat`，分支 main（未 push）

本记录只覆盖本次交付；不改变 iOS 与正式版 Android 的发布状态。

## 1. 产物身份

| 项 | 值 |
| --- | --- |
| 最终交付包 | `artifacts/2026-09-17/android-0.3.92-debug-2125/ChatFlow-0.3.92-debug-2125-arm64-rebuilt.apk` |
| 最终包 SHA256 | `9fb1302dec3037375624e6d4b5247fcb41a0aecc698557074c29aa3706452c8e` |
| 源码中间包 SHA256 | `5cb79c849db706f86b74c31d6562958f42313d1a065b23b8639fa48fa0afcc11` |
| 包名 / 版本 | `com.liuhetong.mobile` / `0.3.92-debug` (2125) |
| ABI | `arm64-v8a` 单架构，debuggable |
| 证书 SHA256 | `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`（未更换密钥） |
| 构建参数 | `flutter build apk --debug --flavor standard --target-platform android-arm64 --build-name 0.3.92-debug --build-number 2125`，三个 HTTPS dart-define，`chatflowParallelDebug=false` |
| 工具 | Apktool 2.12.1、build-tools 36.0.0、zipalign `-P 16 -f 4`、Flutter 3.44.9 / Dart 3.12.2、JDK 17.0.20.8 |
| 构建脚本 | `artifacts/2026-09-17/unified-entry-2125-build.ps1`（沿用固定签名流程，仅 versionCode 递增） |

**本包内容**（在 2124 基础上）：

1. 本次「好友资料 → 发消息」统一入口：通讯录不再自带第二份实现；新增
   `features/matrix/direct_chat_entry.dart`（`resolveFriendContact` 以业务 userId 为主键、
   `ensureCurrentFriendIdentity` 保留原矩阵索引契约、`DirectMessageOpenGate` 单飞去重）。
2. 2124 已交付的三项修复（本次一并包含，未做任何回退）：群聊第三方转账/专属红包只读卡片
   （「转给xx」/「给xxx的专属红包」，无错误文案与「重试」）、领取详情不再出现「null 点钻」、
   好友资料页「昵称」行显示昵称。

> 说明：`pubspec.yaml` 仍为 `0.3.92+2121`（与 2122–2124 相同），版本号由命令行
> `--build-name/--build-number` 冻结；实际清单为 2125 / 0.3.92-debug（见第 2、3 节证据）。

## 2. 重建验证

`rebuild-verification.json`（`android-0.3.92-debug-2125/`）：

| 检查 | 结果 |
| --- | --- |
| `manifest_semantics_identical` | true |
| `changed_native_or_flutter_assets` / `unexpected_…` | 空 / 空（336 项原生与 Flutter 资产逐项比对） |
| `changed_smali_classes` | 空 |
| 类数（source / final） | 27313 / 27313 |
| ZIP 条目（source / final） | 948 / 951 |

另（`artifacts/2026-09-17/verify-2125.log`）：

- `zipalign -c -P 16 4` → 退出码 0；
- `aapt dump badging` → `com.liuhetong.mobile` / `versionCode='2125'` / `versionName='0.3.92-debug'` /
  `application-debuggable` / `native-code: 'arm64-v8a'` / targetSdk 36；
- `apksigner verify` → Verifies（v2+v3），证书 SHA-256 `75b31c66…ba61fff`（固定身份）。

构建日志：`artifacts/2026-09-17/build-2125.log`。

## 3. 设备安装

| 项 | 值 |
| --- | --- |
| 设备 | Xiaomi MI 6（`sagit`，Android 9），adb `cbd0156b` |
| 方式 | `adb install -r`（保留数据覆盖安装，未卸载、未清数据、未降级） |
| 结果 | `Success` |
| 版本 | `versionCode=2125`、`versionName=0.3.92-debug`、targetSdk 36 |
| `firstInstallTime` | `2026-09-11 00:42:05`（安装前后未变 → 原数据保留） |
| `lastUpdateTime` | `2026-09-17 02:11:13` |
| 安装前版本 | `0.3.92-debug` / 2124 |
| 回读校验 | 拉回 `base.apk` SHA256 = `9fb1302d…6452c8e`（等于候选包）；证书等于固定身份 |

日志：`artifacts/2026-09-17/install-2125.log`。临时拉回文件已删除。

## 4. 建议的真机验收用例

**本次新增（统一入口）**

1. **通讯录入口**：通讯录 → 好友 → 好友资料 → 发消息。应正常打开该好友的加密私聊；
   从朋友圈/群聊进同一好友的资料再发消息，必须进入**同一个**会话（不新建第二个私聊房间）。
2. **快速连点**：在好友资料页对「发消息」连续快速点击多次，只应打开**一个**会话页
   （不再叠加多个相同房间页面）；返回后再点仍可正常打开。
3. **失败与重试**：断开网络后点「发消息」，应弹统一文案的失败弹窗（如「当前处于离线状态，
   请恢复网络后重试。」）并带「重试」；恢复网络点「重试」应能正常进入会话。
4. **已删除好友**：把一个好友删除后，从仍停留在栈上的旧资料页点「发消息」，
   应提示「该好友已不在你的好友列表。」（不提供重试）。
5. **群聊/朋友圈不回归**：群聊非好友群成员仍进「用户资料 / 添加到通讯录」；
   朋友圈非好友仍进资料页，自己（SELF）仍是原行为。

**回归（2124 已交付内容）**

6. 群聊第三方视角的转账显示金额 +「转给xx」、专属红包显示「给xxx的专属红包」，
   无「加载状态失败/无权查看该状态/重试」；请用 2125 重新发送消息测试（旧消息无收款对象标识）。
7. 红包「看看大家的手气」：未领取者不再看到「null 点钻」；发红包者/已领完/已过期才显示总额。
8. 好友资料页「昵称：」行显示对方昵称（备注仍作标题）。

## 5. 未执行项与限制

- **未构建 iOS**、未做正式发布；本包为 debug（debuggable），不可作为正式产物。
- 本次只安装 Android debug 包；服务端未改动（2124 的红包总额可见性 API 已于 2026-09-17 00:34 +08
  部署，验证记录见 [2026-09-17-redpacket-transfer-profile](2026-09-17-redpacket-transfer-profile.md)）。
- 测试复用依据：本轮源码（`e0fa42c0`）已在本地跑过 `flutter analyze`（无问题）与全量
  `flutter test` **2721 通过 / 0 失败**（日志
  `artifacts/2026-09-17/flutter-full-direct-message-entry.txt`），构建前后源码输入 hash 由
  脚本内的 `source-input-sha256-before/after.json` 冻结且一致，故未重复整套门禁。
- 已知遗留（未在本次修复，详见验证记录第 5 节）：从消息列表直接打开的 RoomPage 不经 AppHome，
  从该会话进资料再发消息仍可能叠加同一房间的第二个页面；通话入口仍按入口快照的 `matrixUserId`。
- 功能由用户自行真机验收；本任务未在设备上启动应用做交互测试。
