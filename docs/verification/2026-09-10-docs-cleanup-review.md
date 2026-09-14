# docs 目录冗余与构建产物管理审核清单

> **审核已通过：** 用户于 2026-09-10 明确批准按本清单整理、归档和删除。[执行记录](2026-09-10-docs-cleanup-execution.md)记载实际处理结果。以下保留审核时的原始结论与统计，不作为整理后的当前磁盘快照。

审核日期：2026-09-10。状态：**待用户审核；没有删除、移动或改写任何既有文件**。

本次将“构造文件”按构建产物、解包目录、源码快照、临时脚本以及重复/过时文档一并检查。仅新增本审核报告与同主题的扫描证据，不修改产品行为、发布配置、CodeGraph 索引或保留策略。

## 1. 结论与范围

- 存在需要清理或归档的构建中间产物；不能将 `docs/verification/` 或 `artifacts/` 整体删除。
- 对 `rg --files docs -g '*.md' -g '!**/artifacts/**'` 返回的 **539 份 Markdown** 计算 SHA256，未发现字节完全相同的重复文件。这个结论不等于没有语义重复，也不覆盖忽略目录中的所有 Markdown。
- 上述文档分布：根目录 16、verification 264、figma 1、reports 1、plans 2、adr 28、testing 1、runbooks 34、superpowers/specs 39、superpowers/reviews 1、superpowers/plans 152。
- CodeGraph 已优先使用：`codegraph explore "docs documentation artifacts build outputs obsolete Figma workflow references"`。结果包含 `docs/verification/artifacts/2026-09-10/admin-completion/production/server_release.py`，说明验证脚本进入了代码检索范围；CodeGraph 不能替代磁盘清单、内容哈希与文档引用核查。
- 文件树统计包含隐藏/忽略文件；大小为文件逻辑字节数，不等于 NTFS 实际占用，也不代表可立即回收空间。重解析链接不作为真实副本计数。扫描非原子快照，其他任务可能继续产生文件。
- 当前 `.git` 实际存在。扫描开始时既有修改为 `docs/verification/2026-09-10-platform-release-2085.md`，本任务未改动它。即使存在 Git，也不能假定忽略或未提交的源码快照已备份。

## 2. 可逐项审核的文档治理清单

以下路径均相对仓库根目录。A 表示合并/退役入口；B 表示历史归档；C 表示保留并修正文档管理。不建议仅因日期旧或没有检索到引用而删除。

| 编号 | 文件/目录 | 建议 | 事实与理由 | 审核后的执行前提 |
|---|---|---|---|---|
| A01 | `docs/ME.md` | 合并后删除，或改为短跳转入口 | 仅 181 字节，为激活码生成速记；与 `docs/runbooks/activation-codes.md` 重叠，命名不能表达用途，SSH 示例未使用当前默认 jumper | 将其中 `/opt/starchat` 工作目录和 `exec -T` 等有用细节补入正式 runbook，同时按当前接入规则修正示例；本次常规仓库文本引用检索未见直接引用，不等于外部无书签 |
| A02 | `docs/ui-development-figma-workflow.md` | 标记 Retired，并链接新版；保留历史正文 | `docs/ui-development-html-demo-workflow.md:3` 明确 supersedes 旧流程，但旧文件仍显示 Approved；`scripts/verify_ui_contract.py:15` 已禁止 registry 的 figma 字段 | 首选原址增加退役说明，避免历史计划/验证记录链接失效；不直接删除 |
| B01 | `docs/figma/chatflow-ui-delivery-registry.json` | 冻结为历史台账 | 记录旧节点、2026-09-09 工具不可用和远端未同步状态；现行流程已转为 Flutter–HTML；不是现行组件 registry | 历史记录继续保留，停止作为新 UI 交付门禁；迁移时更新引用或保留入口 |
| B02 | `docs/figma/chatflow-ui-parity-ledger.md` | 标注 Historical | 是 2026-08-25 交付限制的事实记录，且指向 `figma-mobile-screen-contract.csv`，有证据价值 | 与 B01 一起管理，不能把历史 blocked 改写成已完成 |
| B03 | `docs/verification/figma-mobile-screen-contract.csv`、`docs/verification/figma-chat-friend-update-2026-08-17.png` | 历史设计证据保留/归档 | CSV 有旧计划和 parity ledger 引用；PNG 属旧设计证据，不能因 Figma 退役就推断没有价值 | CSV 不在本次正文哈希核查范围；截图是否可清需确认最终版本、里程碑和媒体保留条件 |
| B04 | `docs/ChatFlow_Codex_审计修复Prompt.md` | 从根目录导航降级为历史审计需求，保留文件 | 与 `docs/plans/chatflow-audit-remediation.md`、`docs/reports/chatflow-audit-remediation-result.md` 分别是需求、计划、结果，不是三个重复副本；含资金与账号隔离审计上下文 | 三者互相加链接、标明执行状态；不要删除财务审计链 |
| C01 | `docs/plans/chatflow-audit-remediation.md`、`docs/plans/chatflow-chat-ux-spec.md` | 统一计划导航，必要时迁入 `docs/superpowers/plans/` | 当前存在两套 plans 目录；聊天 UX 计划还写有历史拉取、帧延迟、旧组件替换等待做项，不能按“旧计划”直接清空 | 先逐项核对状态；迁移时更新 Prompt/报告等引用。更低风险方案是在统一索引中收录两份 |
| C02 | `docs/RUNBOOK_RELEASE.md` | 收敛为发布入口，旧流水线部分明确标历史/受限 | 已有 APK 重建提示，但正文仍有 APK×3、多 ABI 和旧 CI 示例；容易与当前仅 ARM64、固定签名流程混读 | 以 `runbooks/android-apk-rebuild.md` 和 `runbooks/app-release-deployment.md` 为对应打包/发布权威；保留 CI 特有操作说明。测试源码也引用此路径，移动需联动核查 |
| C03 | `docs/runbooks/mobile-release.md` | 保留 iOS 说明，更新 Android 章节 | 当前 Android 示例使用 `--split-per-abi`，与 2026-09-06 单架构门禁有出入；iOS 签名/模拟器内容仍独立有用 | 不删除整个文件；Android 示例指向现行固定打包流程，分别说明平台职责 |
| C04 | `docs/RUNBOOK_PRODUCTION_CONFIG.md` | 纳入 runbooks 索引；可改规范名称并保留旧入口 | 讲模板渲染、配置漂移、bind mount inode 等，不能被 APK 发布文档替代；有验证报告引用 | 迁移须更新引用；单纯移动不能宣称消除了重复 |
| C05 | `docs/verification/README.md` | 澄清保留策略 | “90 天”与“里程碑上线后即可清理”需说明何者优先；“代码快照 Git 可回溯”对被忽略的源码副本不一定成立；长期在用工具与临时脚本混放 | 明确角色、例外、恢复验证、归档位置和审批记录；本次未擅自修改既有保留期 |
| C06 | `docs/ui-development-html-demo-workflow.md` | 保留，另做术语一致性核对 | 新旧 UI 文档均用“点钻”，本轮用户提供的 AGENTS.md 要求 CAIBI 展示名“彩币”；是文档与上级规则冲突，不是冗余 | 依据上级规则协调术语；本次仅记录，不修改 UI 行为或金融标识 |
| C07 | `docs/ANDROID_SECURITY_AUDIT.md`、`docs/DIRECT_CHAT_ANDROID_COMPATIBILITY.md`、`docs/FRIEND_SYSTEM_REFACTOR.md`、`docs/MEDIA_PICKER_FIX.md`、`docs/NOTIFICATION_QA_MATRIX.md`、`docs/NOTIFICATION_SYSTEM.md`、`docs/PERFORMANCE_AND_CACHE_AUDIT.md`、`docs/PUSH_SETUP.md`、`docs/TURN.md`、`docs/VIDEO_SEND_PIPELINE.md` | 保留，补充主题索引及 Current/Historical 状态 | 未取得足以证明可删除的证据；规格、实现说明、测试矩阵、运维指南不能仅因主题接近视为重复 | 后续按所属功能负责人核对时效。本次未逐段验证这些文档与所有现行代码的一致性 |

## 3. 构建产物与快照：按类型审批

| 编号 | 实际路径或筛选范围 | 建议处理 | 必须保留/核验的内容 |
|---|---|---|---|
| D01 | 扫描附录中 `build`、`.dart_tool`、`.gradle`、`node_modules`、`__pycache__` 目录 | 优先清理候选；仅限验证副本中的可再生产物 | 先确认无构建进程占用，最终安装包、日志、锁文件、源码改动已独立保存；`build` 可能嵌有唯一 APK 或符号文件，不能无条件整删 |
| D02 | 扫描附录中 `decoded`、`verified-decoded` 及解包快照 | 验证完成后删除可再生部分，保留工具/结论 | 保存原始 APK、SHA256、工具版本、命令与差异报告；确认 smali/resource/manifest 无唯一手改。当前已知 8 月 24 日之后的样本截至 9 月 10 日未满 30 天，提前清理需本次明确批准 |
| D03 | `docs/verification/plain36/src/`、`docs/verification/nomin36/src/` | 拆分源码与生成缓存；缓存优先，独有源码归档 | 两份分别关联 b80049b3… 与 1879a0d5…，构建选项不同；必须比较 source.zip、Git 基线及局部改动后才能判定源码副本冗余 |
| D04 | `docs/verification/plain36/source.zip`、`docs/verification/nomin36/source.zip` | 归档，不能按同版本号去重 | 大小分别 14,309,287、13,303,816 字节，源基线不同；可作为恢复来源但本次未验证 ZIP 与 src 全树一致 |
| D05 | `docs/verification/plain36/ChatFlow-0.3.36-arm64-plain.apk`、`docs/verification/nomin36/ChatFlow-0.3.36-arm64-no-obfuscation.apk` | 历史实验包迁入工件库，各保留一份 | 大小分别 75,357,113、73,752,005 字节，README 所记哈希不同；使用旧证书且不是现行正式交付。保留 README、SHA256、signature、manifest、badging、build.log |
| D06 | `docs/verification/ChatFlow_2026年09月05日20点15分.apk` | 移到按日期/主题管理的样本工件区或外部归档 | 用户提供的 0.3.38 修改样本，被 `2026-09-05-modifier-apk-comparison.md` 引用，不是无用安装包；移动后同步路径，保留样本原字节与哈希 |
| D07 | `docs/verification/artifacts/2026-08-24/public-apk-audit-1/` | 分离可再生导出与长期 APK 审计证据 | README 已列为候选，但 2026-09-10 距 8 月 24 日仅 17 天，不能声称 30 天到期；原 APK/审计结果按发布证据保留 |
| D08 | `docs/verification/artifacts/2026-08-28/admin-modernization/MODIFIED_FILE/` 及其他 baseline/rollback/source 快照 | 先压缩归档，完成恢复比对后再考虑本地删除 | README 列为候选，距 8 月 28 日仅 13 天；目录可能包含没有进入 Git 的版本与回滚依据，不认定为纯缓存 |
| D09 | `docs/verification/screenshots/` 和各主题截图/录屏 | 同主题只在人工确认后保留最终证据；其余归档 | 不根据 `final` 文件名自动选优；页面、账号、设备、深浅色、前后状态可能不同。8 月 14/17 日截图尚未满 90 天 |
| D10 | artifacts 中 `.apk`、`.ipa`、`.zip`、`.tar*` 大文件 | 以 SHA256 + 发布身份建立工件目录；确认为同字节副本后才物理去重 | 保留每个发布/回滚版本和关键诊断样本；本次没有对全部大型二进制做 SHA256，附录只表示体积，绝不表示已经证明重复 |
| D11 | artifacts 中一次性 `.py`、`.ps1`、`.sh` | 随主题归档；反复调用的工具提取到 `scripts/` | 必须核对 runbook 的实际引用。文件后缀是脚本、处于临时目录，均不能单独作为删除理由 |

## 4. 明确不应直接删除的对象

1. `docs/adr/`、产品设计规格、金融/账本/钱包/红包/E2EE 证据：依据现行 verification README，相关审计证据永久保留。已完成计划和结论报告保留，仅优化索引。
2. `docs/verification/artifacts/2026-09-05/background-call-signature/sign-diagnostic.ps1`：现行 APK runbook 直接指定它。可先提取长期工具并更新引用，不能连同 background-call-signature 全删。
3. `docs/verification/artifacts/2026-09-05/apk-rebuild-test/`：runbook 指向其中验证工具，且记录用户确认的签名/打包基线。只能逐项分离工具、原包与可再生解包树。
4. `docs/verification/artifacts/2026-09-10/admin-completion/production/`：`admin-completion-deployment.md:22` 指定发布工具及 manifest；保留发布复现/回滚链。
5. `docs/verification/artifacts/2026-09-10/wallet-access-production/`、`media-production-release/`、`android-release-2077-distribution/publish_settings_2077_pageurl.py`：都有现行部署 runbook 引用，不能按日期批删。
6. 当前日期 2026-09-10 的发布和集成目录：即使存在 build/decoded，也要先确认相关任务结束且交付、回滚、证据齐全；不将“今天的大目录”放进立即清理批次。

## 5. 建议的审批批次

- **第一批：文档入口治理。** A01 合并；A02 标退役；B01–B04 标历史；C01–C07 加索引、修正冲突。保留有历史引用的路径，避免为目录整洁制造失效链接。
- **第二批：已结束主题的可再生缓存。** 从扫描附录选择具体目录，先保存唯一产物、核对进程与恢复条件；批准清单应列到目录，不能写成 `artifacts/**` 通配删除。
- **第三批：大型工件归档。** 原包、最终包、哈希、签名、源码/依赖与验证日志成套归档；归档后重新读取核验哈希与可恢复性，再移除本地副本。
- **第四批：检索治理。** 为 CodeGraph 配置适当排除构建/解包/快照树，保留正式脚本检索。本次只确认产物进入索引，未测量其占比，也未修改索引或声称已解决性能问题。

建议新增 `docs/README.md` 统一导航，并给活跃文档补 `status`、`supersedes`、`owner`、`last_verified`；给每个工件主题补 manifest（角色、哈希、源码基线、依赖、关联报告、保留类型、归档地址）。这些是待审建议，本次没有实施。

## 6. 审核边界

这是本地目录与文档依赖审核，不是线上发布核查、完整密钥扫描、全量二进制去重或所有历史需求的完成度审计。未访问服务器或远端 Figma。没有因为生成本报告而运行产品测试；没有产品代码改动。任何未来删除前须再次扫描候选路径和依赖，避免其他任务在本次统计后新增唯一证据。


## 7. 磁盘统计与优先级（完整扫描）

本报告采用已落盘 inventory.json 的快照：**2,329,571 个文件、76,454,624,705 字节（71.20 GiB）**，读取错误 0。扫描过程另一次计数因当日工件写入略有变化，因此这里统一使用该快照；这不是静止目录的原子取样。

[全部目录及大文件清单](2026-09-10-docs-cleanup-inventory.md) · [原始统计 JSON](artifacts/2026-09-10/docs-audit/inventory.json) · [抽样 APK 哈希](artifacts/2026-09-10/docs-audit/selected-apk-hashes.json)

### 类型规模（不可直接当作回收量）

| 类型 | 文件数 | GiB | 建议 |
|---|---:|---:|---|
| `decoded` 筛选桶 | 1,119,541 | 14.740 | 按第 3、4 节条件处理 |
| `verified-decoded` 筛选桶 | 1,093,995 | 14.462 | 按第 3、4 节条件处理 |
| `build` 筛选桶 | 51,301 | 5.624 | 按第 3、4 节条件处理 |
| `.dart_tool` 筛选桶 | 154 | 0.352 | 按第 3、4 节条件处理 |
| `.gradle` 筛选桶 | 76 | 0.085 | 按第 3、4 节条件处理 |
| `node_modules` 筛选桶 | 3,553 | 0.034 | 按第 3、4 节条件处理 |
| `__pycache__` 筛选桶 | 6,431 | 0.077 | 按第 3、4 节条件处理 |
| `MODIFIED_FILE` 筛选桶 | 407 | 0.011 | 按第 3、4 节条件处理 |

扩展名统计与上表重叠，不能相加：

| 扩展名 | 文件数 | GiB |
|---|---:|---:|
| `.apk` | 276 | 24.731 |
| `.smali` | 2,122,167 | 17.217 |
| `.zip` | 102 | 7.825 |
| `.bundle` | 4 | 1.009 |
| `.ipa` | 12 | 0.657 |

### 重点目录（按体积排序前 20）

以下为整个主题的总量，包含必须保留的最终包、审计/发布记录；不是可直接删除的目录清单。

| 路径 | 文件数 | GiB | 处理判断 |
|---|---:|---:|---|
| `docs/verification/artifacts/2026-09-08/branch-consolidation` | 123 | 8.44 | 历史分支与未提交工作恢复档案；异地归档并验证 RESTORE/manifest，禁止当缓存整删 |
| `docs/verification/artifacts/2026-09-08/wallet-compact` | 210,453 | 6.13 | 主题混合证据；只按文件角色拆分，不能整目录判冗余 |
| `docs/verification/artifacts/2026-09-10/mention-history` | 210,429 | 5.77 | 当日活动主题；先确认任务结束，保留发布/审计证据，暂缓删除 |
| `docs/verification/artifacts/2026-09-07/manual-tron-completion` | 158,119 | 4.99 | 主题混合证据；只按文件角色拆分，不能整目录判冗余 |
| `docs/verification/artifacts/2026-09-08/address-wallet-wechat` | 105,237 | 3.20 | 主题混合证据；只按文件角色拆分，不能整目录判冗余 |
| `docs/verification/artifacts/2026-09-10/chat-reliability-2084` | 114,644 | 3.15 | 当日活动主题；先确认任务结束，保留发布/审计证据，暂缓删除 |
| `docs/verification/artifacts/2026-09-08/ios-0353` | 116,369 | 3.08 | 主题混合证据；只按文件角色拆分，不能整目录判冗余 |
| `docs/verification/artifacts/2026-09-10/four-fixes-2083` | 112,238 | 2.86 | 当日活动主题；先确认任务结束，保留发布/审计证据，暂缓删除 |
| `docs/verification/artifacts/2026-09-08/wallet-independent-activation` | 60,200 | 2.17 | 主题混合证据；只按文件角色拆分，不能整目录判冗余 |
| `docs/verification/artifacts/2026-09-08/official-chat-update` | 103,885 | 2.11 | 主题混合证据；只按文件角色拆分，不能整目录判冗余 |
| `docs/verification/artifacts/2026-09-09/mobile-parity` | 103,979 | 1.81 | 主题混合证据；只按文件角色拆分，不能整目录判冗余 |
| `docs/verification/artifacts/2026-09-07/sender-order-debug` | 52,624 | 1.79 | 主题混合证据；只按文件角色拆分，不能整目录判冗余 |
| `docs/verification/artifacts/2026-09-06/wallet-application-mi6` | 155,757 | 1.76 | 主题混合证据；只按文件角色拆分，不能整目录判冗余 |
| `docs/verification/artifacts/2026-09-08/image-layout-mi6` | 52,622 | 1.66 | 主题混合证据；只按文件角色拆分，不能整目录判冗余 |
| `docs/verification/artifacts/2026-09-08/wallet-binding-guidance` | 52,611 | 1.66 | 主题混合证据；只按文件角色拆分，不能整目录判冗余 |
| `docs/verification/artifacts/2026-09-07/wallet-debug-mi6` | 52,610 | 1.66 | 主题混合证据；只按文件角色拆分，不能整目录判冗余 |
| `docs/verification/artifacts/2026-09-07/official-address-fix` | 52,636 | 1.53 | 主题混合证据；只按文件角色拆分，不能整目录判冗余 |
| `docs/verification/artifacts/2026-09-08/wallet-mfa-reauth` | 52,613 | 1.53 | 主题混合证据；只按文件角色拆分，不能整目录判冗余 |
| `docs/verification/artifacts/2026-09-06/mi6-production-debug` | 52,608 | 1.53 | 主题混合证据；只按文件角色拆分，不能整目录判冗余 |
| `docs/verification/plain36` | 7,177 | 1.24 | 主题混合证据；只按文件角色拆分，不能整目录判冗余 |

### D12：最大的分支备份不能直接删

`docs/verification/artifacts/2026-09-08/branch-consolidation/` 为 **8.44 GiB / 123 文件**。`docs/verification/2026-09-08-branch-consolidation.md` 说明它保存已经删除的 10 个 worktree 的源码/证据、未提交修改、manifest 和 RESTORE.md；部分 wallet/auth WIP 并未批准集成。Git bundle 只保留 Git 对象，不能替代未提交/忽略文件的 ZIP。建议整体迁至受控备份库、核验哈希并实际试恢复后，再申请清理本地副本。不能因为名字为 pre/post/final 就推断旧 bundle 可删。

其中最大的 5 个 ZIP：

| 文件（相对于上述目录） | GiB |
|---|---:|
| `codex__chat-room-flow-fixes/checkout-and-evidence.zip` | 1.64 |
| `codex__review3-mi6/checkout-and-evidence.zip` | 1.55 |
| `codex__release-settings-arm64/checkout-and-evidence.zip` | 1.04 |
| `codex__mi6-feedback/checkout-and-evidence.zip` | 0.94 |
| `codex__cache-entry-optimization/checkout-and-evidence.zip` | 0.85 |

### 抽样反证：相同大小并不等于重复

额外抽查两组同大小 source.apk，SHA256 均不同，因此没有将任何一组批准为同字节副本：

| 对照文件 | 大小（每份） | 哈希结论 |
|---|---:|---|
| `2026-09-10/mention-history/apk/source.apk` 与 `parallel-apk/source.apk` | 146,817,247 字节 | 不同 |
| `2026-09-10/four-fixes-2083/delivery/source.apk` 与 `delivery-final/source.apk` | 148,519,123 字节 | 不同 |

上表路径前缀为 `docs/verification/artifacts/`；第二个文件路径沿用同主题。哈希不同不证明业务功能不同，但足以排除“同字节复制品”。未进行全部二进制哈希扫描。

**建议先审批文档治理和已结束主题的生成缓存清理；分支备份、原始诊断包、正式发布/回滚包及金融审计证据只做受控归档。**
