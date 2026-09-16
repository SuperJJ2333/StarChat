# Mi 6 Debug 0.3.92/2124 交付记录（群聊转账/专属红包第三方展示、红包总额、好友资料昵称）

日期：2026-09-17 00:35:11 +08（Asia/Hong_Kong）
关联验证：[2026-09-17-redpacket-transfer-profile](2026-09-17-redpacket-transfer-profile.md)
基线 commit：`5d43ce34`；本任务源码提交 `35090fd0`（工作树 `D:\pythonProject\outsource\StarChat`，分支 main，未 push）

本记录只覆盖本次交付；不改变 iOS 与正式版 Android 的发布状态。

## 1. 产物身份

| 项 | 值 |
| --- | --- |
| 最终交付包 | `artifacts/2026-09-17/android-0.3.92-debug-2124/ChatFlow-0.3.92-debug-2124-arm64-rebuilt.apk` |
| 最终包 SHA256 | `8ff43006076792adda13adc66752b232ec1295f6e574d8e54b16ec4b1c98c52d` |
| 源码中间包 SHA256 | `9118503260c66c7fd5cbda9d4c5d3e2457bbfe2ebdf19fed5b136e9e356ad331` |
| 包名 / 版本 | `com.liuhetong.mobile` / `0.3.92-debug` (2124) |
| ABI | `arm64-v8a` 单架构，debuggable |
| 证书 SHA256 | `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`（未更换密钥） |
| 构建参数 | `flutter build apk --debug --flavor standard --target-platform android-arm64 --build-name 0.3.92-debug --build-number 2124`，三个 HTTPS dart-define，`chatflowParallelDebug=false` |
| 工具 | Apktool 2.12.1、build-tools 36.0.0、zipalign `-P 16 -f 4`、Flutter 3.44.9 / Dart 3.12.2、JDK 17.0.20.8 |
| 构建脚本 | `artifacts/2026-09-17/redpacket-profile-2124-build.ps1`（沿用 2123 固定签名流程） |

> 说明：`pubspec.yaml` 仍为 `0.3.92+2121`，与上一版 2122/2123 相同，版本号由命令行显式
> `--build-name/--build-number` 冻结；本包实际清单为 2124 / 0.3.92-debug（见第 2、3 节证据）。

**本包内容**：用户本次三项报障的客户端修复（群聊第三方转账/专属红包只读卡片与本地展示名、
领取详情页不渲染空总额、好友资料页昵称行）+ 转账/红包引用消息新增收款对象账号标识
（`transfer_receiver_id/_matrix_id`、`red_packet_mode/_recipient_id/_recipient_matrix_id`）。

## 2. 重建验证

`rebuild-verification.json`（`android-0.3.92-debug-2124/`）：

| 检查 | 结果 |
| --- | --- |
| `manifest_semantics_identical` | true |
| `changed_native_or_flutter_assets` / `unexpected_…` | 空 / 空（336 项原生与 Flutter 资产逐项比对） |
| `changed_smali_classes` | 空 |
| 类数（source / final） | 27313 / 27313 |
| ZIP 条目（source / final） | 948 / 951 |

另（`artifacts/2026-09-17/verify-2124.log`）：

- `zipalign -c -P 16 4` → 退出码 0；
- `aapt dump badging` → `com.liuhetong.mobile` / `versionCode='2124'` / `versionName='0.3.92-debug'` /
  `application-debuggable` / `native-code: 'arm64-v8a'` / targetSdk 36；
- `apksigner verify` → Verifies（v2+v3），证书 SHA-256 `75b31c66…ba61fff`（固定身份）。

## 3. 设备安装

| 项 | 值 |
| --- | --- |
| 设备 | Xiaomi MI 6（`sagit`，Android 9），adb `cbd0156b` |
| 方式 | `adb install -r`（保留数据覆盖安装，未卸载、未清数据、未降级） |
| 结果 | `Success` |
| 版本 | `versionCode=2124`、`versionName=0.3.92-debug`、targetSdk 36 |
| `firstInstallTime` | `2026-09-11 00:42:05`（安装前后未变 → 原数据保留） |
| `lastUpdateTime` | `2026-09-17 00:35:11` |
| 安装前版本 | `0.3.92-debug` / 2123 |
| 回读校验 | 拉回 `base.apk` SHA256 = `8ff43006…98c52d`（等于候选包）；证书等于固定身份 |

日志：`artifacts/2026-09-17/install-2124.log`。临时拉回文件已删除。

## 4. 建议的真机验收用例

1. **群聊转账（A1）**：用 A 账号在群里给 B 发一笔转账；用第三方账号 C（**同一个群**）查看该卡片。
   预期：卡片显示金额 + 「转给B的备注或昵称」，底部左侧「转账」；
   **不出现**「加载状态失败，请重试」「对方转给你」「重试」，也不再间歇性刷新出错误文案。
   点卡片应无反应（第三方不可操作）。
2. **专属红包（A2）**：A 在群里发「专属红包」并指定 B；用 C 查看。预期：显示「给B的备注或昵称的专属红包」，
   不出现「无权查看该状态」与「重试」。B 自己仍可正常拆红包。
   **注意**：请用 2124 重新发送这两条消息再测；2123 及更早发送的旧消息没有收款对象信息，
   只会显示中性文案「转账」/「专属红包」（仍无错误文案与重试）。
3. **红包领取详情（A3）**：A 发一个群红包后，用未领取的 C 点开红包弹窗 →「看看大家的手气」。
   预期：顶部**不再出现「null 点钻」**（不显示总额），列表仍是各人领取记录；
   A 自己打开能看到总额；红包被领完或过期后，C 再打开也能看到总点钻数额。
4. **好友资料页（A4）**：打开某好友资料页（该好友既设置了备注、也有昵称）。
   预期：标题显示备注（本机展示名），下方「昵称：」行显示对方**昵称**，不再重复显示备注。

## 5. 未执行项与限制

- 未构建 iOS，未做正式发布；本包为 debug（debuggable），不可作为正式产物。
- 业务 API 同时更新（`starchat-business-api:redpacket-total-20260917`，2026-09-17 00:34 +08 切换，
  健康/401/配置一致性/候选演练证据见验证记录 3.3–3.4），客户端第 3 项验收依赖该部署。
- 旧消息（2124 之前发送）不含收款对象标识，无法显示「转给xx」/「给xxx的专属红包」，
  显示为中性文案；如需覆盖旧消息需新增服务端脱敏字段，属新范围。
- 功能均由用户自行真机验收；本任务未在设备上启动应用做交互测试。

