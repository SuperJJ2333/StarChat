# 畅聊钱包客户端、API、迁移与权限联合核对

日期：2026-09-09。执行分支：`codex/redmi-polish-20260909`，起点 `4912d062`（Android 0.3.68/2072）。主目录 `codex/wallet-safety-mi6` 的未提交代码仅作为读取来源，没有清理、覆盖或提交到其分支。

## 结论与交付范围

正式客户端分支现已整合开发版手动 USDT 钱包；后端与 Worker 源码补齐到已部署共同基线，迁移保留钱包、管理员会话、朋友圈图片评论及最新私聊预约分支。已生成对应 OpenAPI，并补齐手动钱包 Compose 配置及发布预检。

本轮只进行代码整合、只读生产核对、自动化测试和合成 PostgreSQL 演练。没有替换生产容器、运行生产迁移、修改线上资金开关、绑定真实钱包或执行真实充值/提现/兑换。Android 线上仍为 **0.3.68/2072**；没有发布新 APK，也没有推送 iOS。客户端真机发布验收应在下一次 Android 构建、重建、稳定签名及安装后完成，不能将本轮自动化测试称为真机资金验收。

## 生产基线与来源

初始只读观察：API `11c2c59b95e1`、Worker `27bc9f7de31f`、schema `0056_merge_moment_comments`。核对期间另一次线上发布更新了六个私聊预约相关源文件；本轮随后按运行容器快照及逐文件 SHA-256 纳入，避免未来发布覆盖它们。

最终只读核对：

- API：`sha256:c76be88a7e5bef06405bdf6d8b7b5f65109ae8660f9da114ea5b378a2d5dee2f`。
- Worker：`sha256:27bc9f7de31fb5803e3180e6817e319cced9fc1462379146ddf1dc4350925eb5`。
- 数据库唯一头：`0057_merge_direct_room`，合并0056与私聊预约分支；0056继续合并管理员会话与朋友圈图片评论。
- 两个服务一致：`manual_tron / address_only / operation_password / manual_liquidity`；充值、提现申请、提现执行、兑换均显式开启，legacy `real_funds=false`，handover preparation=false。

229个线上 API Python 文件逐项核对，最终源码只有 `app/integrations/tron/reader.py` 是本轮另行审阅的修复，其余与最终生产快照一致。Worker 来自已运行镜像的源码快照。源码归档只收集代码和依赖描述，不包含环境文件、数据库、私钥或资金凭据。

315条导入来源及最终规范化 SHA-256 见 [来源清单](2026-09-09-wallet-integration-manifest.json)。原始摘要、非秘密快照和完整日志位于 `artifacts/2026-09-09/wallet-integration/`，已按目录规则归档并从 Git 排除。

## 实际修复

1. 导入钱包页面、地址登记/绑定、充值意向恢复、提现报价/申请/未知结果恢复、MFA 和对应测试。公共 `BusinessApiClient` 采用手工合并，保留正式客户端已有登录退出修复。
2. 钱包请求固定原业务账号作用域。兑换确认弹窗等待、偏好读取及401刷新期间切换账号，不会以新账号提交原请求；相同账号刷新沿用原请求和幂等键。
3. 发布预检固定最终迁移头0057，检查私聊预约等必要表列；补充三个独立资金开关检查，不能再将开启的充值/提现报告为“资金已关闭”。该工具仅用于关闭资金的部署准备，不是当前线上开启资金状态的就绪判定。
4. `TronReader` 最多执行三次完整快照尝试，保留原始请求窗口及总截止时间，不混用旧事件和新余额。同高度区块hash/时间冲突、区块/时间回退直接拒绝；重试仍不稳定时保持不可用证据状态。未更改账务公式、资金状态机、最终性或认证政策；尚未部署。
5. `docker-compose.wallet-manual.yml` 让九项策略显式必填且两个服务一致；观察数据和已有交接文件只读挂载，禁止自动创建缺失路径，不覆盖既有镜像、启动命令或媒体挂载。
6. 同步旧测试中的迁移头与已部署私聊规范房间规则；补齐独立测试模型注册，避免依赖其他测试的导入顺序。

## 验证证据

| 验证 | 结果与日志 |
| --- | --- |
| Flutter 完整测试 | 1542通过，`flutter-all.log` |
| 最后补充的兑换刷新及账号隔离 | 6通过，`conversion-refresh.log` |
| Flutter analyze | No issues found，`flutter-analyze.log` |
| API/Worker 完整回归（0056整合后） | 1433通过、34跳过，`backend-green.log` |
| 最终0057生产增量与路由/权限/预检/TRON | 208通过，`final-integration-green.log` |
| 仓库与部署政策、最终基础设施测试 | 政策通过；60通过，`final-policy.log` |
| 移动端边界与后续仓库检查 | 66通过；UI契约17组件/330页面、AST、OpenAPI、Compose、离线迁移通过，`repository-remaining.log` |
| PostgreSQL最终迁移及管理员并发会话 | 12通过、无跳过，`pg-final.log` |
| PostgreSQL0057备份恢复 | 恢复后schema和合成账本一致，CAIBI/USDT各自平衡，恢复前后共16次修改/删除均被拒绝，`pg-restore-final.log` |

`scripts/verify.ps1` 首轮实际运行，在旧迁移断言和缺少TRON重试处报告10项失败。已修正后重跑完整API/Worker阶段，并分别执行该脚本后续阶段；不将首轮日志改写为全程通过。最新生产六文件增量另行跑差异回归及PostgreSQL。

首次局部Python命令受机器上主目录的editable安装影响，出现OpenAPI及预检结构不符。最终重测显式设置当前工作树的 `PYTHONPATH=services/business-api;services/business-worker/app;.`，并打印确认实际 `app.__file__`。本报告以完整脚本和明确指定工作树的最终日志为准。

保留红/绿证据：兑换账号切换2项预期失败后修复；独立资金预检3项预期失败后修复；Compose配置10项预期失败后修复。TRON九项初始失败已由完整后端及最终差异回归覆盖。

34个跳过项依赖另行配置的外部/专用数据库环境，不能算作已验收；本轮对最终迁移、管理员会话和账本不可修改/恢复另有独立PostgreSQL证据。既有Starlette/httpx、Alembic配置及Getui Pydantic弃用提示未屏蔽，未在本轮扩大升级依赖范围。依赖有新版本的提示不代表本轮升级过依赖。

## 审阅与收尾

先由独立规格/领域审阅，再由质量/安全审阅。兑换作用域缺陷和资金预检缺陷修复后复审关闭；TRON、最终0057合并图及Compose增量亦无剩余已识别阻断。审阅结论基于源码，测试证据由主任务实际执行，不冒称审阅者独立跑过测试。

SSH测试转发已关闭；五个本轮专属的合成测试容器在核实身份后清理，未清理旧任务或生产容器；只读代码归档和日志保留。临时验证环境链接已移除，未将环境文件、数据库或钱包凭据纳入Git。

后续发布与回退步骤见 [联合发布手册](../runbooks/wallet-client-server-release.md)。下一次正式Android包必须来自此共同基线，并按既有APK重建和签名流程发布；后端新镜像与TRON修复需要独立记录上线结果。
