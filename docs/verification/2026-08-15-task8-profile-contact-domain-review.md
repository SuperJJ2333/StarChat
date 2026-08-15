# Task 8：Matrix 资料同步与好友投影 Domain Review

日期：2026-08-15
范围：`identity.profile.changed` Worker、Matrix 头像/昵称同步、Business 好友与申请投影。

## 结论

**通过。** 本任务维持 ADR 0004 的身份边界：Business API 是个人资料、好友关系和展示字段的权威来源；Matrix 仅接收通信域所需的昵称与头像副本。未引入认证旁路、财务状态写入或 E2EE 密钥/明文处理。

## 核查项

| 领域约束 | 证据与结论 |
|---|---|
| Business 资料权威 | 好友列表、好友申请和用户搜索统一通过 `ProfileService` 的公开读取接口投影，不从 Matrix 反向读取或回写 Business 资料。 |
| Outbox 边界 | Task 7 的资料事务继续原子写入 `identity.profile.changed`；Task 8 Worker 仅消费该事件。同步失败由 Outbox 重试，不撤销已提交的 Business 昵称或头像。 |
| 重放幂等 | `matrix_profile_synced_at` 固化已同步的 Business profile 版本；同一事件重放不会重复上传头像或更新 Matrix。头像上传成功但资料设置失败时保存 MXC 映射，重试不重复上传。 |
| 头像隐私 | Worker 从共享私有卷只读获取头像；Business API 不向 Worker传递公开对象 URL，对外好友投影仍只返回 300 秒签名 URL。Matrix 仅收到验证完成的 JPEG/PNG/WebP 内容及 MXC URI。 |
| 身份映射 | Worker 仅为 `ACTIVE` 且已有稳定 `matrix_user_id` 的用户同步，事件中的 `aggregate_id` 与 `user_id` 必须一致。 |
| 好友展示语义 | `GET /friends` 固定返回 `user_id`、`username`、`nickname`、`remark`、`avatar_url`、`matrix_user_id`、`moments_permission`、`tags`；备注、昵称、用户名的显示优先级可由客户端使用同一响应实现，UUID 不再作为 subtitle 数据源。 |
| 好友申请隐私 | 申请列表返回申请人的用户名、昵称和短签名头像 URL，不返回 `requester_id`。 |
| E2EE 不降级 | 新增调用仅涉及 Synapse media upload 与用户 profile metadata；未访问房间密钥、恢复密钥、消息正文、明文附件或通话媒体。 |
| 财务隔离 | 未读取或写入 ledger、red packet、wallet 表；未由 Matrix 回调派生任何资产状态。 |

## 验证证据

```text
py -3.12 -m pytest tests/business_worker/test_identity_tasks.py tests/business_api/friendship/test_friendship_api.py -q
8 passed

py -3.12 -m pytest tests/business_api/identity tests/business_api/friendship tests/business_worker -q
86 passed

pwsh.exe -NoProfile -File scripts/verify.ps1
Business API and Worker: 138 passed, 1 skipped
Matrix Bot: 8 passed
Flutter boundary: 4 passed
Migrations, OpenAPI drift and Docker Compose render: PASS
```

重点断言包括：事件顺序为私有头像读取 → Matrix media upload → MXC profile 设置；事件连续重放只产生一次上传和一次资料更新；Matrix 更新失败后 Business 昵称与头像引用保持不变；好友投影字段完整且申请响应不暴露 `requester_id`。
