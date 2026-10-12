# Android2215 最终候选：Python/mobile 边界及 verify 环境门禁

- 候选：`ec9a38a882096d80ff4a6ed1e31078dae95ee641`；tree `6b977c6f0332494354ab317ebfb0139e9fef210e`。
- 工作树：`C:/Users/Administrator/.codex/worktrees/media-send-startup-2214/StarChat`；branch `codex/media-2215-final-gates`。
- 本子任务只写本目录证据；按 parent 明确授权，额外创建原 delta 测试硬编码要求的 ignored 历史临时父目录。未修改产品源码、依赖或原测试；未操作构建、ADB、设备及服务器，未 git add/commit/切分支。
- 工具：PowerShell 7.6.5、Python 3.12.10、pytest 8.4.2、Windows 10 build19045、Node v22.22.2、Docker 29.8.2、Compose v5.5.1。详细预检及 Python 导入路径见 `preflight.json`、`python-import-paths.json`。

## 实际结果

| 门禁 | 实际退出码 | 结果 | 原始证据 |
| --- | --- | --- | --- |
| `py -3.12 -m pytest -q -p no:cacheprovider tests/mobile tests/test_android_delta.py` | 1 | 396 PASS / 5 FAIL / 1 SKIP，pytest 87.09s | `python-mobile.log`、`python-mobile-receipt.json` |
| `pwsh.exe -NoProfile -File scripts/verify.ps1` | 1 | repository、deployment、template 三阶段 PASS；render 阶段缺 `.env` 真实阻断 | `verify.log`、`verify-receipt.json` |
| `py -3.12 scripts/verify_ui_contract.py` | 0 | 34 components / 535 screens PASS | `ui-contract.log`、`ui-contract-receipt.json` |
| 原始 `py -3.12 -m pytest -q -p no:cacheprovider tests/test_android_delta.py` 补验 | 0 | 4 PASS；只准备原测试已要求的父目录 | `delta-fixture-recheck.log`、`delta-fixture-recheck-receipt.json` |

`verify.ps1` 内部每个 policy/template 子命令之后立即运行 `Assert-LastExitCode`，成功才推进；原始日志的下一阶段起始行和 PASS 行证明前三个子命令退出码为0。因此不重复执行同一输入的三条命令。整脚本退出1，不能写成整仓门禁通过。

## 首轮失败及补验

1. **版本契约真实失败，尚未在本子任务关闭。** pubspec 为 `0.4.46+2215`，但 `.github/workflows/ios-enterprise-package.yml` 的源码构建参数、IPA 命名、验证器版本和 artifact 名称仍为 `0.4.45+2214`（96/139/142/147/150/183行）。`tests/mobile/test_ios_handoff_release_version.py` 第11行正确报告不一致。相关五个输入 SHA256/Git blob 见 `failure-inputs.json`。已报 parent/root；未改 iOS 业务或降低断言。若修正后候选发生变化，必须独立绑定新候选补验。
2. **四项 delta 首轮为环境 setup 错误。** 原测试 `setUp` 直接向 `docs/verification/artifacts/2026-10-09/mobile-responsive-maintenance/delta` 创建 `TemporaryDirectory`，该 ignored 父目录在此新工作树不存在，四项均在断言之前 WinError3。parent 明确授权后，验证绝对路径仍在本工作树内，显式 mkdir 原父目录并确认 `.gitignore:101` 覆盖；随后不改测试、不 monkeypatch、不跳断言、不换实现，原 delta 命令 4/4 PASS。原失败日志保留不覆盖。环境准备和原源码输入见 `delta-environment-prepare.json`、`delta-inputs-before.json`。
3. **`.env` 环境阻断。** 预检为 false，实际 `verify.ps1` 在 `scripts/init_matrix.ps1:19` 抛 `Missing .env` 并停止在任何配置写入之前。没有创建/导入 `.env`、生产秘密或绕过检查。UI drift 作为后续适用移动门禁单独执行通过。
4. 首轮 `-q` 仅给出一个 skip 计数，没有打印具体原因；本报告不猜测该 skip 原因。

补验4项通过不能覆盖首轮整套退出1。当前覆盖中仍有1个未关闭版本契约失败；不能把历史401 PASS/1 SKIP或其它候选结果当成本轮全绿。

## 输入身份与阶段时间

- 移动源码冻结清单 SHA256：`bf8524c0da20b4a1700fb43c07bd3a5344c08e9c2f2a5e33a3bbf1f8cdee9050`。
- `boundary-inputs-before.json` / `boundary-inputs-after.json` 对比670个相关文件，零SHA漂移；每条 receipt 的前后候选均为 ec9a38a8，tracked status 为空。
- 配置预检：2026-10-12T12:42:31.6117682Z。
- Python/mobile：12:42:53.9948456Z–12:44:24.8314554Z，90.833960s 墙钟。
- verify：12:42:53.9947933Z–12:42:58.7103148Z，4.712863s；与 Python 并行。
- UI drift：12:42:54.0498822Z–12:42:54.8504500Z，0.798572s；与 Python 并行。
- delta 父目录准备：12:47:08.3472416Z–12:47:08.4805266Z。
- delta 原命令补验：12:47:29.0836163Z–12:47:30.5491583Z，1.390080s。

命令、真实退出码、UTC起止、日志SHA及输入SHA均在相应 receipt。多门禁为并行，耗时不能直接相加当总墙钟。

## 未执行与下一步

`verify.ps1` 后续 infra/Getui/Matrix Bot/Business API+Worker 全量、AST/Alembic/OpenAPI 等阶段未执行；此次移动媒体修复不扩展到无关业务全量。独立 deployment policy 已真实执行其两条 Compose config 检查。Flutter/analyze 由 parallel parent owner 执行，本子任务不重复。原生编译、APK重建/签名、模拟器/真机安装与真实图片/视频发送、服务器部署均由 parent/root 负责，本子任务未声称通过。

下一步：parent/root 处理 iOS unsigned handoff 版本契约，再按最终候选补验受影响门禁；保留首轮与本次环境补验的分次身份。根任务还须完成真实模拟器媒体层验收，单元/静态边界不替代设备收发结论。
