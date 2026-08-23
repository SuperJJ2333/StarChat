# ChatFlow / 点钻迁移：Agent Figma 导出与三方注册表证据

- 导出账本：`design-demo/artifacts/figma-state.json`
- 三方注册表：`packages/ui-contracts/changliao-component-registry.json`
- 导出状态：Figma 导出账本记录 150 variables、85 components、326 registered screens；组件 Token 绑定与 screen registry exact-match 均为 `passed/true`。
- 品牌映射：`畅聊 ChatFlow`、`畅聊`、`畅聊号`、`点钻`、`畅聊点钻红包`；内部资产代码保持 `CAIBI`。
- 排除项：OpenAPI 标题、健康检查 service、Docker 默认服务名、TOTP issuer。

## 回滚副本验证

- ORIGINAL_FILE：`docs/verification/artifacts/2026-08-23/ORIGINAL_FILE.json`
- MODIFIED_FILE：`docs/verification/artifacts/2026-08-23/MODIFIED_FILE.json`
- DIFF_FILE：`docs/verification/artifacts/2026-08-23/DIFF_FILE.diff`
- ROLLBACK：`docs/verification/artifacts/2026-08-23/ROLLBACK.sh`
- 原始 SHA-256：`C7A77852F13DAFD3C45DCC6BE89CA02A86DE662341CF1ADD1C285430414EFA4E`
- 修改 SHA-256：`A3BA33B3368B4A6FA83682F74B8E733541C3083BD88ED6D2AF5E5D06F91EB4E9`

| 阶段 | 精确命令 | 输入 | 文字结果 | 退出码 |
| --- | --- | --- | --- | --- |
| BASELINE | `py -3.12 -c "import json, pathlib; registry=json.loads(pathlib.Path(r'docs/verification/artifacts/2026-08-23/ORIGINAL_FILE.json').read_text(encoding='utf-8-sig')); assert 'brand' not in registry; print('baseline registry: no brand field')"` | ORIGINAL_FILE | `baseline registry: no brand field` | 0 |
| MODIFIED | `py -3.12 -c "import json, pathlib; registry=json.loads(pathlib.Path(r'docs/verification/artifacts/2026-08-23/MODIFIED_FILE.json').read_text(encoding='utf-8-sig')); assert registry['brand']['productDisplayName']=='畅聊 ChatFlow'; assert registry['brand']['caibiDisplayName']=='点钻'; print('modified registry: brand mapping verified')"` | MODIFIED_FILE | `modified registry: brand mapping verified` | 0 |
| ROLLBACK | `py -3.12 docs/verification/artifacts/2026-08-23/ROLLBACK.sh` | rollback-target copy | `rollback registry restored: no brand field` | 0 |

回滚后的副本恢复为无 `brand` 字段的基线注册表；`MODIFIED_FILE.json` 保持为已修改状态。

## 全量验证

| 命令 | 结果 | 退出码 |
| --- | --- | --- |
| `C:\src\flutter\bin\flutter.bat analyze`（`apps/mobile_flutter`） | `No issues found!` | 0 |
| `C:\src\flutter\bin\flutter.bat test`（`apps/mobile_flutter`） | `238` tests passed | 0 |
| `py -3.12 scripts/verify_ui_contract.py` | `UI contract drift: PASS (10 components, 326 screens)` | 0 |
| `cd design-demo; npm test` | `14` passed | 0 |
| `py -3.12 -m pytest tests/business_api/test_branding.py tests/mobile -q` | `21 passed` | 0 |
| `$env:PYTHONPATH = (Resolve-Path services/business-worker/app).Path; py -3.12 -m pytest tests/business_worker/test_email_sender.py -q` | `6 passed` | 0 |
| `pwsh -NoProfile -File scripts/verify.ps1` | `Verification: PASS`; Business API/Worker `174 passed, 1 skipped`; Flutter boundary `20 passed`; OpenAPI and migrations PASS | 0 |
