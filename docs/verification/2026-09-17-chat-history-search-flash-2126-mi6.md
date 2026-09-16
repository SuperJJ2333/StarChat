# Mi 6 Debug 0.3.92/2126 交付记录（日期查询 / 全局搜索 / 闪照隐私 / 屏幕捕获安全）

日期：2026-09-17 05:46:47 +08（Asia/Hong_Kong）
关联验证：[2026-09-17-chat-history-search-flash-screen-security](2026-09-17-chat-history-search-flash-screen-security.md)
源码：`6d1dcdac`（本批 A–E 五项修复）；基线 `08f1fc3d`
工作树 `D:\pythonProject\outsource\StarChat`，分支 main（未 push）

本记录只覆盖本次交付；不改变 iOS 与正式版 Android 的发布状态。

## 1. 产物身份

| 项 | 值 |
| --- | --- |
| 最终交付包 | `artifacts/2026-09-17/android-0.3.92-debug-2126/ChatFlow-0.3.92-debug-2126-arm64-rebuilt.apk` |
| 最终包 SHA256 | `7ca01bb1c035355c0ad94b331d3b6e21f302fa7cf211307997a0d26df4ee4942` |
| 源码中间包 SHA256 | `211153541dd5b9fe1aceb0f91a1abf21c7e93365165decbf8bcb4163cdb025e6` |
| 包名 / 版本 | `com.liuhetong.mobile` / `0.3.92-debug` (2126) |
| ABI | `arm64-v8a` 单架构，debuggable |
| 证书 SHA256 | `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`（未更换密钥） |
| 构建参数 | `flutter build apk --debug --flavor standard --target-platform android-arm64 --build-name 0.3.92-debug --build-number 2126`，三个 HTTPS dart-define，`chatflowParallelDebug=false` |
| 工具 | Apktool 2.12.1、build-tools 36.0.0、zipalign `-P 16 -f 4`、Flutter 3.44.9 / Dart 3.12.2、JDK 17.0.20.8 |
| 构建脚本 | `artifacts/2026-09-17/chat-history-search-flash-2126-build.ps1`（沿用固定重建/签名流程，仅 versionCode 递增；新增 `-Mode Pull` 设备回读校验） |

**本包内容**（相对已安装 2125）：

1. **A 聊天历史日期查询**：日期 metadata 与时间线正文解耦（`RoomHistoryDayIndex`）、
   月历 typed 六态（有消息／确认无／未知／加载中／失败／未来）、未知日期保持可点且不伪装成“无消息”、
   最早月份不再回退 1970、月查询有界（≤2 次 `timestamp_to_event`、各 5s、不加载正文/媒体）、
   月索引 anchor 直达定位。
2. **B 全局搜索**：typed 结果（联系人／群聊／聊天记录，每区 ≤3 条 + 更多入口，多条命中聚合到会话页）、
   设备侧内存索引与真实解密聊天记录检索、debounce 250ms + 过期结果抑制、
   修复“空查询把全部联系人/群名/聊天正文平铺”的缺陷、room+event 锚点跳转并高亮。
3. **C 闪照隐私**：修搜索投影丢失 `isFlashPhoto`（闪照混入普通媒体资产）、
   普通大图 Gallery 数据集不含闪照（邻居预取不再触碰闪照 loader）、
   普通查看器/转发对闪照 fail-closed。
4. **D** 闪照查看时长 5 秒 → **3 秒**。
5. **E 屏幕捕获安全**：Android `FLAG_SECURE` + 原生租约引用计数（首个租约开启、归零才清除、
   重申只重新应用）；闪照查看器在录屏/投屏中禁止显示、捕获开始/系统截图/退后台立即销毁、
   动态水印、销毁态文案。iOS 侧只上报捕获状态与截图后销毁（**不声称阻止截图**）。

> 说明：`pubspec.yaml` 仍为 `0.3.92+2121`，版本号由命令行 `--build-name/--build-number` 冻结；
> 实际清单为 2126 / 0.3.92-debug（见第 2、3 节证据）。

## 2. 重建验证

`rebuild-verification.json`（`android-0.3.92-debug-2126/`）：

| 检查 | 结果 |
| --- | --- |
| `manifest_semantics_identical` | true |
| `changed_native_or_flutter_assets` / `unexpected_native_or_flutter_assets` | 空 / 空（336 项原生与 Flutter 资产逐项比对） |
| `changed_smali_classes` | 空 |
| 类数（source / final） | 27316 / 27316 |
| ZIP 条目（source / final） | 948 / 951 |

另（`artifacts/2026-09-17/verify-2126.log`）：

- `zipalign -c -P 16 4` → 退出码 0；
- `aapt dump badging` → `com.liuhetong.mobile` / `versionCode='2126'` / `versionName='0.3.92-debug'` /
  `application-debuggable` / `native-code: 'arm64-v8a'` / targetSdk 36；
- `apksigner verify` → Verifies（v2+v3），证书 SHA-256 `75b31c66…ba61fff`（固定身份，RSA 3072）。

构建日志：`artifacts/2026-09-17/build-2126.log`；构建前后 `pubspec.lock` hash 由脚本冻结且一致
（`source-input-sha256-before/after.json`），源码 commit 记录在 `android-0.3.92-debug-2126/source-commit.txt`。

## 3. 设备安装

| 项 | 值 |
| --- | --- |
| 设备 | Xiaomi MI 6（`sagit`，Android 9），adb `cbd0156b` |
| 方式 | `adb install -r`（保留数据覆盖安装，未卸载、未清数据、未降级） |
| 结果 | `Success` |
| 版本 | `versionCode=2126`、`versionName=0.3.92-debug`、targetSdk 36 |
| `firstInstallTime` | `2026-09-11 00:42:05`（安装前后未变 → 原数据/登录态保留） |
| `lastUpdateTime` | `2026-09-17 05:46:47` |
| 安装前版本 | `0.3.92-debug` / 2125 |
| 回读校验 | 拉回设备 `base.apk`（144,625,963 字节）SHA256 = `7ca01bb1…ee4942`（等于候选包），证书 = 固定身份 |

日志：`artifacts/2026-09-17/install-2126.log`（安装）与 `readback-2126.log`（回读校验，临时文件已删除）。

## 4. 建议的真机验收用例

**A 聊天历史日期**
1. 私聊/群聊 → 聊天记录搜索 → 点日期图标：日历应立即显示当月“有消息/无消息”状态，**不需要先滚动聊天记录**。
2. 切到更早的月份：不应出现长时间转圈或“历史范围尚未加载完成，请重试该日期”这类技术文案；
   若某月无消息应显示“本月没有聊天记录”，未知日期仍是普通可点文字（不是灰掉）。
3. 点一个**没有本地记录**的较早日期（灰显之外的普通日期）：应做一次有界查询后定位并高亮该日最早一条消息。
4. 一直往前翻月：日历不应能翻到 1970 年；翻到房间创建之前应提示无记录。
5. 弱网/断网时点日期：应给出可重试的提示，不能显示成“本日暂无聊天记录”。

**B 全局搜索**
6. 打开搜索页（消息列表/通讯录/发现入口）：**不应**再平铺所有联系人与聊天记录；应只有搜索框。
7. 输入关键词：出现「联系人 / 群聊 / 聊天记录」分区（每区最多 3 条 + “更多”入口），
   关键词高亮；快速连续输入不应出现旧关键词的结果闪回。
8. 点单条聊天记录命中：应打开对应房间并定位+高亮该条消息。
9. 某会话命中多条 → 进“更多”记录页，逐条点开都能定位到对应消息。
10. 私聊不应出现在「群聊」分区；断网时搜索应安全降级（不崩溃、不空白卡死）。

**C/D 闪照**
11. 长按闪照气泡查看：倒计时/提示为 **3 秒**，到时自动销毁，再点气泡提示已销毁。
12. 普通图片长按转发/多选/大图左右滑动：闪照**不应**出现在普通图片 Gallery 或“图片和视频”历史里。
13. 闪照气泡长按菜单：不应出现「转发」。

**E 屏幕捕获安全（重点）**
14. 打开闪照后**立即**用系统截图（音量下+电源）：应提示无法截取/截图内容为黑（`FLAG_SECURE`），
   且最近任务列表里该应用预览应为空白/隐藏。
15. 开始系统录屏后再打开闪照：应显示「正在录屏或共享屏幕，无法查看闪照」，长按也不显示原图。
16. 查看闪照的过程中开始录屏/投屏：原图应立即消失并进入销毁态（不可恢复）。
17. 查看闪照时按 Home 退到后台再回来：闪照应已销毁，不自动恢复原图。
18. 查看中应能看到「闪照 · 仅限当前查看」水印。
19. 如需验证 iOS：iPhone 上录屏时打开闪照应被阻断；系统截图后闪照应立即销毁
    （**iOS 无法阻止截图本身**，只能事后销毁，这符合设计边界）。

## 5. 未执行项与限制

- **未构建 iOS**、未做正式发布；本包为 debug（debuggable），不可作为正式产物。
- 服务端未改动；本次未做生产部署。
- 测试复用依据：本轮源码（`6d1dcdac`）已在本地跑过 `flutter analyze`（No issues found）与全量
  `flutter test` **2826 通过 / 0 失败（退出码 0）**（日志
  `artifacts/2026-09-17/flutter-full-stage3-final.txt`）；重建前后 `pubspec.lock` 与源码输入 hash
  由脚本冻结且一致，故未重复整套门禁。
- **能力边界（不得夸大）**：无法阻止用另一台物理设备拍摄屏幕；iOS 无官方截图阻止 API
  （仅在截图完成后销毁 + 录屏时段禁止显示）；部分定制 ROM/root/无障碍截屏工具可能绕过
  `FLAG_SECURE`；销毁仅释放 `Uint8List` 引用，不声称内存零化。
- 功能与手感由用户自行真机验收；本次未在设备上启动应用做交互测试（按用户要求由用户测试）。
