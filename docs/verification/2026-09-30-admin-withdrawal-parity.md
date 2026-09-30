# 管理员提现一致性实施与发布验收

日期：2026-09-30，Asia/Hong_Kong。用户已批准设计、ADR、计划及直接执行。工作树：`codex/wallet-alert-only-payout-void`。未执行生产退款、结案或资金启停。

## 发布身份

- 原 API：`sha256:62614149b7e469fdbcd0bd5a1465c921dce61d0acaaf1aecce19878ef6207f62`。
- 候选/已上线 API：`sha256:40ad213c785a75406366a6ad3f440b3b9adbbd704de4c54f44f8017386cd7f44`。
- worker 保持：`sha256:3efd5924f343d7e81056e014519a43f411b617747903e2f8e26b6281e00c43ea`；容器 ID 不变。
- 安全回退：`sha256:1e1bcee3d4d7a74eac82b924311c3aad061e9dd3a5d096d7f5fc1c7b0bf8b6c3`，关闭提现写入，保留当前 0094 schema 与既有审计；不恢复客服写权限。
- 生产切换开始：2026-09-30 19:41:00 +08:00。部署目录：`/opt/starchat/releases/admin-withdrawal-parity-20260930/`。仅 API 7 个源文件和 5 个静态文件，无迁移、无 worker 构建。

## 验收

| ID | 结果 | 证据 |
| --- | --- | --- |
| W1 | 充值/提现共用 recharge/dialog 样式，桌面/390px 实际 Chromium 渲染通过 | desktop.png、withdrawal.png、narrow.png |
| W2 | 官方负责人且 SUPER_ADMIN 才能读写提现；客服角色和旧 token 拒绝；充值共享授权保持 | policy RED/GREEN；最终镜像 18 项实际测试 |
| W3 | 点钻/汇率六位 HALF_UP；五个基准按钮与实时预览；刷新保留草稿；付款后禁止改价 | 前端 80 项；旧入口调价 RED/GREEN |
| W4 | 未开始可取消并冲回原兑换；已开始只停止复核；未广播撤销复用最新扫描+独立证明+声明 | 后端取消测试，最终镜像 PG 12 项 |
| W5 | 取消/付款互斥；取消/准备可合法串行；一次冲回、迟到到账结算、独立证明/版本/幂等与中断重试 | PostgreSQL、新 Outbox 与重试 RED/GREEN |
| W6 | 协议门禁、备份恢复、最小部署、两端哈希、健康、未授权拒绝、其他容器不变 | deployed.json、workstation-public.json、服务器私有协议/恢复证据 |

## 测试与评审

- 本地后端聚焦 **172 passed**，30.68 秒，追加历史余额场景 1 项通过；前端聚焦 **80 passed**。
- 最终不可变镜像：管理员策略/取消 **18 passed**；真实迁移 PostgreSQL **12 passed**，55.79 秒；随后追加历史调整释放资金已花掉的原子拒绝 **1 passed**，5.76 秒（输入为同一最终镜像）。候选源码均从镜像实际 `/opt/business-api/app` 导入，测试工具只挂载至只读 `/probe`，不进入生产镜像。
- API/安全回退/worker 的真实 ASGI 续期协议门禁均通过；切换也通过统一 business_release_guard。
- 新鲜生产备份在独立 PG16 容器成功恢复，schema `0094_support_finance_order_recovery`；USDT 非平衡事务计数为 0，演练容器已删除。私有备份未下载。
- UI contract **32 components / 433 screens PASS**；API AST parse PASS；diff whitespace check PASS。
- Domain 设计 PASS，Security 设计 PASS。实施 Domain 三项 P2 与 Security 两项 P2 已逐项重现红并修复到绿：旧版本精确重试、停止 Outbox、过期可取消入口、链上选择中断恢复、刷新草稿。无未处理阻断项；未另行重复同输入评审。

## 完整门禁的真实限制

- `scripts/verify.ps1` 仓库策略、部署策略和模板测试通过，在 render smoke 因隔离工作树没有 `.env` 停止，退出 1。未复制生产秘密或伪造完整门禁通过。
- 全前端 **356/357**：唯一失败是已有首页 iOS 测试期望 2173，而首页已有版本 2189。首页文件不在本次发布清单。该未通过项与提现候选无关联。
- 本地后端有 FastAPI/Starlette 对 httpx 的弃用提醒；最终镜像基础依赖未变更。候选工具首次缺 `py.py`、PG 测试根目录推导错误均修复后重跑；不是功能通过证据。
- OpenAPI 保存最终镜像生成的完整合同，保留已发布的额外 16 条路由。旧工作树全应用源上下文落后于生产，不能用其全局 export --check 冒充候选合同验证；本次最终镜像导出是权威证据。

## 实施裁决与权限边界

- 复用现行 0094 汇率准备：准备只存报价，不移动冻结资金；开始付款才应用最终应付。取消冲回实际冻结及原兑换，不按客户端预览写账本。
- 冻结释放与原兑换冲回是两笔平衡 USDT 事务；按 scope 验证各一次，不能把两笔合理事务误报为双退款。
- 汇率准备可在取消前合法串行提交，最终取消仍一次退款；付款与取消必须互斥。
- 领取历史和旧客服付款归属不改写；所有新管理员资金动作均有独立密码/TOTP与钱包 grant 验证。精确幂等重试仍验证当前身份/证明/token。
- 选择凭证中断恢复使用完整订单/版本/txid/log_index 意图及精确已提交定位凭证；不得借旧版本恢复修改成另一笔链上交易。
- 此前生产资金事故、历史订单和资金暂停状态不会被本次发布自动处理。管理员真实浏览器的实际订单操作尚未代做。

## 后续操作与回退

管理员 Ctrl+F5 后进入充值/提现请求。取消未开始订单需独立验证；结果未知订单需通过最新链上预检并勾选未签名、未广播声明后独立确认撤销。扫描不可用/疑似匹配/已有付款证据时保留冻结。已广播仅停止处理并持续复核。

必要时先核对 API/静态无后续漂移，再运行服务器 `python3 /opt/starchat/releases/admin-withdrawal-parity-20260930/server_switch.py rollback`；该脚本使用同一协议门禁和安全提现写入围栏，恢复静态，不 downgrade 0094 或修改账本。不能回退至原客服可付款镜像。

证据目录：[本任务 artifacts](artifacts/2026-09-30/admin-withdrawal-parity/)。服务器私有日志、备份和配置保留 0700/0600。工作站使用既有 SOCKS，未关闭他人隧道。
