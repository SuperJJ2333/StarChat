# 验证记录：第三轮批次 1（NEEDS_REVIEW 处置/分页时间线/隔离 Synapse 联测）+ 后台扩展

任务：[2026-09-22-zcode-next-step](../workflow/prompts/2026-09-22-zcode-next-step.md)。
前置：第二轮复审回填（34/34 文件 SHA256 核对一致）。
授权边界：本地实现 + 隔离测试；无真实短信、无真实资金、无生产数据、无生产部署。

## 一、缺口与验收对照表（批次 1 第 1 项）

| 复审指出的缺口 | 本轮交付 | 验收 |
| --- | --- | --- |
| 充值 NEEDS_REVIEW 查询/时间线/人工处置不明 | `GET /recharge/admin/review-queue`（占用中的不确定登记）、`GET /recharge/admin/requests/{id}/timeline`（案件+绑定审计时间线）、`POST /recharge/admin/requests/{id}/review`（retry=只读核实重新登记，幂等；release=服务端核证"调整被拒/缺失/已冲正"后释放） | 契约测试 4 项 + 面板 node 测试 |
| 转让 NEEDS_REVIEW 查询/处置 | `GET /groups/{room}/transfer-intents`（时间线；群主或管理员）、`POST /groups/admin/transfer-intents/{id}/review`（confirm_applied=权威状态显示新群主持唯一最高权→依据既成事实完成；fail_unapplied=旧群主仍持唯一最高权→确证未应用后失败化释放；其余 409） | 契约测试（权限/既成事实/未应用/非法动作） |
| 超时不得视为失败 | release/fail_unapplied 均以服务端权威证据为唯一判据，证据不足一律 409 | 测试断言 |
| 案件分页/历史/绑定状态 | `GET /recharge/admin/requests?cursor&limit&status`（稳定游标分页，含 binding_state）；面板历史区+下一页禁用逻辑 | 契约 + node 测试 |
| 目录停用可见与恢复 | 管理端 GET 含停用条目（复审已加）+ 面板 PUT 按 ID 恢复（本轮节点测试覆盖写路径） | node 测试 |
| 隔离真实 Synapse 转让 | 本地 Docker `starchat/synapse:v1.132.0-dedup.1` + 真实 `SynapseMatrixAdminGateway`：真实注册（镜像自带 register_new_matrix_user）、真实建房/邀请/加入、完整协调推进、**权威回读确认新群主唯一最高权、旧群主降权、注册表换主、ACL content 保持**；旧客户端直改权限→注册表不跟随、desync 观测 | `test_synapse_transfer_integration.py` 2 passed（无环境自动 skip） |
| 阿里云真实账户 | 无法完成（无凭据/无授权号码）；交付前置清单（见下） | 清单在案 |

## 二、阿里云真实通道前置清单（待用户提供后才能验收）

1. 阿里云账号开通「验证码短信」（dypnsapi 2017-05-25），创建 AccessKey（建议 RAM 子账号最小权限 `dypnsapi:*`）。
2. 已报备签名 `恒创联众` 与模板（模板须含 `##code##` 与 `${min}`？以控制台实际模板为准——代码使用 `{"code":"##code##","min":"5"}`）。
3. 提供测试手机号与发送授权（费用/频控确认）。
4. 生产配置：`BUSINESS_SMS_PROVIDER=aliyun_dypns`、`BUSINESS_SMS_ALIYUN_ACCESS_KEY_ID/SECRET`、`SIGN_NAME`、`TEMPLATE_CODE`、`REGION`（默认 ap-southeast-1）、`CODE_VALID_MINUTES=5`、`OTP_HASH_SECRET`；容器镜像需含 SDK（requirements.lock 已同步，Docker 构建与 pip check 由复审轮验证）。
5. 真实验收点：SendSmsVerifyCode 下发到真实号码、CheckSmsVerifyCode 对错码/过期码/VerifyResult≠PASS 的行为、`OutId` 回传与 challenge 对应、多 worker 配额、五次尝试、跨用途隔离。**替身 PASS 不替代以上任何一项。**

## 三、本轮改动清单

- 服务端：`app/modules/recharge/service.py`（review_queue/admin_requests/case_timeline/retry/release）、`app/api/recharge.py`（4+1 端点）、`app/modules/groups/transfer_coordination.py`（intents_timeline/review_intent）、`app/api/groups.py`（2 端点）。
- 前端：`src/admin-recharge-panel.js`（待核对队列/案件历史分页/含绑定状态列）、`src/admin-api.js`（5 个方法）。
- 测试：`tests/business_api/recharge/test_review_flow_api.py`（4）、`tests/business_api/groups/test_group_transfer_coordination.py`（+1 契约）、`tests/business_api/groups/test_synapse_transfer_integration.py`（2，Docker）、`frontend/tests/admin-recharge-panel.test.mjs`（+2）。
- OpenAPI 重导出（`--check` PASS）。

## 四、门禁证据

| 检查 | 结果 |
| --- | --- |
| `pytest tests/business_api/{groups,recharge,identity,pricing,fx}` | **451 passed / 10 skipped** |
| frontend `npm test` | **232 passed / 0 failed** |
| 后端全量 `pytest tests/business_api tests/business_worker -q` | **2411 passed / 58 skipped, exit 0**（一次通过；日志 `artifacts/2026-09-22/full-backend.log`、exit 码 `full-backend-exit.txt`） |
| `scripts/verify.ps1` | 本轮按证据复用规则未在专项通过后立即重跑；待后端全量后执行并追记（复审轮 2404 passed 的 PASS 不代表本轮新增代码，故必须重跑） |

## 五、明确未完成 / 未验证（不可省略）

- Flutter 批次 3：**未动工**（契约入口见上轮证据第五节）。
- 真实短信、真实 Matrix 生产实例、生产数据迁移演练（0081/0080 需在生产备份副本演练）、500 人压测、双端真机：均未执行。
- 转让协调端点与 worker 仍默认关闭；启用需上述隔离联测扩展至生产同版本网关演练 + 用户批准。
- NEEDS_REVIEW 的"重新发起"（释放后另建调整）为既有绑定流程组合，未新增一键化操作——属有意保守：重新发起必须由人工以新调整走完整审批链。


## 六、最终门禁追记（2026-09-22）

- 后端全量一次通过：**2411 passed / 58 skipped, exit 0**（25 分 09 秒；含本轮 NEEDS_REVIEW 处置/分页/时间线/转让复核契约与隔离 Synapse 联测全部新增用例）。
- **`scripts/verify.ps1` 退出码 0（`Verification: PASS`）**：`verify-exit.txt`=`exit=0`、完整日志 `verify-full.log`。分段实测：Infra 143、Getui 28、Matrix Bot 9、business_api+worker **2411 passed / 58 skipped**、mobile 84、Business API import / AST / Alembic 离线迁移（含 0081）/ OpenAPI / Compose 全 PASS。脚本任何门禁失败即非零退出，本次 exit=0 即全部门禁通过。
- 58 个 skip 项继续按原条件视为未验证（PostgreSQL 显式开关/环境依赖）；生产部署前须对生产备份副本演练 0079–0081 数据迁移与恢复。
