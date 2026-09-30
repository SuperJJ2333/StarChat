# 确认未广播出款撤销：实现、演练与处置状态

日期：2026-09-30。事故 `75c01afc-29e7-416f-9609-581973994b14`；原订单 `3e728fe3-7343-4036-b9a0-646e56a46457`。用户确认从未签名、从未广播，批准受保护设计、ADR 和计划。[发布公共证据](2026-09-30-wallet-monitor-email-only.md)。

## 验收与生产事实

| ID | 场景 | 状态 |
| --- | --- | --- |
| V1 独立 VOIDED 终态 | UNKNOWN 无候选/事件，保留领取历史，不能再修改 | 实现、ORM/真实 PG guard 验证、已上线 |
| V2 授权与声明 | 官方拥有者、近期登录、独立操作验证、当前钱包授权、双声明、版本、幂等 | 实现、密码/TOTP 两模式与失效回滚测试通过 |
| V3 有界链上复核 | 新鲜覆盖、来源/检查点身份、无匹配或疑似转出、提交前复核 | 实现；14:04 +08 生产只读预检 READY，匹配/疑似转出均 0；不是独立未广播证明 |
| V4 精确原子补偿 | 最终 HOLD 释放、完整原兑换冲回，余额不足拒绝、一次审计/Outbox | 实现；目标原单生产形状在隔离恢复库演练通过 |
| V5 客户端兼容 | 服务/后台 VOIDED；用户查询 CANCELLED + terminal_status=VOIDED | API 和 Flutter 解析通过；旧客户端可读已有终态，新源码显示精确撤销；没有发布移动安装包 |
| V6 正式订单处置 | 真实管理员在后台再次声明、输入本次操作证明 | **待操作**：14:04 +08 原订单仍 UNKNOWN，version=1，无候选 |
| V7 事故结案与资金恢复 | 撤销后事故复核、独立受控恢复 | **待 V6**：事故 ACKNOWLEDGED/version=9/condition_active=true；三项原限制仍 true |

## 红绿与回归证据

- 新授权红测：有钱包 grant 但没有本次 proof，旧实现错误进入缺失订单查询返回 404；修复后返回 TOTP_REQUIRED/403。独立密码/验证码验证与钱包 grant 的最终 freshness 同时生效，凭据不入幂等元数据。
- 用户兼容红测：原返回 VOIDED，旧客户端无法解析；仅用户 GET 投影后 status=CANCELLED、terminal_status=VOIDED，服务原字典仍 VOIDED。后台、账本、历史和命令状态不被映射。
- `pytest test_manual_operations_api.py test_manual_payouts.py -q`：112 passed、1 既有 Starlette 弃用 warning，16.44 秒，exit 0。包括正确密码/TOTP、旧登录、最终 grant 撤销、最终授权失效后的实际账本回滚。
- 汇率补偿、观察证据、用户 API：31 passed、1 warning，8.40 秒，exit 0；新增用户 API 单独 20 passed。前端 49 定向、318 全量通过。
- 真实 PostgreSQL：`REPORTING_PG_URL` 仅指向 SSH loopback 转发的隔离容器，绝非生产 DB；迁移 2 passed，重复撤销/撤销与候选结算竞争 2 passed，最后并发 23.76 秒、无 warning。初次 fixture 因其他惰性注册模块的旧 Boolean DEFAULT 0 失败；限定初始相关 metadata 后复测通过。两项竞争通过共享锁、版本及 PG guard 得到唯一财务结果。
- Flutter 3.44.9/Dart 3.12.2；精确 pubspec.lock 经 `pub get --enforce-lockfile` 还原公共源依赖。钱包解析/历史 15 passed、5 文件 analyze 0。全量 4473 passed、9 skipped、7 failed（3m20s，exit 1）；七项仅为深 worktree 路径下缓存目录超过 Windows 路径限制。使用同一工作树的临时 `subst W:` 短路径复测三个相关文件 35 passed（6 秒），全部七项原失败覆盖并通过，临时盘符已解除。没有用此声称原全量命令 exit 0。日志 `flutter-full.log`、`flutter-path-delta.log`。批量 formatter 产生的无关变化已移除，最终只保留钱包变更。

## 隔离恢复与目标原单演练

实际生产 schema 为 0092，导入同版本迁移，新增唯一 head=0093（原计划调查时只知 0089–0091，按实时 head 修正）。服务器保存 33,248,577 字节 pg_dump 后恢复至独立 PG；迁移后 137 张业务表原值逐表摘要相同（订单排除新增 version 默认），10 个原订单 version=1。`restore-comparison.json` 留存。

最终镜像的财务源码在恢复库以**合成授权及链上证据**演练原订单；这只证明补偿，不代替正式管理员授权或真实未广播事实：

- 原转换 USDT=29.754820；当前最终应付/HOLD=10.000000；已调整退回的可用 USDT=19.754820。
- 释放 10 后，原转换完整冲回 29.754820，用户可用和 HOLD 的 USDT 均归 0，退回 200.00 CAIBI。
- 每个资产全部账本事务平衡；待处理计数减少一次；原 claimant/claimed_at 不变；审计和 Outbox 各一次；同键回放完全相同。
- 兼容回退镜像保留新状态读取及邮件政策，数据库仅向前扩展，禁止破坏性 downgrade。

## 当前可执行下一步

后台新端点已部署：`POST /api/v1/admin/wallet/manual/operations/payouts/{order_id}/void-unbroadcast`，预检 GET 后缀 `/preview`。用户须以官方钱包管理员重新登录，进入原订单，勾选未签名/未广播，填写原因代码和本次操作密码或验证码，确认撤销。浏览器控制工具两次超时，当前无法使用管理员会话；没有伪造会话或直接修改订单/余额。已通过用户输入工具请求该真实操作结果，密码/验证码不应发到聊天。

收到结果后先只读核对正式 VOIDED、冲正、审计、Outbox，再检查并处理事故，使用独立恢复命令。任务到目前只完成部署与演练，不能声称生产订单已撤销或资金已恢复。
