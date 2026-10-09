# 用户操作优先及资源/更新 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Independent domains use dispatching-parallel-agents, sequential integration and final fresh review.

**Goal:** 旧历史后台整理期间可正常收发与浏览，清理发布资源、按需动态表情、Android流式差分安装，并向已连接模拟器安装验证debug包。
**Architecture:** 冻结旧历史基线与事务增量层构成过渡权威，后台有界合并；共享交互维护预算协调资源与数据库。资源不可变清单校验后缓存；更新补丁copy/add流式重建完整已签名APK，经SHA与签名校验交系统安装。
**Tech Stack:** Flutter/Dart、Matrix本地fork、SQLCipher、Kotlin/Android、Python分发工具。
**Spec:** ../specs/2026-10-09-mobile-responsive-maintenance-design.md（用户2026-10-09明确批准推进，并授权模拟器debug安装）

## Global Constraints

- 保留账号、消息、钥匙及固定正式签名；不修改金融状态/鉴权/E2EE。
- 交互操作优先，暂停非必需维护，空闲至少500ms再恢复；不以空列表吞掉错误。
- 每页最多256ID，展示模型沿用40初始/200上限；迁移和更新工作缓冲各目标≤8MiB，必须测量而非假称全机型已满足。
- 静态表情、图标及许可证离线可用；动态资源最多1个下载、缓存64MiB；动画并发4、滚动/后台为0。
- 新成品独立版本，2206正式/2207候选不覆写；本轮授权模拟器debug，不自动切正式更新弹窗。
- 所有证据/临时文件位于docs/verification/artifacts/2026-10-09/mobile-responsive-maintenance；原体积实验位置复用。

## Review Focus

1. 普通nonlimited新消息碰到未迁移大房间，另一小房间与首轮sync仍可完成。
2. 旧源读取时新消息确认/移除、limited切代、进程终止，不丢/重复/漂移。
3. 首次离线或坏资源，emoji仍可发并保持布局；内存压力和快滑暂停动画。
4. 安装基线不符、损坏/超限/恶意补丁、空间不足，不执行未验证的APK。
5. 模拟器当前已装正式包与debug不同签名，独立包名安装，不卸载/清用户正式数据。

## Task 1: 非阻塞旧历史过渡层及有界维护

**Files:** third_party/matrix/lib/src/database/timeline_id_store.dart、matrix_sdk_database.dart及相关stub/API；lib/features/matrix/timeline_migration_reader.dart、matrix_client_factory.dart；test/features/matrix/nonblocking_legacy_timeline_test.dart及现有升级测试。
**Interfaces:** 现有prepare/read/add/remove保持可用；过渡快照与revision固定；与公共维护门通过可注入Future<void> Function()协调，不依赖UI类型。
- [ ] 增加held migration reader+nonlimited sync/入房/发送测试，验证现版本因等待而FAIL。
- [ ] 实现legacy base+增量权威，后台准备不阻塞前台；分页快照、删除/echo、limited及reopen一致。
- [ ] 在批次间让出并接受维护暂停，不持锁等待UI；异常保留可读旧权威。
- [ ] 验证升级/rollback/搜索/快照/GC相关测试，25万与100万规模有界缓冲和前台进展证据。
- [ ] 记录RED/GREEN与输入身份，集成后统一commit，不能与其他任务并发git index mutation。

## Task 2: 清理发布资源、动态表情缓存及交互预算

**Files:** pubspec.yaml（资源项，仅此代理修改）；lib/features/emoji/*；lib/core/maintenance_activity.dart新公共接口；ui/chat的emoji显示/面板/media_activity及相关测试；资源生成工具与本任务记录。
**Interfaces:** MaintenanceActivity.instance.setInteractive(reason,active)、waitForIdle()、pressure()；注入可测clock/delay。EmojiResourceStore.resolve(logicalID)返回本地可用资源或静态fallback，fetch失败不得抛至聊天build。
- [ ] 资源打包清单测试证明diagnostics/备用图片当前误入；删除release声明并保留测试fixture源，branding精确白名单。
- [ ] 缓存与manifest白名单/hash/超限/中断测试RED；实现单下载逐文件私有缓存，静态fallback、固定布局，保持Unicode消息格式。
- [ ] 动画/维护idle/pressure/取消测试RED；实现max4预算与快滑/键盘transition/切房/background暂停钩子。
- [ ] 生成不可变资源清单和文件集（不上传），离线/坏网/缓存淘汰及emoji现有测试GREEN。
- [ ] 资源清理完成后才删除动画bundle引用；新下载端点可配置且无token，未发布资源必须可靠fallback。

## Task 3: 流式差分格式、Android更新及安装桥

**Files:** scripts/build_android_delta.py新工具；Android新增update包及专用测试；MainActivity.kt、AndroidManifest.xml/FileProvider xml（此任务独占）；features/update/app_update.dart与更新对话框相关可选metadata扩展及测试。
**Interfaces:** 保留launchAppDownload整包fallback；可选delta descriptor不破坏旧响应。独立CFDELTA协议stream copy/add，老新SHA/patch SHA/长度/签名信任检查。
- [ ] 精确还原/坏基线/非法copy/长度上限/截断测试RED，实现有界流式补丁生成及应用，不沿用整个literal内存的实验脚本。
- [ ] Kotlin流式校验/空间预检/中断/签名不符测试RED，实现低优先级原生worker与受限私有FileProvider/系统安装动作。
- [ ] 无可信metadata不选择补丁，现有接口无delta时保持全包；APK内信任锚与descriptor验证一致，不临时跳过签名检查。
- [ ] 用2206/2207实际签名包测量新协议并精确还原，阈值80%选择规则及完整包fallback测试GREEN。
- [ ] 新原生通道与Flutter参数/用户动作/权限边界测试，iOS不进入Android路径。

## Task 4: 整体验证、debug构建及模拟器验收

**Files:** 本任务记录/证据、debug构建所需已存在配置；集成hook按前3项实际接口协调。
- [ ] 查看设备ABI/API/已装包名与签名；debug采用既有独立包名，不清正式数据。
- [ ] 准备SDK/Java/磁盘/锁，focused GREEN后analyze/最终共享全量/适用verify门禁，缺环境明确保留。
- [ ] 先规格符合性再fresh质量/安全审查，相关问题RED/GREEN修复，禁止以删用例过关。
- [ ] 构建兼容模拟器ABI的debug APK、读取实际manifest/SHA并adb install -r独立debug包。
- [ ] 合成大历史场景验证首屏/收发/键盘/快滑/切房、100次交互与内存/帧日志；实际服务账号由已有模拟器会话授权边界决定，不读取密码或发送未授权消息给他人。
- [ ] 记录实际安装版本/SHA、通过与缺口；模拟器debug性能不等于正式版/真机性能，不宣称任意手机永不卡。

## 执行与阶段状态

2026-10-09用户“好的，请推进你的方案，并且在模拟器上推送debug包”授权直接执行已确认方案及设备安装。此计划是该授权的具体文件和测试分解，未新增功能或额外发布权限；保持连续推进，实施接口变动记入任务台账。
