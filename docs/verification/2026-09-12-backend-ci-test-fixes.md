# 2026-09-12 backend CI 13 项测试失败修复

## 范围

android-ci `backend` job 的 `tests/business_api` 失败（CI 13 项 / 本地复现 14 项）。不发布服务、不迁移 DB、不改金融写路径行为。

## 根因（全部源于 2026-09-11 的 6947bb7c / 1f957444 引入后未同步的下游）

1. **OpenAPI 契约无效 JSON（4 项 + drift check）**：1f957444 手工编辑契约文件，在 invite 历史 description 字符串里留下真实换行（JSON 非法控制字符，line 15917），并手工补 `maximum/minimum` 约束；源码 `identity.py` 的 limit/offset 是普通 int 参数，FastAPI 生成不出这些约束。
2. **管理端 detail 500（2 项）**：6947bb7c 给 quote 快照新增 funding_asset 等 5 个多币种字段；`manual_wallet_admin.ManualPayoutSnapshot` 是 `extra='forbid'`，`model_validate` 又位于 `read()` 的 try 块之外 → ValidationError 直接 500，测试取 `body['candidate_txid']` 时 KeyError。
3. **创建提现 403（5 项）**：6947bb7c 使 `manual_payouts.request` 强制 `payment_authorization`（缺失 → PAYMENT_PIN_REQUIRED 403）；test_manual_idempotency_recovery 与 test_admin_password_payouts 的 HTTP 流程未同步 PIN 阶段。
4. **吊销 token 仍 200（2 项）**：test_manual_wallet_admin_api 用无 WHERE 的 `select()` 首行做吊销，6947bb7c 给 alice（支付 PIN fixture）新增 Device/Family 行后，首行不再指向 owner；`decode_access_token` 本身有吊销检查（tokens.py L307/L311），是测试打错了行。
5. **legacy_handover 导入失败（1 项）**：测试内 `from tasks...`，而 CI PYTHONPATH 只含 business-api 与仓库根；`tasks` 包在 services/business-worker/app 下。

## 修改

- `services/business-api/app/api/identity.py`：invite 历史 limit/offset 改为 `Annotated[int, Query(ge=1, le=50)]` / `ge=0`（恢复契约承诺的约束；越界由静默 clamp 变为 422，与既有契约一致）；保留 clamp 作为纵深防御。
- `packages/api-contracts/openapi/liuhetong-v1.yaml`：`scripts/export_openapi.py` 重新生成（合法 JSON、描述与源码 docstring 一致、约束回到 schema）。
- `services/business-api/app/api/manual_wallet_admin.py`：`ManualPayoutSnapshot` 增加 5 个可选多币种字段（Literal/pattern 约束，历史订单缺省 None）。
- `tests/business_api/wallet/test_manual_wallet_admin_api.py`：吊销按 token claims 精确命中 actor 自己的 family/device 行。
- `tests/business_api/wallet/test_manual_idempotency_recovery.py`、`test_admin_password_payouts.py`：补 `/payment-pin/authorize` → `payment_authorization` 阶段（对齐 test_manual_wallet_api 的既有通过流程）。
- `tests/business_api/wallet/test_legacy_handover.py`：导入前把 `services/business-worker/app` 加入 sys.path（`app.*` 仍解析到 business-api，已核对 outbox_handover/alert_delivery 存在于 business-api、email_sender 在 worker）。

## 验证（2026-09-12，Windows / Python 3.12 / .venv）

- 修复前全量复现：`pytest tests/business_api -q` → 14 failed / 1719 passed / 52 skipped（CI 13 项 + 本地同样存在的 legacy_handover）。
- 修复后聚焦：test_openapi_contract + 4 个钱包文件 → **60 passed**。
- `python scripts/export_openapi.py --check` → PASS。
- 修复后全量回归：`pytest tests/business_api -q` → **1733 passed / 52 skipped / 0 failed**（13m07s）。

## 备注

- Node 20 deprecation 警告来自 Actions runner 默认版本，非失败项，不处理。
- 本地复现需 `.venv`（全局 site-packages 有无关 `scripts` 包遮蔽工作区命名空间包）+ `pip install -e services/business-api`（coincurve 等）。
