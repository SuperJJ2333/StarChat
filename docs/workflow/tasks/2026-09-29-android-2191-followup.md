# Android Debug 2192 八项反馈修复

## 恢复入口

- 目标、用户授权来源及边界：用户于 2026-09-29 报告聊天记录搜索提示、朋友圈视频发送/封面、未绑定钱包充值与视觉、头像冷启重载、群主转让流程、会话媒体空白、全局搜索头像、转发头像八项；选择钱包 A 白色余额卡与群主转让视觉方案，批准三模块概念设计、书面规格及 ADR-0077 补充，要求继续实施。完成 Debug 装机后，用户明确要求发布配套 API；此授权不含实际金融操作。若现场漂移导致镜像候选身份改变，应先完成新候选及独立审查，按发布手册核对授权范围。
- 关联规格/ADR：[钱包](../../superpowers/specs/2026-09-29-wallet-unbound-recharge-design.md)、[视频与缓存](../../superpowers/specs/2026-09-29-moments-video-avatar-room-preview-design.md)、[搜索与转让](../../superpowers/specs/2026-09-29-android-search-forward-transfer-ui-design.md)、[ADR-0077 补充](../../adr/0077-manual-recharge-withdrawal.md)。[钱包计划](../../superpowers/plans/2026-09-29-wallet-unbound-recharge.md)、[媒体计划](../../superpowers/plans/2026-09-29-moments-video-avatar-room-preview.md)、[界面计划](../../superpowers/plans/2026-09-29-android-search-forward-transfer-ui.md)已批准并提交。
- 当前状态：**Android Debug 0.4.23（2192）已保留数据安装到 `emulator-5556`；配套 API v4r2 已单服务发布并经独立只读验收**。八项客户端实现均已提交，HTML demo 与 UI 注册表一致；钱包实施级领域/质量安全复核、PostgreSQL 16.9 并发 3/3、头像/好友申请/转账独立复核通过。最终 Flutter 5131 通过、9 跳过，analyze 无问题。另一任务生产 API `83aed…8367f5` / schema 0092 是本轮精确基线；v3 `845c…dde8ab` 已废止。v4r2 `fadabb…ab7dd` 保留钱包工作台，未迁移 schema，worker/PG 未切换；第一次尝试受控回退后的健康检查竞态修复与第二次新备份/同 SHA 隔离恢复见[发布结果](../../verification/artifacts/2026-09-29/android-2191-followup/server-release-v4r2/release-result.md)。
- 负责人、工作树、文件所有权、源码 commit：主任务 `/root`，复用 `C:/Users/Administrator/.codex/worktrees/chat-search-jank/StarChat`，分支 `codex/chat-search-jank`，设计提交 `6d75f20bcbd00ad5b494ccdeaa7f8894cbb69c60`。钱包、UI、媒体计划分别由独立代理拥有；主任务拥有本任务记录和恢复索引。执行时再分配互不重叠的源码文件。
- 最后更新时间：2026-09-29 20:01 +08:00。整库脚本的 Business API/Worker 3019 通过、78 跳过；Flutter 边界首次因注册表 433→438 的 2 项失败已修正，定向 238 通过、1 跳过。首轮 Flutter 全量 5119 通过、9 跳过、6 失败；修正后第二轮 5130 通过、9 跳过，仅旧架构守卫源码片段断言失败；更新守卫后最终全量 5131 通过、9 跳过，exit 0，analyze exit 0。整库脚本本次真实退出码仍为 1；后段门禁已按变更影响单独核验。2192 重建 18 个步骤全为 exit 0；模拟器 `adb install -r` 返回 Success，首次安装时间保留，前台进程在位，限定 2428 行 logcat 无崩溃/ANR。v4r2 封装器 30/30 合成测试和独立审查通过，远端 SHA/0600 对齐；发布后 API healthy/零重启、镜像精确匹配、worker/PG 不变、新备份=隔离恢复 SHA。
- 下一条具体操作：用户在已登录设备及 Redmi K80 验证视频上传、封面、缓存命中和钱包/转让/头像视觉。无生产账号，认证诊断 202 与真实充值 409 不归入本次匿名生产烟测。

## 验收台账

| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 真机反馈/缺口 |
| --- | --- | --- | --- | --- | --- |
| A01 | 聊天记录搜索不显示未解密警告，内部覆盖统计如实保留 | 已提交 `1e70813d` | 43 项 Flutter 测试、规格与质量复核通过 | Debug 2192 已安装 | 已登录搜索待用户操作验证 |
| A02 | 合法视频慢速上传成功；新视频有首帧封面；失败阶段可定位并重试 | PUT 时限 `263b1516`、强制首帧封面 `2a302b4c`、九阶段诊断 `1d8f4c6b` 已提交 | 慢 PUT、封面及混合旧/新诊断聚焦通过；服务器候选隔离 202/422 验证；用户原失败阶段仍未知 | Debug 2192 已安装；API v4r2 已发布 | 需 Redmi K80 实际视频/脱敏时间线 |
| A03 | 未 ACTIVE 绑定无法创建新充值；钱包 A 版视觉；历史申请仍可核对 | 门禁 `dd70c1a9`、充值服务 `7bffa68c`、钱包 UI `4abebf25`、HTML `90d0cd85` 已提交 | 隔离 PG16.9 并发 3/3、充值套件 109 通过/1 跳过；实施级领域/质量安全 PASS，见 `2026-09-29-wallet-gate-implementation-review.md` | Debug 2192 已安装；API v4r2 已发布 | 无生产资金写入，模拟器 UI 待验 |
| A04 | 同一头像冷启与回前台命中稳定缓存，换图立即更新 | S3 稳定 `v=`、客户端账号作用域缓存及跨账号好友申请/红包/转账保护 `e453bcec` 已提交 | 52 项后端头像投影及 Flutter 同 ID 成员、旧审核路由和跨 await 账号切换回归通过；规格与质量安全复核 PASS | Debug 2192 已安装；API v4r2 已发布 | 待缓存来源计数及真机冷启 |
| A05 | 群主转让显示头像/搜索，COMPLETED Toast 后回群信息 | `93dbdd4b` 已提交；HTML `90d0cd85` | 成功、待核对、搜索与视觉聚焦测试通过 | Debug 2192 已安装 | 模拟器交互待验 |
| A06 | 再进会话可立即显示同账号已缓存预览；冷启有非空白占位 | 有界首帧缓存 `89e04f20` 已提交 | 74 项 Flutter 聚焦和分析通过，规格及质量复核通过 | Debug 2192 已安装 | 断网重复进房、Matrix 请求数需已登录设备验收 |
| A07 | 全局搜索聊天记录/群聊结果显示对应头像 | `35cbbe71` 已提交，含账号切换/并发加载保护 | 59 项聚焦测试通过 | Debug 2192 已安装 | 模拟器交互待验 |
| A08 | 转发“发送给”单人/群头像完整、顶部对齐 | `aea54c7d` 已提交 | 非零 32dp 安全区 RED 复现，23 项相关测试及分析通过 | Debug 2192 已安装 | 模拟器交互待验 |

## 版本与证据

| 平台/服务 | 实际版本/build/镜像 | 来源 commit | 包名/签名渠道 | 文件位置及 SHA | 发布观察时间/链接 |
| --- | --- | --- | --- | --- | --- |
| Android 安装前调试包 | 0.4.22（2191） | `e81c809b` | 固定用户测试签名；此前已保留数据安装 emulator-5556 | 旧 APK SHA256 `aa70b8d32827579b7f06b206dda9015329819e8e9b3c63b3ec47a8c620bc6e77`，见 `2026-09-28-chat-search-jank-diagnostics.md` | 2026-09-29 17:53:46 +08:00 被 2192 保留数据覆盖 |
| Android 本轮 Debug | 0.4.23（2192） | `6fc2cec9` | `com.liuhetong.mobile.debug`，固定测试证书 `75b31c66…61fff` | [最终 APK](../../verification/artifacts/2026-09-29/android-2191-followup/android-debug/run-20260929-175000-2192/final.apk) SHA256 `34dd06bf90bdad9772914b0c0e11b76c97f824520d49eb1a2153d4679567676d`；1811 文件冻结清单 SHA256 `765babd99f2e4d0959da75774a31008a4252e2bcff726b09f7a449377b396455`；[安装证据](../../verification/artifacts/2026-09-29/android-2191-followup/android-debug/run-20260929-175000-2192/install-verification.json) | 2026-09-29 17:53:46 +08:00 保留数据安装模拟器；首次安装时间仍为 2026-09-26 04:06:20 |
| Business API 冻结时基线 | `sha256:0bdf751c05015454781c24b66a0c5066ca08ce23436c232ff8aecd1ba5042993`、schema 0091 | v3 构建来源；后续被钱包工作台发布替换 | 历史只读快照 | 不再是当前生产 | 2026-09-29 早前快照；不可作为现在回退目标 |
| Business API 非服务候选 v3（阻断） | `sha256:845c1f030238887218e74b4212c5ceaa7dea57a6aab9526662218ddd92dde8ab` | 旧 `0bdf…` 叠七文件；未含钱包工作台两处现网改动 | 隔离构建，未切流 | [候选报告](../../verification/artifacts/2026-09-29/android-2191-followup/server-candidate/candidate-report.md)及独立审查 | 2026-09-29 现场漂移核验拒绝发布；未上传封装器、未备份、未切换 |
| Business API 本轮发布前基线及回退目标 | `sha256:83aedc06dd6763f819c4147736d0f422d238f4284b926429094d3e38eb8367f5`、schema 0092 | 钱包工作台已发布，保留两个新 API 文件；worker `sha256:3c9e4bbf…eaadaaf` 不变 | 历史基线，本轮发布后不再服务；镜像保留作固定回退目标 | [独立只读基线](../../verification/artifacts/2026-09-29/android-2191-followup/server-release-prep/readonly-preflight-independent.md)、[两文件漂移](../../verification/artifacts/2026-09-29/android-2191-followup/server-release-prep/api-drift-diff.md) | 2026-09-29 用户发布授权后复核；v4r2 基于此构建 |
| Business API v4r2 已发布 | `sha256:fadabb52cd61c078599ceda2544cea6f34dd85b0dbc0b6c5d276c5d3a96ab7dd`，schema 0092 | 原 `83aed…8367f5` 上叠七个批准文件，保留钱包工作台 0092 | 生产 `starchat-business-api-1`，容器 `c0ec3a78…17895a` healthy/零重启 | [发布结果](../../verification/artifacts/2026-09-29/android-2191-followup/server-release-v4r2/release-result.md)、[独立只读验收](../../verification/artifacts/2026-09-29/android-2191-followup/server-release-v4r2/independent-postrelease.md) | 2026-09-29 20:00:07 +08:00 容器启动；新备份 `25d922b4…0b981d` 同 SHA 隔离恢复；worker/PG/其它容器不变 |
| 本轮设计 | Git `6d75f20b` | 同左 | 不适用 | 三份规格及 ADR 补充 | 2026-09-29 |

测试证据必须包含命令、真实退出码、输入/源码 hash、依赖锁和工具版本、平台、通过/失败/跳过数；文档阶段只做链接、占位符与 Git whitespace 检查。既有 2191 整库验证最后一次 exit 1，不当成本轮通过证据。

## 阶段计时

| 阶段 | 开始（+08:00） | 结束 | 主动/工具/外部等待/返工 | 并行组 | 结果/耗时来源 | 下一步 |
| --- | --- | --- | --- | --- | --- | --- |
| 只读调查与视觉确认 | 首次准确时间未记录，至迟 2026-09-29 12:55 | 2026-09-29 13:15 前 | 主动调查与用户异步回复，精确时长未知 | 媒体、钱包、搜索及主任务并行 | 源码、生产只读基线、浏览器方案和用户回复 | 写规格 |
| 三份规格及 ADR 提交 | 2026-09-29 13:00 后，精确时间未记录 | 2026-09-29 13:15 前 | 主动写作、独立钱包草稿，精确时长未知 | 钱包代理与主任务 | Git `6d75f20b`，用户已批准 | 写计划 |
| 实施计划与钱包设计审查 | 2026-09-29 13:15:54 | 2026-09-29 13:34:01 | 并行代理编写、主任务交叉文件审查，约 18 分 7 秒墙钟 | 钱包、媒体、UI 与独立领域/安全审查并行 | 三份计划已保存，钱包审查两项问题已修订并复核批准；计划提交待记录 | 红测 |
| 第一批红绿任务 | 2026-09-29 13:36 左右；精确派发秒未记录 | 2026-09-29 14:04 前 | 并行实施和复核；精确耗时以三个任务各自证据为准 | 钱包门禁、媒体 PUT、搜索提示 | 三项已通过规格和质量复核并提交 `dd70c1a9`、`263b1516`、`1e70813d` | 第二批实施 |
| 第二批红绿任务 | 2026-09-29 13:53 后；精确派发秒未记录 | 2026-09-29 17:49 前 | 服务、媒体、搜索并行；根任务串行承担钱包/转发 UI 与钱包 HTML | 充值服务、封面、搜索头像、钱包/转发页面 | 八项实现和独立审查完成；API v3 候选隔离构建通过；最终 Flutter 5131/9 与 analyze exit 0 | 构建 Debug |
| Android Debug 2192 包装与装机 | 2026-09-29 17:50:00 | 2026-09-29 17:56:20 | 源码冻结、Flutter 构建、Apktool 重建、固定签名、安装与有界日志检查，约 6 分 20 秒 | 主任务；服务发布封装器并行 | [artifact.json](../../verification/artifacts/2026-09-29/android-2191-followup/android-debug/run-20260929-175000-2192/artifact.json)、[18 步](../../verification/artifacts/2026-09-29/android-2191-followup/android-debug/run-20260929-175000-2192/steps.tsv)、[安装证据](../../verification/artifacts/2026-09-29/android-2191-followup/android-debug/run-20260929-175000-2192/install-verification.json) | API 发布授权与真机验收 |
| API v3 发布前现场核对 | 2026-09-29 约 19:09 | 约 19:12 | 独立只读生产镜像、0092、Compose/健康及全 app 文件哈希；精确秒见服务器证据 | 主任务、两只读代理 | 发现 API `83aed…` 及 schema0092；旧候选回退两现网钱包文件，拒绝切换 | 基于当前现场最小重建 v4 |
| API v4 候选与首次尝试 | 2026-09-29 约 19:12 | 约 19:46 | 重新叠七文件、隔离验证与独立审查；生产新备份/同 SHA 隔离恢复、API 单服务切换，候选验收失败后受控回退；精确开始秒未记录 | 主任务、候选/封装器/0092 审查并行 | v4b `fadabb…ab7dd` 有效；回退后原 API healthy/零重启；[事故记录](../../verification/artifacts/2026-09-29/android-2191-followup/server-release-v4/incident-first-attempt.md) | 收束旧状态并修复健康时序 |
| v4r2 收束、重发及验收 | 2026-09-29 约 19:46 | 2026-09-29 20:01 后 | 旧 `rolling_back` 只读核验后收束；新封装器红绿 30/30、独立审查、上传 SHA/0600、新备份与隔离恢复、API 单服务切换及独立只读复验 | 主任务与独立复核并行 | `active/verified`；候选镜像 `fadabb…ab7dd` healthy/零重启；worker/PG/其它容器未变；新备份与恢复 SHA `25d922b4…0b981d` 相同；[独立验收](../../verification/artifacts/2026-09-29/android-2191-followup/server-release-v4r2/independent-postrelease.md) | 真机业务体验 |

总墙钟：任务起点未可靠记录，暂不估算；计划与实施完成后以可核验时间区间更新。重复工作：无已确认；未知时间不写作精确耗时。

## 交接与回退

- 已确认根因/已排除假设：8 秒媒体 PUT 是合法慢速视频的确定失败路径；线上 0091 接口存在，不能把缺接口当现网根因。头像私有 S3 存储与 HTTPS 下载并不冲突，随机签名 URL 被当版本才导致缓存抖动。会话空白不证明重复联网。本轮发布前的未绑定 CNY 人工充值在客户端与原生产 API 缺少新申请门禁，旧 TRON 手工意图已有门禁；v4r2 已部署该 CNY 新申请门禁，但真实认证 409 尚待测试账号验证。
- 待办及验收缺口：八项代码与自动化测试完成，Debug 2192 装机/启动通过；需已登录模拟器或 Redmi K80 手动检查视频上传/封面、钱包/转让/头像视觉和缓存命中。A02 的用户实际失败阶段未采到；Redmi K80 真机性能和视频体验未验收。
- 已发布与仅候选的区别：Debug 2192 已安装，配套 API v4r2 `fadabb…ab7dd` 已在生产运行且 healthy；v3 `845c…dde8ab` 从未服务生产。v4 首次候选只短暂运行后受控回退，旧状态 `rolled_back` 不可再激活。v4r2 保留钱包工作台两处现网文件、0092、旧 0091/S3 功能及原 worker。
- 生产备份位置、恢复操作、漂移检查、可重试阶段：v4r2 root `/opt/starchat/releases/android-2192-api-v4r2-20260929/private/` 0700，`business-pg-before-api-v4.dump` 0600 SHA `25d922b4197119cf6916131a1003794dc67659c09e23385e033b0b344c0b981d`，同 SHA 隔离恢复通过；回退目标固定原 `83aed…8367f5`，保持 schema0092。发布器在单锁下固定 API/worker/PG/其它容器身份、Compose 与私有文件 SHA；后续如发生其它发布，不能盲目运行本轮回退。回退命令与门禁见 [v4r2 playbook](../../verification/artifacts/2026-09-29/android-2191-followup/server-release-v4r2/playbook.md)。
- 运行中 CI/命令/自己创建的隧道：无 CI；本地视觉方案服务器 `http://localhost:64834` 仅供审阅，若关闭无需恢复。无生产隧道。
- 下次恢复先检查的事实：Git 状态、当前生产镜像/schema 与 v4r2 `active` 状态、模拟器安装 build、是否已有 Redmi K80 脱敏视频阶段；勿把旧 8015、v3 或第一次受控回退后的快照当现网状态。
