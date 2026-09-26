# 冷启动缓存优先修复验证

> 2026-09-26 集成交接：下文为当次交付历史；其中“未提交/未合并/未推送”及旧 Debug 下一步只描述 2026-09-24 的状态。对应移动实现已随分支集成进入 `main f820d704`，见[集成记录](../workflow/tasks/2026-09-26-branch-integration-main.md)。本文此后补入版本控制，不表示重新构建、安装或发布；当前设备及生产状态以最新任务的实测为准。

## 范围与版本

用户授权移除正常启动的检查页、缓存优先恢复聊天及头像、后台刷新，并调查重启后的错误撤回预览。源码基线为 main `9cfcd00c7ea5fd0b626a9f432bc8428b0f351b23`，修复已应用主目录并通过最终验证，未提交、打包、安装或发布。其他任务的 Mi6 debug、生产服务及 current-state 更新不属于本次交付。

环境：Windows x64，Flutter 3.44.9 / Dart 3.12.2，PowerShell 7，Python 3.12。依赖版本未变；Flutter 自动将 pubspec.lock 的 hosted URL 改为镜像，核实版本/hash 均一致后恢复原锁文件。锁文件 SHA256：`484A85F5521A3FCCE8C47BF8300C705A9C7F04C28ED82CBFAD85370D9DB05051`。

## 已确认的改动

- `InstallationStartupGate` 正常阶段不构建检查页面，首次本地恢复期间保留平台启动画面；成功、异常和销毁均释放首帧。安装校验失败仍阻止组合应用并允许重试。
- Matrix `init(waitForFirstSync:false)` 保留本地账号、房间、设备密钥载入等待，只将首次网络同步移到后台。
- 只读缓存预览从当前 Matrix 账号的持久化 ProfileRepository hydrate 后生成快照；网络刷新仍由验证后的正式页面执行。延迟旧账号/旧 API 加载不覆盖新页面，外部仓库不被销毁。
- 首次本地快照尚未返回时不展示“暂无消息”；真实空快照返回后才展示空态，切账号重置。
- 头像同步确定性 URL 先访问既有磁盘缓存，再异步确认媒体端点；异步结果复核账号、token、client 和 room lease 生命周期。磁盘 PNG 用例在清空内存图片缓存且能力请求未结束时成功绘制。
- 本地预览中的权威撤回优先于旧解密缓存；两种 redacts 格式及已撤回事件会清除旧明文缓存，当前已撤回事件拒绝晚到解密覆盖。已知加密撤回无需密钥即可显示。

## 撤回问题的证据边界

第一条已复现缺陷是：旧解密缓存使热态错误显示已撤回正文，冷启动缓存消失后显示真实撤回。这一条不足以单独解释用户现场。

用户随后明确“只有个别会话；点进去最后一条仍正常”。据此新增 SQLite 旧缓存 fixture：room.last_event 为旧撤回，但 canonical timeline 第一条为新正常消息，close/reopen 后列表仍错误采用旧撤回。该症状已真实复现，`preview-legacy-red.log` 为 8 通过/8 预期失败。修复改为冷启动从有限 canonical 本地事件校正房间预览，正常消息、真实撤回、发送状态与编辑关系均有护栏；不会通过清库或删除撤回标记掩盖问题。尚未采集用户设备数据库，不能宣称已证明是哪一个历史写入路径形成了该不一致。

SQLite 真实事务回归证明：旧消息撤回后再收到新消息，关闭并重开数据库仍保留新预览；旧历史回放不复活撤回，也不替换最新预览；本地 sending 状态保留。最初未包事务的中断探针与错误 sending 夹具不作为生产根因证据，调查记录见 artifacts 下 `preview-investigation.md`。SDK 仅修改本地恢复投影，不改变同步事务、加密或密钥协议。

## 验证与失败记录

所有日志位于 [本次证据目录](artifacts/2026-09-24/cold-start-cache/)。

**最终结果：Flutter 全量 4011 项通过、exit 0；本次17个 Dart 文件（含 SDK）的静态分析无问题、exit 0；移动边界107通过/1条件跳过；UI契约通过；3524个源文件凭据扫描通过。19个源码/锁文件/SDK补丁说明的 SHA256 已记录并复核一致。**

- 完整命令：在 `apps/mobile_flutter` 执行 `C:/src/flutter/bin/flutter.bat test --no-pub --reporter expanded`，`flutter-final.log` 4011/0，exit 0；runner耗时4分45秒。期间仅补齐新SDK条件语句的大括号，逻辑不变；最终源身份见 `source-hashes.json`。
- `analyze-final-changed.log`：所有变更 Dart 文件及 SDK 文件 `dart analyze --fatal-infos` 无问题，exit 0。首轮专门分析 SDK 发现一处缺大括号 info，已修正后重跑。
- `preview-review-green.log`：真实 SQLite 重启与状态/撤回/解析/读取上限21项通过，exit 0。`preview-review-red.log` 记录3个预期失败（同ID密文ack状态、超时pending构造自愈、坏候选解析）后修正。
- `mobile-boundary-final.log`：107通过、1条件跳过、1密钥扫描另行执行，exit 0；`identity-and-credential-final.log`：19个冻结hash及3524个源文件同规则扫描通过；`ui-contract-final.log`：32组件/403页面通过。

- `startup-red.log`：82 通过、2 预期失败（启动检查页/网络阻塞）；随后两项均在定向回归转绿。
- 头像最初夹具未真正调用能力请求，不能作为有效红证据。修正夹具后禁用同步入口产生 4 预期失败，恢复后 7/7 通过；见 `avatar-valid-red.log` / `avatar-final-green.log` / `avatar-evidence.md`。
- `identity-green-preview-red.log`：4 个缓存撤回断言预期失败；4 个真实 SQLite 回归通过。修复后预览 8 项在 `focused-green.log` 中通过。
- `identity-green-final.log`：身份缓存 5/5 通过；后续补充首次快照前假空态回归。
- `identity-empty-red.log`：假空态预期失败；`identity-empty-fixtures-green.log`：新增6项身份/空态及原会话投影、跳转、预览等共24项通过，exit 0。
- 首轮完整 Flutter：`flutter-full.log`，3985 通过、8 失败，exit 1。失败为旧只读预览 fixture 未注入资料仓库、假定同步即完成；按原测试目标显式注入 caller-owned 内存仓库，真实持久化路径由新增身份测试独立覆盖。没有删除相关断言。
- 全量 `dart analyze --fatal-infos`：exit 1，两个基线已有 info（未变的 `test/features/moments/moment_video_test.dart:25,31` 缺 if 大括号）；基线源码已核对。变更文件分析 `analyze-changed.log`：exit 0，无问题。不声称全仓 analyzer 零问题。
- `mobile-boundary-scoped.log`：107 通过、1 条件跳过、1 项另行执行，exit 0。原全目录密钥扫描遍历生成产物长时间未结束，停止本任务该进程，`mobile-boundary.log` exit -1，不计通过。替代扫描同一禁用字面量规则覆盖 3523 个 tracked 源文件及本任务新增文件，排除生成产物，`credential-scan.log` exit 0。
- `ui-contract.log`：32 组件、403 页面契约通过，exit 0。`git diff --check` 通过。

未重跑未变的后端、迁移、容器与管理前端门禁；按 mobile-delivery-workflow 变更影响规则，沿用基线交付记录。本轮未变业务 API/worker/数据库/infra/前端依赖，不将其他 worktree 的新结果冒认为本候选结果。`scripts/verify.ps1` 已预读，本轮只执行其中受影响的移动边界、UI 契约和安全源码检查，完整脚本未重跑。

## 审查与限制

独立审查先规格后质量/安全，初稿中“读取旧pending触发自愈写入”的P1已通过只读解析及回归关闭，最终未发现新增 P0/P1，见 `review.md`。P2 兼容限制：同步头像 URL 针对当前配置的认证媒体端点；只支持旧 legacy 端点的服务器仍需能力响应后才能定位旧磁盘缓存。当前仓库配置 Synapse v1.132.0，未在本轮重新探测生产服务器。

恢复读取批量化，每房最多32个同步事件、8个待发事件、当前预览与至多1个编辑根引用。这个上限约束事件正文；底层仍读取两个已存的时间线 ID 列表，不声称总字节量严格固定。缺少顺序锚点时只接受时间戳更晚的候选，不为展示旧明文启动联网解密或请求密钥。

没有 Redmi K80 真机冷启动计时、系统帧耗时或新 APK 验收。历史缓存被系统删除/从未下载的图片仍需联网，不能承诺无缓存时离线显示。已有密钥但历史房间行仍 encrypted 的冷恢复空白路径尚无真实复现，不与本次撤回问题混为一谈。

## 时序

2026-09-24 00:40 +08 开始调查；00:49 后写计划/红测并行实现；00:56–01:08 验证及修正夹具；01:03–01:08 首轮完整 Flutter；用户补充后至01:20完成有界旧缓存修复、红绿与复审；01:20发起最终全量，01:29确认exit0及源码hash一致。总墙钟约49分钟，含工具等待、一次无界产物扫描中止及夹具返工；并行主动/工具时间未分别计量，不伪造精确人时。

## 交接

主目录候选无需清理聊天数据即可升级使用，但本轮没有生成APK。下一步为按实际发布授权，将此源码与其他仍在独立工作树的移动反馈改动核对后打包，使用既有稳定签名覆盖安装，真机验收冷启动/弱网/头像及受影响会话。不得把本报告当成手机已安装或生产已发布证据。无本任务仍运行的测试、隧道或生产任务。
