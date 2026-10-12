# Android2215 builder：DPAPI 序列化换行增量

本增量修复 e9878d5dd7d7f4681feb900b1af5817df7b43e68 的确定性独审阻断：此前复制的是 538f90f6 中旧 signer，未包含 root 后续已修的序列化 DPAPI `.Trim()`。旧脚本在 CRLF 终止的合成 DPAPI 文本上抛 `System.FormatException`，历史 11 项准备门禁没有覆盖这条路径，不能据此宣称 signer 通过。

## 最小修复及输入身份

- 仅替换 `tools/sign-existing-identity.ps1` 为 root `3edbf0031e540a1ee067f9e686475b3227f5ac5b:docs/verification/artifacts/2026-10-12/media-debug-packaging-tools/sign-existing-identity.ps1` 的精确 Git 字节。
- 旧 SHA256：`1baf91b7c2e3ed7951c3c3f9fab623d9cf6355d3dc3a2eade29f58508183b7d0`；新 SHA256：`eef1c12edf36c800166447911e6cc08f56ebb53224d7b24a40670ea07d1413a4`。
- 可执行差异只有第 95 行：对 `Get-Content -Raw` 取得的 DPAPI 序列化文本调用 `.Trim()` 后再 `ConvertTo-SecureString`；解密后的密码不修剪。签名身份、调用参数、清理和证书校验不变。
- `candidate-tool-identities.json`、`source-provenance.json` 更新该工具身份；`candidate-input-identities.json` 从 staged Git blobs 重新生成，保持 Git 字节域。builder 本体、闭包工具、400 source 基线、旧 APK/receipt/57 smali/full manifest 输入均未变。

## 本次实际执行

`verify_signer_dpapi_regression.py` 精确载入已有测试 `bf6fa639fa3a02fab067b2708d27832c8299992f:docs/verification/artifacts/2026-10-12/media-debug-packaging-tools/test_sign_wrapper.py`，SHA256 `7cb68309598f3e92c215600e0c5efbe161d001b095485ab3f84c7506267d3f3d`，只运行 `WrapperTests.test_dpapi_line_terminator_preserves_password_and_decrypts`。它给测试设置独立 synthetic USERPROFILE，用 PowerShell AST 只提取实际脚本的 DPAPI 赋值语句；不执行 signer 主体，不读取真实 P12/DPAPI，不调用 apksigner。

| 精确输入 | 结果 | 证据 |
|---|---|---|
| 旧 copied signer 1baf91b7 | 1 FAIL，exit 1；实际 `System.FormatException` | `signer-dpapi-red.log`、`signer-dpapi-red-receipt.json` |
| 新 copied signer eef1c12e，同一测试 | 1 PASS，exit 0；CRLF 外壳正确解密，合成密码两端空格保留；无 signer 调用/输出 APK | `signer-dpapi-green.log`、`signer-dpapi-green-receipt.json` |
| 新工具身份下原 builder 4 项有界 preflight 替身 | 4 PASS / 2.798s，exit 0 | `signer-preflight-green.log` |

原始日志/receipt 保留；不重复未变的旧 7 项锁屏闭包或全量签名门禁。4 项 preflight 仍将实际 build 尾部替换为不可执行的 throw，并使用无效假 key/DPAPI 和 Python 替身；此通过不是正式构建、真签名或实际设备证明。既有独审报告中的 19+1 项 DPAPI/sign-wrapper 证据按上述精确测试/工具身份引用，不声称本次重跑了全部。

## 交付边界

仅新增/修改本独立候选准备目录；已冻结 `android2215-release`、root/mobile/version 和产品源码未改。本轮没有构建、签名、设备、网络或生产操作。下一步是非作者对该精确增量做 SPEC/domain → QUALITY/security 审查；通过后由 root 取得真实最终输入并按原 builder 及三个实际门禁执行。当前没有新候选 APK 身份或 gate 批准。
