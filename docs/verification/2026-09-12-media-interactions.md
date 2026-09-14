# 媒体交互、最近访问与加载检查

交付：**Mi 6 已保留数据覆盖安装 0.3.87-debug（2094）**，2026-09-12 17:14:47 +08 完成安装包拉回/哈希/签名核验。产品实现、针对性验证与 Astra 审查完成；全套仍有已记录的基线失败及环境阻断，用户真机功能验收待完成。基线 `aac3d806`（Debug 2093，含 main `1d1db6aa`），工作树 `.worktrees/offline12`，分支 `codex/media-interactions-20260912`。Astra 制定计划、检查实际 diff/调用链/原始测试证据；执行代理明确使用 `gpt-5.6-terra`。后续新建代理被 thread limit 拒绝时已如实记录并复用已确认的 Terra，没有静默替换模型。

[实施计划](../superpowers/plans/2026-09-12-media-interactions.md) · [授权、分工与阶段时间](../workflow/tasks/2026-09-12-media-interactions.md) · [原始证据目录](artifacts/2026-09-12/media-interactions/)

## 根因、实现与规格审查

| ID | 复现/问题 | 根因 | 修改与边界 |
| --- | --- | --- | --- |
| P1 | 好友详情刷新后缓存通知、断网重进或重启导致最近访问时间丢失/回退 | 缓存 JSON 漏字段、相等比较漏 known 状态、详情成功未持久回填、404 留旧值，旧异步请求与落盘期间更新相互覆盖 | 保留未知/明确无值/确切时间三态；详情按账号/API/仓库/用户/请求代次隔离，合并仓库最新资料，保护并发备注/头像修改；404 清 presence，网络失败保留缓存；前台分钟刷新，后台停止 |
| P2 | 缓存、冷/热启动、聊天与朋友圈重进、离线提示核对 | 前次 2093 已有离线恢复与缓存优先修复，本轮未把旧问题重新实现 | 核对并验证本地启动 gate、账号资料 hydrate、40 条初始/200 条上限消息窗口、朋友圈 SQLite/快照先显后刷新、稳定媒体 provider、内容 SHA 缓存、账号与清缓存代次、统一连接状态与重试；没有声称新包真机性能实测 |
| E1 | 窄屏/大字下 emoji 面板错位，缺少独立橡皮擦 | 默认按钮内边距与列布局挤压；编辑工具只有马赛克，未独立擦除编辑层 | emoji 48px 居中触点、最多 6 列、零默认 padding；独立橡皮擦 icon，用 clear 仅擦编辑层，原图保留；马赛克单独采样原图；保持原图坐标、裁剪、撤销重做、导出 |
| S1 | 录像等待压缩，转发等待全部网络完成后才能退出；退出来源页影响发送 | 准备/发送 await 与页面生命周期耦合，缺少账号任务所有权与稳定每目标 txid | 账号拥有的有界队列；确认仅等待本地接收，图库视频文件延后获取/压缩，媒体源一次准备，多目标独立状态与固定 txid；页面关闭不撤销已接收任务，账号退出撤销；发送中/失败/重试真实反馈 |
| L1 | 点钻流水层级与微信式连续账单布局不符，窄屏金额与时间显示有问题 | 每条卡片和大筛选控件占空间，金额固定宽度截断，DateTime 与字符串时区处理不一致 | 现有页面改为紧凑搜索/类型日期入口、月份分组、类型 icon、连续流水行与右侧完整金额；本地时间一致，大字可换行，懒构建可见行；保持筛选、分页、详情、复制与精确金额。按用户明确选择不增加截图导出 |

“最近访问时间”沿用服务端定义：好友最近一次 App/设备活动（未撤销设备的最大 last_seen_at，现有分钟心跳），不是别人访问资料页的时间。服务端好友可见性、鉴权和字段契约未变。

## 后台发送的实现细节与风险边界

- 同一账号最多 128 个未确认目标项、3 个并行传输、1 个待传就绪源、128MiB 准备/保留预算，终态元数据有界。9 个图库视频可以先原子接收句柄，开始准备时才预留压缩结果和缩略图空间；不新增原始录像 100MiB 上限，现有压缩后 20MiB 限制保留。
- 现有文本/完整格式、选中文字、图片、视频、文件、语音、多条混合消息和编辑图转发接入同一 owner。源事件、账号、client、内容与目标在接收边界冻结；每源下载/解密/准备一次，失败只重试失败目标，沿用原 txid，成功目标不再发送。
- 下载使用认证且有界的流，非 2xx/超限及时停止；缩略图计入预算，旧无 hash/size 的媒体兼容，超限可选缩略图可丢弃；未放宽 E2EE 描述符、房间权限或 SDK 加密发送。录像真实压缩失败保留原件，终态后按所有权清理。
- 实际 RoomTimelineController 最新窗口展示 pending，旧锚点不被强行移动，后续新消息不会把旧 pending 挪到末尾；本人新发送回最新窗口，后台转发不移动来源锚点。同步回执须与存储中的消息关联后才释放本地投影与额度。
- 本次为**进程内跨页面后台发送**。没有新增明文持久 Outbox，不保证杀进程后继续压缩/上传；系统后台调度、进程终止恢复及 iOS 原生兼容尚未验证。反馈“正在发送”不等于对方已收到。

## 关键文件与兼容审查

- 好友资料：`contact_models.dart`、`contact_profile_sections.dart`、`contacts_page.dart`、`profile_repository.dart`。
- 编辑器：`ui/chat/wechat_image_editor.dart`；HTML `image-editor.js`、icons、styles 与浏览器用例。
- 发送：`matrix_outgoing_work_coordinator.dart`、`matrix_e2ee_client.dart`、`content_addressed_media.dart`、`device_gallery_source.dart`、`prepared_chat_video.dart`、`room_page.dart`，以及 owner/coordinator、实际窗口与真实 UI 回归。
- 流水：`features/ledger/ledger_pages.dart`；HTML `finance.js`、共享样式和 registry。未改 LedgerController/Gateway、金融写入、金额公式、账本 schema、服务端 API 或生产配置。
- UI 演示：`messaging.js`、catalog、registry 和三组真实浏览器测试；发送演示使用本地受控 fixture，不连接生产。Figma 工作流已退役，采用 ui-demo-delivery。

Astra 已逐批完成规格审查后再做质量/安全审查，退回并复验过：落盘覆盖新备注、裁剪擦除坐标、真实窗口漏 pending、ack 重入与扫描复杂度、同房间换账号、准备预算、录像源清理、picker 与 composer 真实 UI 路径等。并发代理不共享文件写权。Getui、服务端、vendored SDK、原生配置、钱包/红包/转账业务路径与基线的差异检查记录于 `protected-path-review.json`；该差异核对不替代平台真机验证。

## 针对性验证（实际执行，重复套件不累计）

| 范围 | 结果 | 原始证据 |
| --- | --- | --- |
| P1 Flutter | 第二轮 75 passed；held-store 收尾 24 passed；实际 RED 是新备注被旧快照覆盖 | `p1-green-round2.log`、`p1-held-write-red.log`、`p1-held-write-green.log` |
| P1 本地业务接口 | `py -3.12 -m pytest tests/business_api/friendship/test_friend_detail.py -q --tb=short`：4 passed，exit 0；1 条既有 Starlette/httpx 弃用警告 | `p1-friend-detail-pytest.log`；本地 SQLite fixture |
| P2 | 23 文件、197 passed，exit 0：启动 gate、断网提示、SDK 恢复/看门狗、资料/朋友圈缓存、媒体/头像、50k 合成消息窗口 | `p2-focused-green.log`、`p2-audit-inputs.json` |
| E1 | 4 Flutter 像素/布局测试及 target analyze 通过；真实 Chrome 验证 emoji、工具、裁剪、撤销重做 | `e1-image-editor-red-green.md`、`e1-flutter-final.log`、`e1-html-final.log`；截图 `editor-root-review.png` |
| L1 | 15 Flutter 测试、target analyze、Node 与 Chrome 筛选/日期/空态/reset/精确 copy 通过 | `l1-ledger-review-*.log`、`l1-html-final.log`；有效截图 `ledger-root-390.png`、`ledger-root-320-dark.png` |
| S1 基础 | owner/coordinator/真实 adapter 45 passed；窗口位置收尾 16 passed | `s1-c-windowed-owner-coordinator-green.log`、`s1-c-windowed-position-green.log` |
| D2 媒体边界 | 72 passed、target analyze 通过；真实 A256CTR HTTP fixture 验证 2 源×2 目标、单次下载解密、账号隔离、失败重试、受限读取 | `d2-boundaries-focused-green.log`、`d2-boundaries-target-analyze.log`；流取消 RED `d2-content-bounded-baseline-red.log` |
| D3 视频/入口 | 77 passed；真实 RoomPage 长按→选择聊天→确认→整个 picker 退出且 composer 可输入；held 下载/来源 lease 撤销后 owner 继续，另 1 passed | `d3-final-focused-green.log`、`d3-room-page-forward-ui-final-green-route-lifecycle.log` |
| D4 同步确认 | D3/D4最终52 passed，实际RoomPage全文件4 passed，target analyze通过；覆盖未打开目标、早到回执、本地状态过滤、密文/解密事件、身份隔离、准备/HTTP错误后的成功确认 | `d3-d4-final-focused-green.log`、`d3-d4-target-analyze-final-green.log`、`d3-room-page-forward-ui-fullfile-final-rerun.log` |
| U1 | Node/Chrome 交互与 UI contract 28 components/364 screens 通过；Astra 亲自点击和截图复核 | `u1-forward-final.log`、`u1-forward-contract-final.log`、`forward-root-pending.png` |

各日志以实际退出码和终态摘要为准；早期名称含 green 但退出 1 的夹具/动画/真实 IO 调试记录不计通过。真实 RoomPage 测试经过屏幕控件，不直接调用发送回调；编解码插件/网络部分使用受控边界，仍不能代替 Mi 6 实测。

## 最终门禁、源码与 APK

候选源码 `0.3.87+2094` 已冻结；[source-freeze.json](artifacts/2026-09-12/media-interactions/source-freeze.json) 记录 44 个源码/依赖文件 SHA256、基线与分支。门禁后逐项复核无漂移（`source-freeze-post-gates.json`）。Flutter 3.44.9 / Dart 3.12.2 / Java 17.0.20 / PowerShell 7；工具版本原始输出在证据目录。

| 最终门禁 | 实际结果 | 证据与说明 |
| --- | --- | --- |
| `flutter test --no-pub --reporter expanded` | **2535 passed / 29 failed，exit 1** | `flutter-full-final.log`；与 2093 的 29 个钱包失败身份完全相同，新增/消失均 0，见 `flutter-failure-comparison-final.json`。不能称全量通过 |
| `flutter analyze --no-pub` | 无问题，exit 0 | `analyze-final.log` |
| `py -3.12 -m pytest tests/mobile -q` | **67 passed / 3 failed，exit 1** | `mobile-boundaries-final.log`；既有 GlobalSearch 正则解析及两项过时 registry 数量断言，失败身份无新增，见 `mobile-failure-comparison-final.json` |
| `py -3.12 scripts/verify_ui_contract.py` | 28 components / 364 screens，exit 0 | `ui-contract-final.log`，实际契约校验通过 |
| `node --test --test-reporter=spec`（frontend） | **161 passed / 11 failed，exit 1** | `frontend-final.log`、`frontend-failure-comparison.json`；失败身份与 2093 一致，最终 HTML 后未再修改相关输入，复用该结果 |
| `git diff --check` | exit 0 | `diff-check-final.log`；仅 Git 行尾提示，无 whitespace 错误 |
| `pwsh -NoProfile -File scripts/verify.ps1` | **exit 1 / 环境阻断** | `verify-final.log`；仓库/部署策略/模板通过，render-only 缺工作树 `.env` 停止，其后依赖步骤未执行；未引入生产凭据 |
| 文档链接 | 32 条有效，缺失 0 | `document-link-check.json` |

最终共享门禁 17:08:05–17:10:17 +08，约 132 秒（Flutter 101.65 秒、analyze 10.17 秒、mobile 20.05 秒），完整时间/命令/exit 见 `final-gates.json`。源码构建、固定重建/签名与安装均已完成，详见下表。

| 交付身份 | 实际值/证据 |
| --- | --- |
| 最终包 | [final.apk](artifacts/2026-09-12/media-interactions/delivery/debug-2094/final.apk)，144,003,371 bytes；这是重建后固定签名的交付包，source.apk 仅中间产物 |
| 版本/包名 | `0.3.87-debug / 2094`，`com.liuhetong.mobile`，ARM64，debuggable |
| SHA256 | `3a15b4aa3ca3abdb695c0f8c40b33303f4024d54cd19189f7bddea431a8bffaf` |
| 固定证书 SHA256 | `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，与原 Mi 6 的 2093 一致 |
| 构建流程 | 标准 Flutter/Gradle ARM64 Debug → Apktool 2.12.1 全量 DEX/资源/清单重建 → zipalign 16KiB → 固定签名 → 重解码核验；没有混淆/壳/任意填充 |
| 内容与签名验证 | 27,250 个 smali 类语义一致、339 项原生库/资产 SHA 无变化、manifest 语义一致、资源确实重建；v2/v3 签名及最终 zipalign 通过。见 `delivery/debug-2094/verification.json`、`signature.txt`、`debug-verification.log` |
| 设备安装 | Mi 6 `cbd0156b`；`adb install -r` 返回 Success；已安装 APK 拉回后整包 SHA 与 final.apk 一致，证书再次验证一致；[安装证据](artifacts/2026-09-12/media-interactions/mi6-install-verification.json) |
| 数据保留证据 | 未卸载/清数据，firstInstallTime 前后均为 `2026-09-11 00:42:05`；未对用户聊天内容做读取或逐项验证 |

构建/重建/验证 17:11:09–17:13:30，140.70 秒；安装及拉回核验 17:14:27–17:14:47，19.60 秒。从任务 13:50（分钟精度）到安装验证约 3 小时 25 分钟。主动实施、并行代理、等待与返工未分别完整计时，分项未知部分不编造；可核对阶段时间见任务记录。

没有生产发布、push 或数据库迁移。Mi 6 安装步骤只允许固定签名 `install -r`，不卸载、清数据、改变网络配置或自动进行功能测试。

## 新包真机验收用例（由用户执行，尚未实测）
| 场景 | 操作 | 通过条件 |
| --- | --- | --- |
| 最近访问 | 从通讯录、聊天成员和朋友圈打开同一好友；等待详情返回后重进；修改备注同时刷新 | 最近活动值一致；缓存通知不回退；备注不被旧请求覆盖；无记录/未知状态不伪造时间 |
| 离线页面 | 先在线浏览并缓存，再由用户断网，重进聊天、朋友圈、我和好友资料 | 已缓存内容可见；已有私聊可由发消息进入；媒体不闪回空白；缺缓存明确占位，弹窗与页面提示一致 |
| 恢复连接 | 由用户恢复网络，保持应用前台并让另一账号发消息 | 目标恢复≤5秒；状态恢复后提示消失；新消息正常进入，不要求重启应用 |
| 冷/热启动 | 同一账号同一构建冷启动/热恢复各3次，记录首条缓存与可输入时间 | 无网络等待阻断已有缓存；记录每次原始值及P50，不与旧构建数值混算 |
| 编辑器 | 打开emoji面板、选表情；画笔后分别使用橡皮擦/马赛克；裁剪、撤销重做、完成导出 | emoji居中不挤列；两工具独立；擦除编辑痕迹保留原图；马赛克有效；裁剪后笔画位置和导出正确 |
| 视频发送 | 分别选择图库视频、视频文件、实时录像，确认后立即输入/返回，再进入目标会话 | 确认不等待压缩或网络上传；会话可见发送中/失败状态；返回不取消已接收任务；成功内容可播放 |
| 转发 | 文本全选/部分选区、图片、视频、多条混合消息转发至两个目标，确认后立即返回 | 本地接收后退出选择页；选区只转选中文字；两个目标准确收到；部分失败只重试失败项，不重复成功项 |
| 编辑图转发 | 图片编辑完成→转发→选择聊天→确认 | 选择页及时退出，反馈正在发送；目标收到编辑后的图片 |
| 账号隔离 | 上传中退出账号；或打开选择页后切换账号再确认 | 不把原账号源发送到新账号；原任务按退出生命周期停止，不跨账号复用明文缓存 |
| 全部账单 | 切类型/日期、搜索、翻页、进入详情并复制账单ID；窄屏、暗色、大字 | 月份分组和本地时间正确；完整精确金额可读；筛选/搜索/详情保留；不出现伪造分页月度合计 |

微信参照范围为布局、工具分工与交互流程；自动化不等同于微信逐像素、动画手感、Android实际权限/媒体编解码兼容性验收。进程内后台任务也不等同于系统杀进程后继续转码上传。
