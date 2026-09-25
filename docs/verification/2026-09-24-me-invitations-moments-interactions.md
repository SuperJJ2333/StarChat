# “我”页、邀请码与朋友圈互动验证记录

**日期：** 2026-09-24 HKT
**工作树：** `D:\pythonProject\outsource\StarChat\.worktrees\online-room-refresh`，HEAD `8ed729a1` 加本任务和前次任务未提交改动。
**计划：** [2026-09-24-me-invitations-moments-interactions.md](../superpowers/plans/2026-09-24-me-invitations-moments-interactions.md)；任务台账见 [同名任务记录](../workflow/tasks/2026-09-24-me-invitations-moments-interactions.md)。

## 已取得的 RED/GREEN 与视觉证据

| 范围 | RED | GREEN/现状 |
| --- | --- | --- |
| 邀请码真实入口 | `invite_route_history_test.dart` 两例均在预期的零次历史 GET 断言失败；页面旧入口没有注入网关 | `flutter test test/features/profile/invite_route_history_test.dart --reporter expanded` exit 0，2/2 passed；首/次页、空态和带 Bearer 的真实入口均覆盖 |
| 昵称/签名服务端 | 4 个资料/注册测试按旧规则分别在组合 emoji 与 13 字素场景失败，0 collection error | 共享字素校验、提交复验、注册/资料 API 和 0088 扩列 GREEN；ADR-0085 领域与 Quality/Security 复审通过；隔离实库原值不变 |
| 朋友圈互动服务端 | 新增 5 个评论/回复、权限、历史通知与分页聚焦测试先 RED 5/5 | 通知种类/隐私/失效历史/分页 GREEN；审查发现游标输入可触发 500，新增测试 4 通过/1 按预期失败，修正后相邻两文件 41/41 GREEN；最终 `service.py` SHA256 `0d1fd84e…` |
| SessionGate/二级导航 | 旧登录根路由残留场景 RED 2 个；真实路由测试见 Tab 仍暴露 | 根路由清栈聚焦 3/3 GREEN；个人信息、朋友圈、点钻、钱包、设置、二维码/邀请码/账单入口与返回均由 widget 测试覆盖，Flutter 全量通过 |
| HTML 设计演示 | 新增画面/路由专项 2/2 按缺失状态和错误入口预期失败 | `npm test` exit 0：305 passed；`py -3.12 scripts/verify_ui_contract.py` exit 0：32 components、429 screens；更正了编辑页“保存”误显示省略号后复测结果相同 |

浏览器手工查看 `profile-home-default`→`profile-details-default`→返回：二级页无主导航，回到“我”后恢复；`moments-personal-default` 的“更多”进入 `moments-interactions-default`；不可查看历史行进入 `moments-interactions-unavailable` 并出现“该内容不可查看”弹窗；`profile-details-edit` 粘贴 13 个汉字后昵称截至 12 字素、计数 `12/12`、出现可关闭的“昵称最多支持12个字符”弹窗；`profile-invitation-history` 有昵称、畅聊号、精确到分钟的时间和加载更多。上述为 HTML 演示交互证据，不替代 Flutter 真机验收。

## 发布前只读基线

在 2026-09-24 08:12–08:15 HKT 通过已配置 jumper 读取：生产 `starchat-business-api-1` 使用镜像 `sha256:f63cb266617819f5f407bba4bac0622fce4bfca83581f6e5ceb72f9c17d92f91`、healthy；worker 使用 `sha256:237162bea8f8b8f8e662daa35ed585b17ee16922fde2eec97ff478892f7860b4`、healthy。`docker exec starchat-business-api-1 alembic current` 因当前 API 镜像缺少数据库已记录的 `0087_support_payout_workflow` 文件而 exit 1；本次候选必须在保持现网镜像基线的同时补齐 0087 和新 0088，先在隔离恢复库验迁移，不把这个旧镜像缺文件误当数据库未升级。

本轮额外运行 `scripts/bump_version.ps1 -Version 0.4.10+2170` exit 0，版本合同 2/2 passed；MI 6 `cbd0156b` online，当前安装版为 0.4.10/2169、`firstInstallTime=2026-09-20 09:35:24`。Flutter 3.44.9/Dart 3.12.2、JDK 17、Apktool 2.12.1、Android build-tools 36.0.0 与固定签名材料均在本机。为候选镜像从包注册表下载锁定的 Linux CPython 3.12 x86_64 `regex==2026.2.28` wheel，SHA256 `d6b08a06976ff4fb0d83077022fde3eca06c55432bb997d8c0495b9a4e9872f4`；仅用这份受控 wheel 构建，不在生产构建时动态取最新版。

## 最终源码与门禁

按计划先做规格符合性复审、再做领域及 Quality/Security 复审。修复了资料审计记录明文、幂等回放重复审计、通知非法游标 500、Flutter 安全存储异常路径及一条旧 UI 假数据签名；每处保留针对性 RED/GREEN。新互动保留失效历史行但对无权目标只输出泛化内容；详情仍由已有可见性策略校验，客户端打开前先取详情，403/404 不导航进入旧缓存。群公告沿用上一轮修复的 Matrix E2EE 路径，金融写入未由客户端通知派生。

- `flutter test --no-pub` **最终 exit 0，4120 passed / 9 skipped**；日志最后写入 10:00 HKT。[最终日志](<C:/Users/Administrator/.codex/visualizations/2026/09/23/01a0d059-a062-7cd3-b140-f324cc27a599/docs/verification/artifacts/2026-09-24/me-invitations-moments-interactions/flutter-full-2171.log>)。较早 4114/9 的全量通过是 2170 中间候选证据，不作为最终客户端源码门禁。
- `flutter analyze --no-pub` **最终 exit 0，No issues found**。[最终日志](<C:/Users/Administrator/.codex/visualizations/2026/09/23/01a0d059-a062-7cd3-b140-f324cc27a599/docs/verification/artifacts/2026-09-24/me-invitations-moments-interactions/flutter-analyze-2171.log>)。
- `pwsh -NoProfile -File scripts/verify.ps1` **exit 0**：后端/worker 2763 passed、77 skipped；移动边界 108 passed、1 skipped；UI 合同 32 组件/429 屏；迁移、OpenAPI 漂移、Compose 渲染均 PASS。[日志](<C:/Users/Administrator/.codex/visualizations/2026/09/23/01a0d059-a062-7cd3-b140-f324cc27a599/docs/verification/artifacts/2026-09-24/me-invitations-moments-interactions/verify-final.log>)。该完整脚本在最后的 Moments 游标修复前启动；修复后受影响的 Moments 两测试文件 41/41 GREEN，未变的后端/合同门禁按工作流影响复用。随后仅 Flutter 群名/红点/更多入口源码变化，已重跑最终全量 Flutter；Python 移动边界、后端、OpenAPI 与 Compose 输入未变，不重复 28 分钟后端门禁。
- 前端演示 `npm test` 305/305、UI registry 429 屏；浏览器已查看实际入口、私密失效提醒、字素截断提示和二级页导航。OpenAPI 从最终源码重新导出并 `--check` PASS。

最终独立审查另发现：建群页/创建控制器仍允许 20 字，旧超限群名在编辑页可原样保存；已补单行 12 字和控制器字素限制，历史值可显示但超限保存被弹窗拦截。群名两测试文件 RED→GREEN **41/41**。我的朋友圈“更多”在临时身份读取失败后可能消失，以及用户停留“我”页或回前台时互动红点不刷新；已加入口容错、进入前实时身份核对、前台恢复/我页每分钟限频刷新和账号隔离，三个聚焦文件 RED→GREEN **16/16**。最终全量 4120/9 覆盖以上新改动，94 个本轮变更 Flutter 文件及锁文件哈希见私有 [源码身份清单](<C:/Users/Administrator/.codex/visualizations/2026/09/23/01a0d059-a062-7cd3-b140-f324cc27a599/docs/verification/artifacts/2026-09-24/me-invitations-moments-interactions/source-manifest-2171.json>)。

## 正式 v0.4.6 基线纠偏与生产发布

用户明确指出手机号等代码**已经上线**，正式 Android 最新版本是 **v0.4.6/2165**。只读比对证实现网后续最小增量 API `f63cb266…` 相对正式 v0.4.6 镜像缺 24 个 Python 文件（含手机号/群主转让/充值等）与 17 个迁移文件；worker `237162be…` 缺 3 个任务；两服务配置均缺正式版已有的 17 个环境键，且自动兑换值与正式配置不同。旧 API 对外 OpenAPI 也没有手机号路由。此现场漂移由本轮候选恢复，不把手机号当新增功能。正式 Android 分发保持原状。

冻结生产原库备份 SHA256 `97491a46…` 于服务器私有 0700 目录；候选 API `sha256:c41dfffc30a3b52f0af179cf58aebfb0ce58db26c09d333881906a01755b7ba9` 使用正式 v0.4.6 功能源与本次资料/朋友圈、上轮媒体/钱包兼容增量；worker 用正式 v0.4.6 `sha256:90696ffa848299cc157daba0a80b0d3ce26a2693c13f1d5b0138ac70c740f1bd`。候选 API 源码树与安装树各 240 文件哈希一致，93 个迁移文件齐全，刷新协议三个镜像各 9/9 通过。兼容 schema0088 的回退 API `sha256:f96c43cca1d118b646417fbde01d527cb653fa00acd8008e2348404ad8a1be9e` 已就绪。

在隔离 PostgreSQL 16.9 恢复生产快照并执行 0087→0088 增量迁移：137 表/225466 行、原表逐项行数及用户资料摘要不变；候选和回退镜像均通过 0088、路由/账本探针，worker 导入通过。生产迁移完成后再冻第二份备份 SHA256 `7d9678dfbc2820e090d3783737c48188f1dbad61ac9fecbd4e9fa4a7fc88dab4`，两备份及私有 Compose 配置仅存服务器 `/opt/starchat/releases/me-invitations-20260924/`。

首次服务切换沿用旧 Compose 环境，API/worker 在配置加载时拒绝“关闭用户兑换但启用自动兑换”的组合，造成短暂服务中断；立即停止切换脚本并恢复原 API `f63cb266…`/worker `237162be…` healthy，数据库保留兼容的增量 0088。随后从已发布 v0.4.6 配置恢复两服务各 17 个缺失键及自动兑换值（正式设置为用户兑换关闭/自动兑换关闭、手机号开启），其他服务字段不变；用真实生产配置先做只读 `Settings()` 和 311 路由装配检查，再重新预检 24 容器、备份、0088、回退镜像、刷新门禁。第二次切换 09:38 HKT 成功。

09:41 HKT 最终生产只读复核：API c41dfffc、worker90696ffa **healthy、零重启、零新 ERROR**；其余 22 容器 ID/镜像/启动时刻不变；schema `0088_profile_grapheme_limits`；服务器端严格 TLS 的 HTTPS ready **200**、未授权朋友圈 feed/互动 **401**；运行时 OpenAPI 311 条路由，手机号登录、邀请历史、互动消息/未读/已读均在位；实际导入的 Moments service SHA 与最终候选一致。生产私有 `predeploy-v4.json`、`deployment-v4.json`、`postdeploy-v4.json` 记录详细身份，敏感备份和环境值不复制到仓库。未代用户执行真实短信、金融交易或好友互动。

10:05 HKT 在最终 Debug2171 安装后重复只读复核，以上容器身份、健康/零重启、22 容器不变、0088、HTTPS 200/401、311 路由、实际导入 SHA 与零新错误日志再次全部通过；`postdeploy-v4.json` 已更新至 `2026-09-24T02:05:48Z`。

## MI 6 测试包

内部测试包 **0.4.10+2171 Debug** 与正式 v0.4.6 属不同发布渠道；2170 是最终审查前的中间包。源码 ARM64 Debug 构建后遵照重建流程使用 Apktool 2.12.1 常规重建 DEX/资源/manifest、16K zipalign、固定用户测试签名。原生资产 339 条和 smali 27317 类与源码中间包一致，manifest 语义一致；`apksigner` v2/v3 与证书 SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff` 通过。[最终 APK](<C:/Users/Administrator/.codex/visualizations/2026/09/23/01a0d059-a062-7cd3-b140-f324cc27a599/docs/verification/artifacts/2026-09-24/me-invitations-moments-interactions/android-debug2171/final.apk>) 145510699 字节，SHA256 `5f3ddee5e9396a31efb16c3aff9c185937f5203bb9b5f950825f1561148aaf20`。[重建内容身份](<C:/Users/Administrator/.codex/visualizations/2026/09/23/01a0d059-a062-7cd3-b140-f324cc27a599/docs/verification/artifacts/2026-09-24/me-invitations-moments-interactions/android-debug2171/verification.json>)。

MI 6 `cbd0156b` 已 `adb install -r` 保留数据覆盖安装，设备读回 base.apk SHA 与本地包一致；最终版本 0.4.10/2171，`firstInstallTime=2026-09-20 09:35:24` 未变；MainActivity 在前台、进程 PID 9641，独立清空的安装后 crash buffer 中无本 App 崩溃。[设备身份记录](<C:/Users/Administrator/.codex/visualizations/2026/09/23/01a0d059-a062-7cd3-b140-f324cc27a599/docs/verification/artifacts/2026-09-24/me-invitations-moments-interactions/android-debug2171/device-verification.json>)。中间 2170 首次设备验证脚本最后记录步骤误用了 PowerShell 只读 `$PID`，安装/哈希/启动已成功；随后只读重验，最终 2171 采用修正后的独立安装验证脚本一次通过。

**待用户验收：** 用真实登录账号和好友在 MI 6 上检查各“我”子页的返回与安全区、邀请历史、字素弹窗、本人朋友圈/互动失效提示、评论/回复提醒，以及上轮八项群聊/媒体/钱包视觉和播放。自动化与启动验证不能代替真实业务反馈。
