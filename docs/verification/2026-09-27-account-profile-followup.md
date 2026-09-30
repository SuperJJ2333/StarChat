# 个人信息与账号设置反馈：实现、服务端发布与 Debug 安装验证

日期：2026-09-27；时间均按香港时间（UTC+08）说明。本文依据实际日志、结果 JSON、冻结源码清单及独立审查记录编写，未重复执行测试。

## 1. 已交付状态与边界

- 本轮五分钟热缓存、统一七项个人信息、邮箱/手机直达设置、365 天修改畅聊号已实现。用户批准的[设计](../superpowers/specs/2026-09-26-account-profile-followup-design.md)、[计划](../superpowers/plans/2026-09-26-account-profile-followup.md)和[ADR](../adr/2026-09-26-mutable-changliao-username.md)是验收依据。
- 服务端经本轮明确发布授权，API/worker 已切换为已审查候选，生产 PostgreSQL 16.9 已升级至 `0089_username_claims`。账号安全路由已从此前缺失的 404 变为正常的未认证 401；没有伪造生产登录会话或执行真实验证码、改号、换绑验收。
- **畅聊 Debug 0.4.15 / 2182 已保留数据安装到 `emulator-5556` 并启动**，包名 `com.liuhetong.mobile.debug`。本次候选包含实际已安装的 `6f11c603` 移动端基线及本轮账号功能。
- 原 D 工作区的并行网络摘要增量保持独立，未包含在本轮 APK 或服务端候选。未执行 Git 提交/远端推送、官网正式包更新或 iOS 发布。
- 完整测试曾有失败，详见第 3 节。最终验收复用未受影响的通过项，并补齐受影响专项；**不声称最终完整 `verify.ps1` 或合并后 Flutter 全量重新取得 exit 0**。

主证据目录：[本轮实现及构建](artifacts/2026-09-26/account-profile-followup/)、[实际生产发布](artifacts/2026-09-27/account-profile-followup/server-release/)。跨会话状态由[任务记录](../workflow/tasks/2026-09-26-account-profile-followup.md)维护；本文不覆盖该文件。

## 2. 需求与证据映射

| ID | 用户要求及实现 | 实际证据与验收层级 |
| --- | --- | --- |
| C1 | 账号安全/聊天在同账号会话内缓存 5 分钟；TTL 内再次进入零 GET、直接展示；过期先展示再后台 singleflight 刷新 | core 重复读取/并发/TTL/会话切换用例；页面热进入测试；`cache/core-focused-final.log` 57 PASS，最终手机 OTP/缓存交叉集合 `cache/phone-401-final.log` 61 PASS |
| C2 | 摘要 GET 支持可信令牌刷新；绑定实际运输未完成前不发布可操作旧摘要；实际完成后再次失效并强制读取 | 邮箱/手机超时后迟到成功、失败及跨会话 pending 用例 4 FAIL → 6 新用例通过；`cache/binding-pending-final.log` 42 PASS。页面 `mobile/binding-page-pending-green.log` 15 PASS，8 秒后退出 spinner、显示待确认并禁用旧动作，实际完成后重读 |
| C3 | 群聊未确认写入不能绕过锁，迟到 GET/PUT 不覆盖新状态或新账号 | pending、串联写入、旧会话用例；`cache/pending-chain-red.log` 保留竞态红证据；核心与页面专项转绿。消息列表读取最新已确认偏好，加载失败不默认自动允许 |
| S1 | 服务端开放账号安全配套接口 | 本地鉴权/脱敏契约及候选 import/OpenAPI 通过；生产服务器、工作站双侧 HTTPS GET `/api/v1/auth/account-security` 均 JSON 401，接口存在且拒绝匿名访问；未进行生产 authenticated 用户操作 |
| P1 | 头像、畅聊号、邮箱、手机号、昵称、个性签名、拍一拍按顺序展示；左标签、右对齐内容及统一箭头；点击独立编辑、绑定直达 | `mobile/profile-regression-final.log` 122 PASS；包含窄屏/文字缩放、路由、保存失败保留草稿、成功立即更新与联系方式显示。合并后新增修复复验见下表；HTML/Catalog 与共享组件同步 |
| U1 | 畅聊号新输入 6–20 位 ASCII、字母开头，其余字母/数字/下划线/连字符；大小写不敏感去重；首次可改，成功后 UTC 365 天一次 | normalized 主键/唯一索引精准检索，登录态可用性查询限频；最终事务唯一约束裁决。`backend/username-green-regression-final.log` 63 PASS，冻结身份专项 19 PASS；客户端策略/失败/冷却路由在页面集合中覆盖 |
| U2 | 新号用于业务登录、好友搜索；UUID/Matrix ID 保持；并发、幂等与旧号冒用保护 | 历史号与 Matrix localpart 永久归属原用户，两条注册路径均检查 claims；同用户行锁及共同锁序。真实 PG18 并发 4 PASS、注册竞争 5 PASS，锁序冻结 delta 10 PASS；实际 PG16 恢复与生产迁移的 UUID/Matrix 摘要均不变 |

缓存只保留脱敏展示摘要和已确认偏好，不保存 OTP、密码、恢复证明或完整联系方式。手机四步 OTP 最终统一固定 Bearer、单次发送；显式 401 不 refresh/replay/匿名降级。该安全 delta 经独立规格及质量审查：[mobile-otp-delta-review.md](artifacts/2026-09-26/account-profile-followup/server-prepare/mobile-otp-delta-review.md)。

## 3. 测试门禁：原始失败、修复与复用

| 门禁 | 真实结果 | 处理及证据 |
| --- | --- | --- |
| 初轮 Flutter 全量 | **4052 PASS / exit 0**，23:36:09–23:39:57，墙钟 228.13 秒 | `flutter-full-final.log`、`flutter-full-result.json`；这是合并实际已安装 `6f11c603` 基线前的结果，不能替代最终合并门禁 |
| 完整 `pwsh -NoProfile -File scripts/verify.ps1` | **2811 PASS / 92 SKIP / 2 FAIL / exit 1**，业务集合 1785.34 秒；命令 23:36:09–00:06:39 | 两个迁移 head 断言仍指向旧 revision。`verify-final.log`、`verify-final-result.json` 原样保留；受影响迁移/基线集合 `migration-head-green.log` **15 PASS** |
| verify 后续门禁首次 | **107 PASS / 1 SKIP / 1 FAIL** | `verify-continuation.log`：版本规范旧正则不能识别新 build；未以之后成功覆盖该失败 |
| verify 后续门禁修复后 | **108 PASS / 1 SKIP**；AST、策略、UI 合同、Alembic、OpenAPI、Compose 均 PASS | `verify-continuation-final.log`；完整原命令仍是 exit 1，后续仅续跑此前未完成/受影响门禁 |
| 实际已安装基线合并后 Flutter 全量 | **4657 PASS / 9 条件跳过 / 10 FAIL / exit 1**，00:16:25–00:23:15；runner 6:32 | `mobile/merged-full.log`、`mobile/merged-full-result.json`。失败涉及 build fixture、诊断/frame fixture、资料编辑/草稿、搜索异步 fixture、次级导航及朋友圈请求 fixture |
| 合并后受影响修复集合 | **53 PASS、46 PASS、7 PASS、20 PASS** | `mobile/merged-root-green.log`、`merged-fixtures-final.log`、`merged-navigation-green.log`、`merged-moments-fixture-green.log`。46 项实际包含诊断失败持久化/退出回填及 config/profile/search 用例，关闭旧 fixture 与编辑恢复状态缺陷；朋友圈恢复真实请求 fixture，导航补真实路由断言 |
| 诊断中间复验 | **20 PASS / 2 FAIL** | 文件名 `mobile/merged-diagnostic-fixtures-green.log` 含“green”，实际仍失败；不据文件名判定成功。之后 `merged-fixtures-final.log` 明确覆盖两条 `failed uploads persist` / `stopSession persists` 并最终 **46 PASS** |
| 合并四文件专项 | 首次 **66 PASS / 1 FAIL / exit 1**；受影响资料集合后续 **27 PASS / exit 0** | `installed-mobile-merge/four-file-focused-result.json`、`four-file-profile-green-result.json` 和 [独立审查](artifacts/2026-09-26/account-profile-followup/installed-mobile-merge/four-file-review.md)；其余未变通过项复用 |
| Flutter analyze | **无问题**；最终发布前 analyzer 21.8 秒 | `mobile/analyze-release-final.log`；合并专项 analyzer 17.5 秒亦无问题。文件格式及源码比对在独立审查中确认 |
| 前端全量 | **318 PASS / 0 FAIL**，1790.22 毫秒 | `frontend/full-merged-final.log`；初轮新需求断言 18 PASS，grapheme 红用例修复后旧全量 317 PASS，最终新增资料验证后 318 PASS |
| UI 合同 | **33 components / 462 screens PASS** | `frontend/ui-contract.log`；HTML 与 Flutter 组件登记及 token 保持一致 |
| 后端/迁移/并发专项 | 63 PASS；冻结 19 PASS；共同锁序 10 PASS；PG18 并发 4 PASS、注册竞争 5 PASS；offline 3 PASS | `backend/` 对应日志；`username-migration-green.log` 为 2 PASS / 4 条件跳过，不把跳过当 PostgreSQL 执行证明。真实 PG16 执行证据见第 4 节 |

复用理由：最终记录包含冻结源码/依赖清单与独立读取比较。通过且未变的测试输入继续复用；后续变化集中在上述失败夹具、资料 no-op 恢复状态、导航及既有基线整合，均运行受影响集合。没有把测试取消、条件跳过、命名为 green 的失败日志或初轮全量通过冒充最终完整重跑通过。[最终移动审查](artifacts/2026-09-26/account-profile-followup/mobile/merged-readonly-review.json)分别给出规格与质量/安全 PASS，原诊断基线及本轮缓存/OTP 语义比对通过。

## 4. PostgreSQL 16、生产发布与兼容回退

### 隔离恢复与迁移

准备阶段使用生产同版 PostgreSQL **16.9**，internal 任务网络、无公开端口。只读一致性备份 27,047,179 bytes，SHA256 `4580264cd588ac9346dd49ebae11bac4690535ffe30a54bc85447640e1240005`，保留在服务器 0700 目录。

实际恢复的 **137 张既有表 / 262,371 行**保持计数，UUID/Matrix 摘要不变；在线迁移与实际 offline SQL 的 claims owner/time、列、索引、revision 均一致，46 条归属匹配。冲突夹具实际 psql **exit 3 为预期拒绝**：保留原 2 个用户、0088 revision，未添加新列或 claims 表。Unicode 大小写归一化实际验证 11 个 ASCII fold、4 个拒绝形式和旧 ASCII 大写：16 users / 28 claims，在线与离线一致。

证据：[prepare-sanitized.json](artifacts/2026-09-26/account-profile-followup/server-prepare/prepare-sanitized.json)、[backup-restore-sanitized.json](artifacts/2026-09-26/account-profile-followup/server-prepare/backup-restore-sanitized.json)、[独立准备/回退审查](artifacts/2026-09-26/account-profile-followup/server-prepare/review-and-rollback.md)。

### 实际生产身份与结果

| 项目 | 实际值 |
| --- | --- |
| API 镜像 | `sha256:9083f0279fbc46811e49fd546322ac66c29b572d4b8cc5460478a1915a0701a8` |
| worker 镜像 | `sha256:15659d6c20a464d75fa2a5c81d2c3d91648c8e2e04d0b47fd3871046e85ef638` |
| 明确覆盖 archive SHA256 | `e107aed605f61ba6688fde72fa85e4b08ef22c33027ec3b2c891c2e08bc59ca3` |
| 实际唯一 head | `0089_username_claims (wallet_access) (head)` |
| 新鲜发布备份 | 27,121,763 bytes；SHA256 `5cc916af603498e351485ca2dbdfd9520adc0e817754ff83bf3613723e72a533` |
| 生产迁移保持 | 137 既有表 / 263,072 行计数不变，UUID/Matrix 摘要不变，46 claims 与预期原归属匹配 |
| 范围与配置 | 仅 API/worker 替换；原环境、挂载、端口、网络、入口等配置保留；其余 **25 个容器**身份/镜像/启动/重启数不变 |

生产维护窗口 00:34:22.245–00:34:28.715（6.470 秒）；迁移 2.440 秒。两个服务 healthy、restart count 0。服务器与工作站 HTTPS 两侧均取得 live/ready JSON 200，以及账号安全/改号状态/可用性/PATCH 匿名 JSON 401，TLS 验证保留。实际 PK/FK/64 字符储存边界/nullable timestamptz/owner index 及唯一 head 于 00:49:35–00:49:38 再次确认。

API 新 error 级日志 0；worker **保留 29 条既有 dead-letter 告警**，没有新候选异常或 traceback。发布前快照已有 ledger/wallet 待处理与 DEAD 历史，随后 32 条既有 pending 被原有 reaper 处理；旧 handlers/reaper 字节保留，仅增加账号凭据/手机密码 topic。该独立历史消费缺口没有在本次静默重放、修改或隐藏。初版验证器因列表顺序和 JSON 字段中的 `error` 误判导致的失败结果亦保留，最终语义比较和真实 severity 分类通过。

Worker 只检查 SMTP/Aliyun 配置类及秘密是否存在；未发送邮件/短信。最终生产详情与真实命令退出码：[task-report.md](artifacts/2026-09-27/account-profile-followup/server-release/task-report.md)、[release-sanitized.json](artifacts/2026-09-27/account-profile-followup/server-release/release-sanitized.json)、[最终验证结果](artifacts/2026-09-27/account-profile-followup/server-release/server-verify-final-green-result.json)、[双侧 TLS](artifacts/2026-09-27/account-profile-followup/server-release/workstation-tls-sanitized.json)。

### 回退

未执行生产回退。兼容 API 已准备且真实请求测试通过：`sha256:1045b2b6c4e50144ed1d5233808990cd854b4a89c42d4fc5e5be554eb2fa3ad2`，配合当前 candidate worker，保留 0089/schema、历史号 claims、归属审计及共同注册锁序。兼容入口仅禁用三条新改号路由（实际 404），保留既有资料、开户、账号安全和绑定路由。改号后直接回退原 r4 开户逻辑或删除 claims/破坏性 downgrade 不安全；数据库全量恢复仍需独立评估后续写入。

服务器私有备份、候选/兼容镜像和任务 volume 保留；本任务隔离 PG16 于 00:55:15 停止，其他测试/生产服务未停止，见 `cleanup-owned-pg-sanitized.json`。

## 5. Debug 2182 构建、重建与安装

候选源码冻结于 **00:31:53.898**，`source-freeze.json` 记录 1346 个文件、已安装基线 `6f11c603`、版本 0.4.15/2182；该清单自身 SHA256 为 `055c67f2f22ddb6c0b965bd67f2f983c93c9032a60b80082b90b64d4610abbb8`。

源码构建 00:31:54.209–00:34:55.874，exit 0，ARM64 standard Debug、独立 `.debug` 后缀，business/Matrix/Getui 均使用生产 HTTPS 域名。随后执行 Apktool 常规 DEX/resource/manifest 重建、zipalign、固定签名及独立最终解码；所有步骤退出 0。

| 交付身份/验证 | 实际结果 |
| --- | --- |
| 版本与包名 | `0.4.15 / 2182`；`com.liuhetong.mobile.debug` |
| 最终 APK | 145,871,147 bytes；SHA256 `44bce182f4321b7051206807a7c59e794d1b22b33da68b8895580cf0456bf1a3` |
| 固定证书 | SHA256 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`，RSA 3072；v2/v3 验签通过 |
| 重建一致性 | ARM64 唯一 ABI；27,317 类、339 native/asset entries 字节/语义一致；manifest 语义一致；25 DEX 与 resources 真正重建 |
| 安装 | `emulator-5556`，保留数据覆盖安装 exit 0，7.354 秒；未卸载或清数据 |
| 设备读回 | SHA256 与 final.apk 完全一致；首次安装时间仍 `2026-09-26 04:06:20` |
| 启动 | PID `17209`、启动/activity 检查 exit 0，本次 launch 无应用 crash lines；installation `passed=true`、`data_preserved=true` |

安装记录生成于 **00:48:19.951**。证据：[source-build-result.json](artifacts/2026-09-26/account-profile-followup/android-2182/source-build-result.json)、[rebuild-steps.json](artifacts/2026-09-26/account-profile-followup/android-2182/rebuild-steps.json)、[verification.json](artifacts/2026-09-26/account-profile-followup/android-2182/verification.json)、[installation.json](artifacts/2026-09-26/account-profile-followup/android-2182/installation.json)。[最终 APK](artifacts/2026-09-26/account-profile-followup/android-2182/changliao-0.4.15-2182-debug.apk) 是交付包；原 Flutter/Gradle APK 只是中间产物。

## 6. 尚需用户/真实设备验收及证据范围

- 真实邮箱/短信验证码、真实账号换绑和改畅聊号、新号登录/搜索的生产用户操作未执行；本轮证明本地契约、并发/迁移和生产路由/配置可用。
- Android 模拟器已安装并启动；真机视觉、系统输入行为与弱网体验仍需用户验收，iOS 未构建/安装。
- D 工作区341项输入已逐文件整合：292项回填、47项相同、2项并行backend/contract保留后重生合同；7项overlay保留6f性能/账号行为及regional待发布源码。独立规格→安全复审通过，114相关测试通过。D全analyze最初5条加括号规范info失败，仅语义相同括号/formatter修正后No issues；API交叉初146PASS/5FAIL仅worker import path未设，补正确PYTHONPATH后5PASS（9项此前覆盖而deselected），OpenAPI check通过。源回填/合同不代表regional功能已发布。[最终回执](artifacts/2026-09-26/account-profile-followup/original-integration/final-result.json)。
- 总主动工时缺少完整早期记录，未知，不由文件修改时间推算。上述测试 runner、构建与维护窗口均有真实日志/结果时间；并行区间不可简单相加成总墙钟。


冻结2182的1346项mobile源码在安装后逐SHA复核均一致，见[构建后来源核对](artifacts/2026-09-26/account-profile-followup/android-2182/postbuild-source-comparison.json)。D包含尚未发布网络摘要源码，与已安装/已上线的冻结来源分开记录。
