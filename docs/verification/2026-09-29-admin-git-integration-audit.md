# 管理台发布后的干净 Git 集成审计

## 快照与边界

本审计只处理新建的 `codex/admin-release-git-integration-20260929` 工作树，起点为本地已知 `origin/main` 的 `971fb50d193ab1a34610bd7908c2dbf6272db431`。它不修改恢复树、管理台树、脏的 `main` 工作区或生产。源树逐文件 SHA 和全部精确路径见[机器可读清单](2026-09-29-admin-git-integration-inventory.json)，快照时间见其中的 `snapshotUtc`。当前没有 fetch；本地已知的 `origin/main` 不代表远端实时状态。集成工作树创建时为干净的 detached HEAD，随后仅在本树建立 `codex/admin-release-git-integration-20260929` 本地分支。

截至 2026-09-29 02:17 +08:00，管理台发布任务报告 v8 已完成生产 `0092`、API `sha256:0bdf751c05015454781c24b66a0c5066ca08ce23436c232ff8aecd1ba5042993` 和 18 个静态文件切换，并经独立双端严格 TLS 复核；一次瞬时容器集合观测 exit 1 被保留为 P3 限制，真实账号登录仍待反馈。最终细节以[管理台验证记录](2026-09-28-admin-entry-merge.md)和[去敏结果证据](artifacts/2026-09-29/admin-entry-release-v8/production-result-evidence.json)为准；结果 JSON SHA256 `7822efd8075e82b8f6bbca89403ae16763a666bfb6cb9c91d2020ffb592803c3`。本集成分支只形成本地提交，不执行生产操作、推送或创建 PR。

恢复树 `codex/restore-published-identity-moments` 的 HEAD 与 `origin/main` 相同，恢复源码和证据尚未提交。管理台树 `codex/admin-entry-merge` 的 HEAD `ae3a26de` 比该基线多三个设计/ADR/任务文档提交，功能代码仍未提交；本地已知两个同名远端分支均不存在。脏 `main` 的 HEAD `b9eca8a4` 比本地已知 `origin/main` 落后 43 个提交，且另有大量其他任务改动，不能作为集成输入。

独立恢复 r2 发布后的 API 为 `sha256:8015e9637fb33c3cf07995612ba1680dbdd3acec4705dee062803517d4bd26d3`，Worker 为 `sha256:3c9e4bbf4760edd173263efb8a8ad2cbee99af9a287402c4d885f5186eaadaaf`，当时生产 schema `0091_moment_video_posters`。已知 `origin/main` 迁移最高仅 `0088_profile_grapheme_limits`，因此 Git 集成不能只拷 r2 的八个发布 payload。管理台冻结 v6 候选目标为 `0092_admin_session_entry_mode`，冻结时尚未发布；v6 manifest SHA 为 `bcc26e76029c17c1fa4d24ba5aa222b225126dffd80c93c3e6740fcf6abf5aa1`。后续冻结 v8 manifest SHA `dc168f6aea06991e3c203109d7a577f51f7f20bb281a0cb86309d98a899fb63b` 的 API 21、静态 18 项 `after_sha256` 与 v6 **39/39 相同**；v8 更改发布探针/元数据，不改变本集成树的候选业务 payload。

## 差异审计

| 来源与层 | 精确文件集合 | 快照核对 | 提交意图 |
| --- | --- | --- | --- |
| 已发布 0091 基线与 r2 恢复 | 清单 `restoreRuntime` 的 54 路径：Business API app 42、迁移 0089–0091 三、Worker app 六、依赖锁两、OpenAPI 一 | r2 manifest 的八个 API payload 与恢复源码 SHA **8/8 相同**；其中 `profile_text.py` 已在 `origin/main`，但发布前镜像缺该文件 | 首个源码提交；不把 r2 八文件误当成从 `origin/main` 可独立运行的全部差异 |
| 恢复相关测试 | 清单 `restoreTests` 十路径 | 含恢复后修订的 `test_client_diagnostics.py`、`test_wallet_release_baseline.py`；原恢复树完整 API 2837 passed/78 skipped、Worker 本地门禁见其验证记录 | 随首个源码提交，保证 0091 head 和已发布行为的断言一致 |
| 恢复与双角色门禁文档 | 清单 `restoreDocs` 七路径 | 恢复任务、计划、验证、当前状态和门禁 ADR/计划/手册 | 六份专项文档已独立提交；共用当前状态仍待管理台最终记录合并 |
| 已安装双角色门禁源码 | 管理台树 `scripts/business_release_guard.py`、`scripts/business_refresh_image_probe.py`、`tests/infra/test_refresh_release_guards.py` | 服务器已安装 guard/probe，但恢复树未改这些脚本；本地角色门禁 34/34 | 单独门禁提交，核对已安装 guard/probe SHA 后再提交 |
| 已发布钱包 T2 静态层 | 清单 `publishedT2` 的三份 JS 和两项验证测试，源自钱包 T2 冻结目录 | 三份 JS 的冻结 SHA 与 2026-09-29 香港时间只读现网 SHA **3/3 相同**；两项测试与冻结验证目录和钱包工作树 SHA **2/2 相同** | 单独静态提交，给管理台 A1 的两个叠加脚本提供真实已发布父版本 |
| 已发布 iOS 下载页基线 | `frontend/download.html`、对应旧版断言 `frontend/tests/home-ios-download.test.mjs` 与两项精确换行属性 | 现网下载页 SHA `4488a024…` 与候选/提交/清洁检出完全相同，页面及已发布 T2 首页均显示 0.4.20（2189）；专项 2/2 | 单独 I0 提交，避免在管理台 A1 文件集合中夹带并行 iOS 更新 |
| 管理台冻结 v8 发布 payload | 清单 `adminReleasePayload` 的 39 路径：API/0092 21、静态 18、Worker 0 | v8 `frozen=true`；源字节、暂存索引 blob 和 `git checkout-index` 清洁检出 SHA 与 `after_sha256` **39/39 相同**，其中 tokens 使用已审阅 overlay | A1–A5/0092 已精确提交；生产结果仍按独立验证记录核对 |
| 测试与契约分层 | 清单 `adminChangedTests` 59 路径：A1 30、已发布 T2 后端 14、T2 前端 1、iOS 1、恢复 1、现有相同 5、旧断言保留 3、已发布 Worker 1、待审媒体存储 3；另 OpenAPI 一 | 14 个 T2 后端测试来自钱包 T2 树；A1 测试 30 个来自管理台树；OpenAPI SHA `a6e95fb5…` 与新增端点一致。未复制三个无关测试的新版本，旧版专项 22/22 通过 | 已发布 T2 测试单独提交；A1 测试和契约随 A1 提交；Worker 测试随已发布依赖层提交 |
| 已发布 Worker 审计依赖 | `services/business-api/app/modules/audit/writer.py`、已有 `tests/business_worker/test_internal_publication.py`、新增 `tests/business_worker/test_published_worker_entrypoint.py` 与 writer 的精确 `.gitattributes` 属性 | 生产 Worker writer SHA `c3a10925…`；真实入口红测重现缺常量的 `ImportError`，补入生产原字节后绿测 1/1，完整 Worker 200/200 | 独立 `b23d1a56` 提交；这是当前 Worker 启动所需已发布依赖，不属于 v8 的 39 项 API/静态 payload |

管理台 API app 相对恢复树恰有 21 个字节差异：v6 列出的 20 个 app 路径全部在内；唯一不在发布清单的是 `services/business-api/app/modules/audit/writer.py`。随后真实 Worker 入口检查证明 writer 是已发布 Worker 镜像的必需依赖，因此另作独立基线提交；v8 API 镜像仍使用旧 writer，详见下文。v6 静态清单的 `frontend/src/styles/tokens.css` 是特别来源：管理台工作树当前文件 SHA `3796a3ecf07afca750e6d6834bdad93c0b6fd7f02954ecac120b1ac50e0ece7e` 包含无关全局 token；已审阅的 `docs/verification/artifacts/2026-09-28/admin-entry-release/static-overlay/src/styles/tokens.css` SHA **`39bebda4b6b18452f79da5fc758bedc20a8b8bb453ff02ad489dfc88046e1853`** 与冻结 v6 一致。集成树只复制此已审阅的生产原字节加管理登录变量，管理台源树保持原样。`origin/main` 比现网 tokens 多出约 48 行未上线的全局视觉变量，此差异在下文单列，不混入 A1 发布 payload。

## 本地集成与验证进度

已在本**新**工作树从恢复树逐文件复制清单中的 54 个 runtime、10 个测试和 7 个恢复/门禁文档，共 71 项；复制前后 SHA 均与快照相同。新树 Business API app 的 250 个可枚举文件及 Worker app 的 20 个文件与恢复树逐字节一致。54 runtime + 10 测试的 staged 路径与白名单 **64/64 相等**、`git diff --cached --check` 通过；随后形成本地 R0 提交 **`971bf35922355491a8a4fc9c02e05ce79a9725b3`**，未 push。六份恢复/门禁专项文档随后形成 R1 提交 `b8b943b25e154e5aa065bce6cea73be7cfd6db8e`；共用当前状态与本审计另行收口。OpenAPI `scripts/export_openapi.py --check` 退出 0。迁移、资料、朋友圈、诊断、搜索及 Worker 聚焦命令真实退出 0：**251 passed、1 skipped、1 条既有 Starlette/httpx 弃用 warning，290.65 秒**；原始本机日志在被 Git 忽略的 `docs/verification/artifacts/2026-09-29/admin-git-integration/r0-focused.log`。恢复树的完整 API 结果仅在源字节相同的覆盖范围内可复用，不能把这次聚焦测试称为集成树完整套件。

双角色门禁两脚本从管理台树复制到本集成树，SHA 分别为 `78b2beb6c20484cea04fa8e77c1dd23b9a3e401af9d6fafd3e4b7d316d07beec` 和 `d77a83e89d848bfc8b6d7dad72b9abd01d60550a6e356d0a12b382674c37b678`，与已安装服务器文件记录一致；对应 infra 测试 SHA `503d0e5643ede9846eb7c20dec858e19cec306e500ef05a100a2cd07220e48f1`。三文件精确 stage、`git diff --cached --check` 和聚焦 **34 passed、exit 0（9.21 秒）** 后形成本地 G0 源码提交 **`4c55e5e58bba1b3093fcf10da54c3f7a0df9c01f`**，未 push。门禁 ADR、计划和手册在 r2 上线状态对齐、相对链接核对后随 R1 文档提交。集成树 `tests/infra` 全量后来 **210/210 通过**。

钱包 T2 冻结 manifest SHA 为 `9505c5460df860b03c5c2cf43f1d6301b399a15dea0479c75c6ac34864b8f8fe`。经既有跳板只读运行现网三文件 `sha256sum` 后，`admin-home.js`、`admin-manual-wallet-panel.js`、`wallet-incident-workflow.js` 依次为 `98438108d3113c89e730175c49c81bd14c182cea4054823f6197a8700670bb7c`、`45a9f02ae3662a0f89ed7dc1ac00ffb811f82b65761c244a2303d42f4860d5f8`、`e03f1fe9fd245a10bff6ec5d7095d71e1424d5b15cffe2ae9a82ccf3dbe11575`，与冻结目录 **3/3 相同**。两项测试来自同一冻结验证目录，分别为 `1c400c2b514e5a2093f3020894a647ac5b9625e81e69aa45144408e1ac990465` 和 `7807bfd6d6d42c5aa03c7375d39ad2550102f806422c83cedca38086858960ef`；测试并非生产部署文件。五文件复制后 SHA 仍逐项相同，三个 JS 的 `node --check` 和两项测试的 Node 聚焦运行 **62 passed、0 failed、exit 0**；精确 staged 五文件及 `git diff --cached --check` 通过。本地 T2 提交为 **`2fdbd1cebc040bab0cac1749b76893476b0a0ad6`**，未 push。`optional/admin.html` 不在冻结必需清单，因此未纳入。

初次 Git 索引核对发现：恢复层 8 个运行文件和 2 个测试、T2 两项测试被默认换行转换，虽然当前工作树 SHA 正确，原提交 blob 不等于源字节；另两项纯 LF 文件会在 Windows 干净检出时变为 CRLF。B0 提交 **`512f4ad4226612f0d695a5babc55bc70e4a5ddcb`** 只对 15 个精确路径设 `-text`、2 个设 `text eol=lf`，并重录 12 个受转换影响的原字节。忽略行尾差异后，该提交除 `.gitattributes` 外无语义内容差异。用 `git checkout-index` 模拟清洁检出后，恢复 runtime 54、恢复测试 10、门禁 3、T2 静态 3 和 T2 测试 2 的源 SHA、索引 blob SHA、检出 SHA **72/72 相同**；这比当前工作树复制 SHA 更能证明以后构包可重现。

现网下载页和管理台树候选的 SHA 都是 `4488a024ae32c4ca1b475b4d1baf104ac276966a64fe8df66e5c12756543d984`，与已发布 T2 首页同示 iOS `0.4.20（2189）`。原 `origin/main` 的首页下载测试仍断言 `0.4.7（2173）`。I0 提交 **`f7e13a5338585d5a88241d8e65ada44694d23b9f`** 仅纳入现网 `frontend/download.html`、对应版本断言和两项精确路径 `.gitattributes`；下载页及测试的源、索引、清洁检出 SHA 均相同，专项 **2/2 通过**。这层属于已经上线的 iOS 基线，不属于 A1。

冻结 v8 的 21 个 API/0092 与 18 个静态输入已复制到新集成树，39 个源 SHA 与 `after_sha256` 相同。经精确路径换行属性处理，v8 **39 payload** 加已安装 guard/probe **2**、已发布 T2 `wallet-incident-workflow.js` **1** 的原始字节、索引 blob 和 `git checkout-index` 模拟清洁检出 SHA **42/42 相同**。A1 提交前暂存的 71 个非文档路径恰与 39 个 payload、30 个 A1 测试、OpenAPI 一项和根 `.gitattributes` 一项白名单相等，额外路径 **0**；`git diff --cached --check` 通过，已形成本地提交 **`ad37b91411e8d0ddb6f1880235c80f598cab7231`**。v6 的 11 个静态 `before_sha256` 初看与 `origin/main`+T2 不同；其中 10 个仅是 CRLF/LF 差异，文本内容完全相同且当时现网 SHA 与 v6 `before_sha256` **11/11 相同**。唯一实质差异是 `tokens.css`：`origin/main` 有未上线的全局视觉变量，而 v8 使用已审阅的现网 overlay 字节。相应 `.gitattributes` 的 A1 精确路径增补随 A1 提交。新版 OpenAPI SHA `a6e95fb56393345b7b81cb879306078e40c2efa9779a1ebc219ca2cfdda84681`，`--check` 及契约测试 **4/4 通过**。

测试分层后，14 个 T2 后端测试与钱包 T2 工作树逐字节一致，源、索引与模拟清洁检出 SHA **14/14 相同**；wallet API 专项 **366 passed、1 skipped**，告警邮件测试包含在当时 Worker 全量 **122/122 通过**中；补入已发布 Worker 依赖层后的最终全量 **200/200 通过**，随后形成本地提交 **`967f3c511260994bb61e51a4e0465d4407787328`**。30 个 A1 测试来自管理台树，复制原始字节 SHA **30/30 相同**，已随 A1 源码提交。管理台/钱包/iOS 前端专项 **153/153 通过**；A1 API 的 17 个测试文件专项 **211 passed、4 skipped、1 条既有 Starlette/httpx 弃用 warning，exit 0**，本机日志见 `artifacts/2026-09-29/admin-git-integration/a1-api-focused.log`。保留旧版 `test_user_search.py`、`test_wallet_operations_wiring.py`、`test_worker.py` 后，针对已集成运行时代码聚焦 **22/22 通过**，无需引入畅聊号发现调整；internal-publication 已发布 Worker 基线另行验证。

已发布 Worker 依赖层的红测在本集成树真实导入 `app.main` 并构建 11 个 internal-publication handlers 时复现 `ImportError: cannot import name INTERNAL_PUBLICATION_TOPICS`；红测记录在 `artifacts/2026-09-29/admin-git-integration/worker-entry-published-red.log`。只读生产 Worker 镜像核对：`main.py` SHA `03b74f5ec9283464b8a1596dad142dd1a01bdc2e0fdb9211c248f84c67e3c4c1`、`tasks/internal_publication.py` SHA `1e50d4b0bc09c9b7dd1a33c208dbc30c8795e870faf5cd8111189a1341325b2d` 与集成树逐字节一致；Worker 镜像的 `/opt/business-api/app/modules/audit/writer.py` 及 site-packages 版本 SHA 均为 `c3a109258bccdfe982953913c45c4f8e267a57ac1c43ead4ecd965784b8c940a`，入口从 site-packages 导入，生产构建返回 11 个 handlers。集成树引入同 SHA writer，并对该精确路径设 `-text` 后，源、索引 blob、模拟清洁检出三者的 raw SHA 与生产 Worker **4/4 相同**；真实入口绿测 **1/1**、既有 internal-publication 测试 **77/77**、Worker 全量 **200/200**，API 审计/Outbox/钱包审计/账本专项 **24/24**，Ruff、compileall 和差异检查通过。本层为 `b23d1a56e8a0e3541cc4a9696409f192e319dfb7`，仅 writer、两项 Worker 测试及根 `.gitattributes`。**v8 当前 API 镜像的 writer 仍为 `afd549de3ff75076fad022ed651a5bd830cc90ed64d6ee84cb01db61a6c7b795`，v8 冻结的 39 项 payload 不含 writer；集成分支是供未来统一构建的源码超集，不能据此称当前 API 镜像与分支全部逐字节相同。未来由本分支重建 API 镜像时，该 writer 变化须另过 API 侧门禁。**

原管理台树完整 API 已独立 exit 0：**3032 passed、83 skipped**。新集成树的 21 项冻结 API/0092 payload 与原树 raw SHA **21/21 相同**，前述三个保留旧版测试文件聚焦 **22/22 通过**。本树另启动一次完整 API，但它运行至 23% 时，按项目证据复用规则于 **2026-09-28 17:32:30 UTC** 有界 Ctrl-C 主动停止，进程退出码 1；保留原日志及[停止记录](artifacts/2026-09-29/admin-git-integration/api-full-stop.json)。该中断**不是全量通过证据**，本树的 A1/T2 新测试以原树全量结果、逐文件 SHA 和本树上述专项共同判断。

前端全量首轮 **339/345 通过、6 失败**。其中 iOS 旧版本断言已由 I0 的已发布基线修正且专项 **2/2 通过**；余下五项在 A1 提交后再次聚焦复现：三个文件共 **10 passed、5 failed、exit 1**，日志为 `artifacts/2026-09-29/admin-git-integration/frontend-css-conflict-focused.log`。`gradient-divider.test.mjs` 两项、`group-moments-wallet-demo.test.mjs` 一项、`token-contract.test.mjs` 两项分别要求渐隐分隔线/品牌淡底、公告色、浅深主题新增键和客服身份黄色。发布前现网 `tokens.css` SHA `ac5bcdcd…` 与 v6 before 相同；现网 `primitives.css` SHA `570ec161…`、`components.css` SHA `b429df9b…`，当时现网 styles 检索不到这些变量的定义或引用。它们是 `origin/main` 与现网 CSS 的历史差异；保留原测试并记录全量门禁失败，不修改冻结 v8 payload，不把未上线视觉变量混入 A1。管理台生产发布按原工作树冻结包及独立验收判断；Git 分支在协调此主线测试差异前不可合并。

已发布 Worker 的 `services/business-api/app/modules/audit/writer.py` 已按生产原字节单独集成。管理台树的 `test_user_search.py` 新版涉及非本次畅聊号发现/排序，`test_wallet_operations_wiring.py` 新版涉及另一条 internal-publication handler，`test_worker.py` 新版只调整格式顺序；三个旧版在集成树已通过聚焦测试，不同步新文件。另三项 `review-hold` 测试涉及媒体存储，未核准归属前不纳入 A1；internal-publication 测试属于已发布 Worker 基线。`docs/verification/artifacts/` 受共享 `.git/info/exclude` 忽略，恢复树和管理台树本日期目录在初始快照时分别有 109 与 356 个被忽略条目；本次仅对已逐项复核的 12 个视觉/历史/生产证据文件使用精确 `git add -f`。其余被忽略证据不会因普通提交或受管工作树归档而保留，归档前仍须单独保存。

最终文档层逐字节复制原管理台工作树的设计、ADR、实施计划、任务、验证和 `current-state` 新状态段；纳入本审计与机器清单，共 8 份文档。任务/验证直接引用的 7 份历史证据、已选定登录视觉稿和 4 份 v8 去敏生产/回退证据按清单 **12 个精确路径**单独复核 SHA、字节数，再强制暂存，未递归纳入忽略目录。两名独立检查者扫描令牌、口令/密钥赋值、PEM、JWT、邮箱、手机号、钱包地址、完整请求查询等敏感模式均无命中；两处 IPv4 均仅为 `127.0.0.1`。Git 默认换行曾令其中 7 项索引或模拟检出 SHA 变化，根 `.gitattributes` 只对这 7 条精确路径加 `-text` 并重录；最终 12 份证据的源、索引 blob、模拟清洁检出 SHA **12/12 同原树**。新管理台文档及审计相对链接均可解析；`current-state` 旧历史部分另有 16 个本任务前已存在的失效链接，未扩大本次范围。

## Git 远端与 CI 风险

2026-09-28 18:25 UTC 再次只读 `git ls-remote --heads origin refs/heads/main refs/heads/codex/admin-release-git-integration-20260929`：远端 `main` 仍为 `971fb50d193ab1a34610bd7908c2dbf6272db431`，与本地 `origin/main` 和本分支 merge-base 相同；目标远端集成分支尚不存在。未 fetch、push 或创建 PR。最终 `origin/main..HEAD` 的 **179 个**改动路径由前九个提交的 **159 路径**加精确 8 份文档、12 份证据组成，白名单 **179/179 相同，额外 0**；工作树无未暂存或未提交变更。仓库策略、部署策略均 PASS，本树 `tests/infra` 全量 **210/210 通过**。

`.github/workflows/android-ci.yml` 因 `services/**` 与 `tests/**` 改动会在 PR 上运行后端、移动边界、Flutter 等任务；仓库 GitHub 工作流与 `scripts/verify.ps1` 当前均没有执行 `frontend` 的 Node 全量套件。因此即使 PR 检查显示绿色，也不能覆盖上述五项前端本地失败。Linux CI 尚未在此本地分支实跑，原管理台工作树的 Business API 全量 **3032 passed、83 skipped** 与本树专项、原始 SHA 可以作为同输入证据，但不能写成本分支 CI 成功。安全的下一步是在最终文档收口后推送本分支并建立明确标示五项红项的 **draft PR** 供审阅；合并前须对主线未上线视觉断言与已发布静态字节作独立协调，不能删测或修改冻结 v8 发布文件来制造全绿。

## 本地提交与 PR 顺序

1. **R0：已发布 0091 源码和 r2 恢复。** 在本集成树按清单 `restoreRuntime` 和 `restoreTests` 精确复制并比对 SHA；先核对唯一 0091 head、OpenAPI、导入、相关测试与 `git diff --check`，只 stage 白名单。相关恢复/门禁文档可为紧随其后的提交。R0 的完整源必须代表已发布 r2，不能只提交八文件 overlay。
2. **G0：已安装的角色门禁。** 从管理台树只复制两脚本与对应 infra 测试，并核对生产 guard/probe 已知 SHA、API 9/9 与 Worker 8/8 证明。保留 ADR/实施计划；服务器脚本已安装不等于 Git 源码已集成。
3. **T2：已发布钱包监控静态层。** 用冻结目录中三份现网 JS 和两项验证测试单独提交；A1 之后覆盖其中两份 JS，第三份保留为已发布 T2 基线。
4. **B0：Git 字节保真。** 只修改已核实会被自动换行转换的精确路径属性，重录原始字节；恢复/门禁/T2 基线 72 项的源、索引、清洁检出 SHA 全同。
5. **I0：已发布 iOS 下载页。** 在现网与候选 SHA、版本双重一致后，单独提交下载页及其版本断言；不列入 A1 payload。
6. **T2 后端测试。** 14 项来自钱包 T2 工作树，专项及字节复现验证通过，已作为独立本地提交。
7. **A1：管理台 A1–A5/0092。** 以完成的已发布基线为父提交，从最终 v8 manifest 逐路径核对 21 API/迁移与 18 静态；tokens 使用上节 overlay。只纳入经审阅归属的 30 项 A1 测试及更新 OpenAPI，已形成本地源码提交 `ad37b91411e8d0ddb6f1880235c80f598cab7231`。已批准设计、ADR、计划、任务/验证记录在生产最终记录质量复核后逐字节核对并单独提交；未盲目 cherry-pick 三个旧文档提交（其中含历史草图工件与旧状态）。
8. **已发布 Worker 依赖。** `b23d1a56` 仅补入生产 Worker 实际导入的 writer 和对应两项测试，保留当前 API 镜像 writer 差异审计；未来 API 重建独立验证。
9. **最终文档与证据。** 按源 SHA 精确纳入管理台设计、ADR、计划、任务/验证/当前状态及本集成审计与清单；12 个已去敏并核对 SHA/尺寸的既有证据只逐文件强制纳入。
10. **远端集成。** 推送前再核验远端 `main`、比较本地和远端、审查 staged 路径与 SHA；draft PR 必须显式列出前端五项失败和不可合并状态。当前不 push、不建 PR、不合并到脏 `main`、不归档两个源工作树。任何源 SHA 或最终发布清单变化都先更新本审计，再继续集成。

本文件记录 R0、G0、T2、B0、I0、T2 后端测试、R1 文档、A1 源码和 Worker 依赖层共九个前置本地提交；管理台最终文档与本审计、所需证据另作第十个文档提交。管理台 v8 已由原发布任务完成技术发布和独立复核，真实账号验收与本分支的五项主线视觉测试冲突仍分别保留。
