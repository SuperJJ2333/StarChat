# 钱包生产部署就绪验证（资金关闭）

> 后续状态：用户授权继续后已完成生产应用切换，详见 [正式上线记录](2026-09-06-wallet-production-deployment.md)。本文保留部署前验证时的历史状态。

本轮目标是消除应用部署阻塞并完成可回退的发布准备；不是无托管商条件下开放真实 USDT。本轮没有切换生产 API/Worker、没有升级线上数据库，也没有向第三方发送消息。

## 已完成工作

1. 修复历史0025重复添加0014所属 `moments_preferences.cover_url`：使用兼容添加，降级不删除既有列或值。真实 PostgreSQL 测试覆盖空库全链、0014/0024保留数据、旧缺列、重复head、离线SQL及生产实际0038分支合并到0041。之前记录的这一迁移阻塞已解决。
2. API/Worker 共用精确版本 `requirements.lock`，固定 Python 基础镜像摘要，禁用构建隔离的浮动依赖；Docker构建上下文排除环境、密钥、Git及验证工件。`pip check` 在镜像构建中执行。
3. 新增只读启动前检查，验证生产配置、兑换关闭、没有资金provider、数据库连通、唯一0041版本及21张相关表的显式列集合。错误只输出固定代码。`RELEASE_READY_FUNDS_DISABLED` 不是余额审计、外部监控或真实托管就绪证明。
4. 准备发布/回退两个Compose覆盖：API与Worker同时选用指定镜像、先迁移再启动，补齐Worker生产配置缺失的推荐码密钥映射；保留原始五层生产配置、端口、挂载和其它服务。回退旧API通过显式uvicorn绕过不识别0041的旧Alembic启动命令。

## 实际环境证据

- 只读确认生产基线为 `0038_app_settings_text`，API与Worker此前版本不同。SSH默认代理程序不可用；显式 `-F none` 成功直连，未修改用户SSH配置。
- 本地隔离的生产配置演练：[rehearsal.json](artifacts/2026-09-06/wallet-production-readiness/rehearsal.json)。旧表结构被拒绝、0038升级/重放成功、API就绪、钱包资金关闭、真实HTTP兑换请求503、Worker可启动且明确监控无provider、重启成功、合成备份恢复再升级成功。
- 服务器隔离演练：[server-rehearsal-log.txt](artifacts/2026-09-06/wallet-production-readiness/server-rehearsal-log.txt)。从生产复制**仅表结构**到独立内部网络PostgreSQL，没有复制用户行；候选版升级/启动/重启成功；旧生产API和Worker在扩展结构上恢复启动成功；线上容器ID保持不变。候选镜像及源清单保留在服务器发布目录供正式发布。
- [server-config-check.json](artifacts/2026-09-06/wallet-production-readiness/server-config-check.json)：生产实际六层Compose合并成功；候选API/Worker在真实环境下只读检查配置和数据库，均正确拒绝尚未升级的旧head。没有打印环境或密钥。
- [server-backup-verification.json](artifacts/2026-09-06/wallet-production-readiness/server-backup-verification.json)：完整业务数据库备份与环境/容器配置仅保存在服务器0700目录、0600文件。数据库在 `--network none` 的独立PostgreSQL中恢复成功，基线0038；未启动应用处理恢复的数据。验证容器及其匿名卷已删除；真实备份未下载到工作区。旧镜像已保留为独立回退标签。

## 测试与审阅

新增测试先验证失败：全链升级最初6项因DuplicateColumn等失败；预检脚本/发布覆盖/回退覆盖缺失分别出现预期失败；构建锁缺失setuptools与固定安装步骤也先失败。最终冻结后生产迁移/预检/发布/回退/构建专项45项全部通过。全仓库验证601通过、30跳过，迁移、OpenAPI与Compose检查均PASS。跳过项来自未启用的独立PostgreSQL测试环境和SQLite不支持的跨进程/串行化用例；本次迁移专项另外启用REPORTING_PG_URL完成真实PostgreSQL验证，不能把30项跳过当作通过。完整日志见工件目录。

全仓库有3条现有依赖弃用提示：两处Starlette TestClient使用httpx的提示，以及Getui Bridge的Pydantic class Config提示；不影响本轮执行结果，未屏蔽。后续依赖升级需处理这些兼容性迁移。

[领域与安全审阅记录](artifacts/2026-09-06/wallet-production-readiness/reviews.md)：领域审阅PASS后，Quality/Security审阅PASS，仅限 `FUNDS_DISABLED` 部署范围。两者均为只读审阅，没有代替实际运行结果。Ruff检查通过；最终源清单和镜像验证与交付工件对齐。

演练工具自身的两项问题已处理：Docker Desktop随机发布端口在重启后改变，重新读取端口后验证通过；PostgreSQL初始化阶段Unix socket过早就绪，备份恢复及服务器演练检查均改用TCP就绪后成功。Windows Docker曾显示已无进程的一次性容器仍running，清理明确属于本轮的验证容器后继续；服务器独立Linux演练不依赖此状态。没有将这些工具问题冒充为生产应用故障。

## 发布条件与限制

正式部署操作步骤、服务器工件ID、备份和回退命令见 [生产发布手册](../runbooks/wallet-production-release.md)。发布前必须重新确认基线/镜像并刷新备份；普通代码回退保留新增表、订单和金融证据，不覆盖上线后的新分录。历史报告中的0025阻塞是当时状态，以本次完整PG链验证为准。

真实MPC/链上证明、外部告警送达、操作MFA、独立存证、跨故障域RPO=0及iOS真机分发不在本次就绪结论中。无provider时的监控不可用和资金暂停是明确运行状态，不能通过关闭告警或绕过预检消除。
