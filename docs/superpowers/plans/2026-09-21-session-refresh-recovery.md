# 移动刷新异常恢复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development or executing-plans task by task. User approved ADR-0080 and implementation; do not re-request scope permission.

**Goal:** 恢复结果未知的移动刷新，保留真实重放防护，并准确区分退出原因。
**Architecture:** 安全存储中的pending operation与服务端原子轮换结果对应；匹配操作只恢复原子令牌，不推进或延长子令牌；客户端串行读写与epoch防止旧结果复活。
**Tech Stack:** Python3.12/SQLAlchemy/FastAPI/Alembic，Flutter/Dart/secure storage，现有有界诊断。

协议与安全细节必须遵循 [ADR-0080](../../adr/0080-mobile-refresh-recovery.md)，规格见[设计](../specs/2026-09-21-session-refresh-recovery-design.md)。源码基线ca4a306a。

## Task 1 服务端协议和真实错误原因

所有权：services/business-api/app/modules/identity/{tokens,models,matrix_login,matrix_sessions}.py，app/api/identity.py，新迁移；tests/business_api/identity/test_refresh_recovery.py及相关身份/迁移测试；OpenAPI由主代理统一生成。

- [ ] 新建故障结果恢复测试，先运行RED：
```python
operation = base64.urlsafe_b64encode(bytes(range(32))).rstrip(b'=').decode()
first = tokens.rotate(old.refresh_token, operation_id=operation)
recovered = tokens.rotate(old.refresh_token, operation_id=operation)
assert recovered.refresh_token == first.refresh_token
assert tokens.decode_access_token(first.access_token)['family_id'] == old.family_id
```
- [ ] 扩展测试：异nonce/无nonce仍撤销；相同操作结果推进返回409不撤族；用户/设备/族失效优先；父过期子有效恢复；子到期拒绝；反复恢复不延长子expires；管理域隔离；旧StrictModel422无消费。
- [ ] 扩展模型两可空字段operation_hash及result_key_version；使用不与main待合入0072–0078重复的迁移编号，down_revision仍接本分支真实head（集成时处理分叉），不运行生产迁移。
- [ ] 新移动刷新请求模型验证canonical 43字符base64url nonce；旧logout/admin模型不扩展。rotate新增可选operation_id，未提供保持旧协议；首次消费在锁内保存hash、版本与replacement。
```python
digest = hmac.new(parent_token.encode('utf-8'),
    b'chatflow/mobile-refresh/result/v1\0' + decoded_nonce, hashlib.sha256).digest()
replacement_value = base64.urlsafe_b64encode(digest).rstrip(b'=').decode()
```
- [ ] 已消费重试先验证账户/族/设备，匹配hash且child未消费未过期时返回同一结果，不重新写expires。不同操作重用保持撤族；真实撤销原因不得被后来的重用覆盖。
- [ ] Matrix授权/绑定校验按实际账号限制、会话失效或替换返回，不将全部失败标SESSION_REPLACED。
- [ ] 跑`../../.venv/Scripts/python.exe -m pytest tests/business_api/identity -q`（PYTHONPATH=services/business-api）；保存RED/GREEN与真实exit；规格审查后质量安全审查。

## Task 2 客户端持久恢复与提示

所有权：apps/mobile_flutter/lib/core/{business_api_client,session_store,session_bootstrap_controller,business_auth_contracts}.dart，lib/session_gate.dart（生命周期若需要），相关core测试及新business_refresh_recovery_test.dart。保留所有既有身份/账号槽/Matrix保护。

- [ ] mock HTTP服务真实模拟“消费成功后抛网络异常”，下一次相同令牌+nonce返回同一结果，断言未收到invalidations；预期旧实现失败。安全存储fake分别在写入前/写入后抛错，覆盖重建store/api继续恢复。
- [ ] StoredBusinessSession添加可选pendingRefreshOperation；JSON继续兼容version1旧字段，用Random.secure生成32字节。单会话记录保存parent+nonce；不能分两个不原子key保存。
```dart
final operation = base64UrlEncode(List<int>.generate(
    32, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
```
- [ ] 将prewrite/readback/resultwrite放入当前_writeSession串行队列和epoch守卫。HTTP在锁外。write抛错重读，已提交则采用，旧pending则重试，读失败暂停；不清空/覆盖不确定记录。
- [ ] 同一次刷新请求body包含refresh_token与operation_id；响应丢失等每轮至多重试一次，之后5/15/30/60秒退避，回前台/联网有限触发。保留singleflight与现有总请求预算，不让业务并发各自产生nonce。
- [ ] 非结构化401、5xx、超时、格式异常、存储错误都不作权威退出；结构化终止码白名单才能清业务认证。superseded先读最新存储，只有仍停留在该旧pending才要求重认证。403账户受限保持既有账户处置。
- [ ] bootstrap/monitor依据真实终止码显示具体文案；SESSION_REPLACED默认“账号已重新登录，当前会话已结束，请重新登录”，不声称其他设备；临时异常无弹窗/退出。
- [ ] 明确退出/新登录与迟到回复测试；共享Flutter定向、analyze及最终全量。原生双端验证独立记录，未运行不冒充通过。

## Task 3 有界诊断及契约

主代理所有权：移动诊断allowlist/tests、服务端diagnostics schema allowlist/tests、OpenAPI生成、文档及统一门禁。不与Task1/2同时编辑上述所有权文件；API调用诊断接线由Task2代理完成。

- [ ] 为session_refresh事件测试白名单阶段、无凭证字段、上报失败不清会话；先RED后允许pending_write_failed/request_uncertain/result_write_failed/retry_recovered/terminal_invalidated/result_superseded。
- [ ] 事件固定stage/status/duration/retry/appbuild/lifecycle，拒绝原异常、账号、token/nonce/hash，沿用诊断限频队列，不await上传。
- [ ] 重新导出OpenAPI并检查仅本次增量，扩展迁移空库/既有库演练；不修改主目录其他新协议。

## Task 4 审查、验证与交付记录

- [ ] Domain/spec review通过后Quality/Security review；修复所有重要问题后复审。
- [ ] 前置工具环境、真实导入路径、锁hash、磁盘检查后跑scripts/verify.ps1；最终Flutter共享全量+analyze。不重复跑未变输入的等价门禁。
- [ ] 记录红绿、精确SHA、迁移heads、当前发布与候选差异，ADR/任务更新时间。无新移动包安装不能宣称手机已生效。
- [ ] 服务器正式发布需兼容迁移、真实基线、回退演练和门禁；移动端候选需整合未合入2145重启/权限修复再构建，避免覆盖。若本轮仅源码修复，明确待发布和真机项。
