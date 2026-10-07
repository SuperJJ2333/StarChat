# 2203 资源与弱网历史连续性缺陷修复计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development or executing-plans to implement this plan task-by-task.

**Goal:** 恢复已批准的正常 emoji/图标资源交付与连续历史浏览，排除旧请求跨消息片段污染，并用实际性能证据核对服务器卡顿。

**Architecture:** 继续既有已批准历史窗口/上下文与 Android 标准重建方案，不变更通信、鉴权或财务契约。资源门禁检查原始与最终 APK 的实际清单/字体/源资源；历史 SDK 请求绑定 limited-sync 片段代次，普通阅读固定为独立历史片段而保留后台 live 时间线。

**Tech Stack:** Flutter 3.44.9/Dart 3.12.2、vendored Matrix SDK、现有 SQLCipher DatabaseApi、Python、Apktool 2.12.1、Android build-tools 36.0.0。

**Spec:** `docs/superpowers/specs/2026-08-12-starchat-product-modernization-design.md`；延续 `2026-10-03-mobile-ui-push-2196.md`、`2026-10-04-search-date-context-followup.md` 已批准历史行为与 `docs/runbooks/android-apk-rebuild.md`。范围来源为用户 2026-10-07 四项缺陷反馈及服务器排查要求；不增加新产品功能。SSH 加固另列具体配置并等待用户选择，不归入移动源代码。

## Global Constraints

- Matrix 通信内容/密钥不进入服务器日志或业务诊断；保留已有解密、读取权限和账号隔离。
- 每个源文件单一代理所有权。root 仅承担根文档、构建/版本与整体验证；字体代理拥有资源门禁及 Python 测试；历史代理拥有列明的 SDK/窄适配器方法及行为测试。
- 验证临时产物只在 `docs/verification/artifacts/2026-10-07/history-icons-performance/`。
- 单一源码与输出路径拼写、独立本次 build 缓存，禁止复用 C:/S: 两种路径拼写的旧输出记录。依赖锁保持基线 SHA `ac0966cb75f61763073bfc48ef5e8b93b85cf6cf46ebaa921d8b3739c62694ac`。
- 最终候选冻结后一次 focused/analyze/Flutter 全量；verify.ps1 先预检，本地 .env/local.env 不存在则如实记未执行，不引入生产秘密。
- Android 最终交付标准 DEX/资源/manifest 重建、对齐及固定 75b31… 签名；保留数据安装，不自动卸载/清数据。正式移动发布尚未执行。

## Review Focus

- limited sync 正好在历史 HTTP 或缓存读取 await 内返回，旧响应不能覆盖新 token、写入新片段或移走可见锚点。
- 普通 nonlimited sync 并发新增消息时合法历史仍须接入，不能把任何 token 变化都视为失效。
- 只加载 30 行但数据库还有更多本地历史，固定窗口后不能使用数据库末端 token 跳过未加载行。
- 固定历史保持撤回、隐藏、解密与账号撤销边界；live newest 与明确返回最新入口正常，不能伪造 forward token。
- 原始/最终 APK 都可能同样缺资源，因此 source→final 相等不能代替实际资源完整性；清单、字体引用、emoji 声明与源字节均检查。

## Task 1: APK 资源完整性与唯一构建路径

**Files:** `scripts/verify_android_flutter_assets.py`；`tests/mobile/test_android_flutter_asset_bundle.py`；本任务独立 Android 构建 driver。接口 `validate_apk(apk, mobile_root, flavor='standard')` 与 CLI `--mobile-root/--flavor`。

- [x] 用实际旧 2203 APK 证明 FontManifest/AssetManifest/emoji/font 缺失；对完整合成 bundle、缺失字体/emoji、错误 manifest/目录引用、源字节漂移写失败行为用例。
- [x] 最小实现：解析 AssetManifest.bin/FontManifest.json，要求 Material/Cupertino 字体与全部声明的资源成员非空、emoji catalog 与源 SHA 一致。
- [x] 22 项资源门禁与 5 项相邻发行测试转绿；实际 2203 source/final 仍 exit1。保留真实 RED。
- [ ] root 新候选构建只使用本工作树同一种路径与独立缓存，在 source、final 两处调用门禁；标准重建/对齐/固定签名与原有语义门禁全部通过。
- [x] 资源门禁已先独立规格审查、再质量/安全审查接受；实际新 APK 仍需现物审查。

## Task 2: 片段请求所有权与固定历史浏览

**Files:** `apps/mobile_flutter/third_party/matrix/lib/src/room.dart`、`client.dart`、`timeline.dart`；`apps/mobile_flutter/lib/features/matrix/matrix_e2ee_client.dart` 中 `_SdkRoomTimelineCapability.pinWindow` 及直接辅助；`test/features/matrix/history_pagination_continuity_test.dart`。

**Interfaces:** `Room` 的片段代次在 limited sync 替换之前失效；`requestHistory` 捕获代次并在网络/存储/发布 await 边界检查；`Timeline.forkHistory()` 返回独立历史 timeline，loaded Event 引用及缓存 ID 游标保持原片段，使用现有 DatabaseApi 公共读取接口，必要时通过真实 `/context` 获取有效历史 token。

- [x] 真实 SDK 延迟诊断：20/19 日缓存 → limited sync 30 日 → 旧分页18/17 日，复现30/18/17、旧19日锚点消失与新 token 被覆盖；无同步及 nonlimited 对照保留连续片段。
- [x] 正式失败行为用例：旧响应拒绝、合法 nonlimited 响应接入、固定后 cached 未加载行可依次读取、limited sync 保留可见行/live newest、返回最新与撤回边界。
- [x] 最小代次 guard 与 forkHistory，禁止将不同片段静默拼为连续历史或伪造 nextBatch。
- [x] 54 项 focused 与相邻 SDK/历史窗口/上下文/真实列表锚点回归；独立规格和质量/安全审查接受，另对既有实际 RoomPage 的真实反向滑动 transport fixture 做增量复核。

## Task 3: 生产证据与最终候选验收

- [x] 查实际 CPU/内存/进程、日志保留、Synapse 请求延迟和当前 PostgreSQL 锁；按用户最近一小时关联 Android 2202 诊断，区分 wall-time 与 CPU 时间。
- [x] 用户确认未部署 xmrig；已复核进程身份后保留 root-only 取证，stop/disable exit0，业务容器身份/重启数保持，对比资源压力下降。
- [x] 核对真实同步阶段与假同步：历史/本地发送 handleSync 的 processing(progress 非空) 会污染 watchdog/房间开页的实际响应标记，把长轮询残余计入 processing；真实无网络 SDK probe 已证明。
- [x] `matrix_sync_watchdog.dart` 与 `room_page.dart` 的窄性能计时入口只采纳真实 processing(progress=null)；watchdog 在真实 processing 边界之后继续接收活跃处理进度心跳，等待 HTTP 时的假进度不能延迟卡死判断。`matrix_sync_watchdog_test.dart` 和现有 `room_page_anchor_navigation_test.dart` 先证明污染与健康/卡死判断，再转绿；原 UI progress 流保留。82 项 focused PASS，独立 SPEC/QUALITY 接受。
- [ ] 冻结候选版本/源码/依赖输入，适用门禁和独立整体现物 review；标准 APK 保留数据安装、版本/包 SHA 读回与图标/弱网列表交互验收。
- [ ] 更新本任务台账/证据和当前状态索引；记录已止损、移动候选、正式发布与真机反馈的不同状态。
