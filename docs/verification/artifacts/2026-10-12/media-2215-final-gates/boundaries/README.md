# Android2215 最终候选：Python/mobile 边界与 verify 环境门禁

最终候选 **`e432414276af7d6fe73afd9afc8b41d7bfd4b5b7`**（tree `dd8f6068d952626e481328047819cb34950a648a`）的原始完整命令已自然完成：**401 PASS / 1 SKIP / 0 FAIL，exit 0**。

工作树 `C:/Users/Administrator/.codex/worktrees/media-send-startup-2214/StarChat`；branch `codex/media-2215-final-gates`。本子任务不修改产品源码、依赖或原测试，未构建、ADB、服务器操作、git stage/commit/切分支；root 提供的 iOS CI 元数据修正未触发 iOS 构建或发布。

## 最终结果及适用复用

| 门禁 | 候选及实际结果 | 证据 |
| --- | --- | --- |
| `py -3.12 -m pytest -q -p no:cacheprovider tests/mobile tests/test_android_delta.py` | **e432：401 PASS / 1 SKIP / 0 FAIL，exit 0** | `python-mobile-final.log`、`python-mobile-final-receipt.json` |
| `pwsh.exe -NoProfile -File tests/repository/Test-RepositoryPolicy.ps1` | **e432：PASS，exit 0，新执行** | `repository-policy-final.log`、`repository-policy-final-receipt.json` |
| Deployment policy | ec9 上实际 verify 前缀 PASS；e432 闭包未改，复用 | `verify.log`、`verify-receipt.json`、`final-gate-reuse.json` |
| TemplateTools | ec9 上实际 verify 前缀 PASS；e432 闭包未改，复用 | 同上 |
| UI drift | ec9 上实际 exit 0，34 components / 535 screens；e432 闭包未改，复用 | `ui-contract.log`、`ui-contract-receipt.json`、`final-gate-reuse.json` |
| 完整 `scripts/verify.ps1` | ec9 实际 **exit 1**：缺 `.env` 阻断；e432 对应脚本和环境不变，保留阻断，**不称全仓通过** | `preflight.json`、`verify.log`、`verify-receipt.json`、`final-gate-reuse.json` |

独立 `git diff ec9…e432` 严格只有 `.github/workflows/ios-enterprise-package.yml` 六处 0.4.45+2214→0.4.46+2215 的版本参数/文件名修正；见 `final-candidate-metadata.diff`。旧670个边界输入在候选更换后零SHA差异；最终672个相关输入（补入 CI workflow 和 delta 实现）前后也零SHA差异，tracked status 为空。部署、模板和 UI closure 均不读取变化的 CI 元数据，准确复用原因与旧receipt SHA见 `final-gate-reuse.json`。

`verify.ps1` 在每条 policy/template 子命令后立即执行 `Assert-LastExitCode`，成功才进入下一阶段；其原始 PASS/后续阶段日志证明旧三个子命令均退出0，不将整脚本exit1误写成通过。没有创建/导入 `.env` 或生产秘密。

## 原始失败与关闭过程（全部保留）

1. **ec9 首轮完整命令 exit 1：396 PASS / 5 FAIL / 1 SKIP。** 原始 `python-mobile.log`、receipt 未覆盖；旧报告/汇总/hash快照为 `README-initial-ec9.md`、`summary-initial-ec9.json`、`artifact-hashes-initial-ec9.json`。
2. **四项 delta 是环境 setup 失败。** 新工作树缺少原测试硬编码的 `docs/verification/artifacts/2026-10-09/mobile-responsive-maintenance/delta` 父目录，全部在断言之前 WinError3。parent 明确授权后，校验绝对路径位于本树内、`.gitignore:101` 覆盖，显式 mkdir 原父目录；随后原 delta 四项 **4 PASS / exit 0**。没有 monkeypatch、跳断言、改实现或测试排除。见 `delta-environment-prepare.json`、`delta-inputs-before.json`、`delta-fixture-recheck.log`、receipt。
3. **剩余一项是真实版本契约失败。** ec9 的 pubspec 为0.4.46+2215，iOS unsigned workflow仍0.4.45+2214，`test_ios_handoff_release_version.py:11`正确失败。root 在 e432 仅修正六处 CI 版本参数/文件名；本子任务在最终候选重新执行完整原始测试集，401/1/0、exit0，关闭该失败。旧输入及 Git blob见 `failure-inputs.json`，新输入见 final-before/after清单。
4. 这不是用四项补验掩盖原整套失败：最终全套另外自然执行并取得exit0。两轮 `-q` 均仅给出一个 skip 计数，无详细原因，本报告不猜测原因。

## 身份、工具与阶段时间

移动源码冻结清单 SHA256：`bf8524c0da20b4a1700fb43c07bd3a5344c08e9c2f2a5e33a3bbf1f8cdee9050`。最终输入清单SHA：`557ded9369b08e4c6851bcf3989c6186faca0eadabb9c10c084111bdba9decb5`。最终 Python 日志SHA：`879b40f1a7b00a31f4c86337d8b25ccd991313ab5e3fe6d0213da4e230a7985e`。

工具为 PowerShell7.6.5、Python3.12.10、pytest8.4.2、Windows10 build19045、Node22.22.2、Docker29.8.2/Compose5.5.1；详见原预检和 Python 导入路径证据。

| 阶段 | UTC起止 | 墙钟与结果 |
| --- | --- | --- |
| ec9 首轮 Python/mobile | 12:42:53.9948456Z–12:44:24.8314554Z | 90.833960s；396/5/1，exit1 |
| ec9 verify（并行） | 12:42:53.9947933Z–12:42:58.7103148Z | 4.712863s；前三阶段PASS，缺env exit1 |
| ec9 UI（并行） | 12:42:54.0498822Z–12:42:54.8504500Z | 0.798572s；exit0 |
| delta 原命令补验 | 12:47:29.0836163Z–12:47:30.5491583Z | 1.390080s；4PASS exit0 |
| **e432 最终完整 Python/mobile** | **12:53:44.3038885Z–12:54:21.4610854Z** | **37.155727s；401/0/1，exit0** |
| e432 repository policy（并行） | 12:53:44.3038840Z–12:53:44.7101943Z | 0.404839s；exit0 |

全部发生于2026-10-12。最终 pytest 自报36.36s，receipt 包含进程起止墙钟37.155727s；不混作同一度量。每条receipt包含命令、真实退出码、UTC、源码/日志/锁输入身份。并行门禁时长不可直接累加成总墙钟。

## 未执行与下一步

原 verify 在render前阻断，后续 infra/Getui/Matrix Bot/Business API+Worker 全量、AST/Alembic/OpenAPI未执行；移动媒体子任务不扩大到无关业务全量。Deployment policy已实际执行两条Compose config检查。Flutter/analyze由parallel parent执行；原生编译、APK固定重建签名、模拟器/真机安装与真实图片/视频发送、服务器部署仍属parent/root，不由此静态/Python门禁替代。

下一步由parent/root把 e432 的Python证据与未变移动输入下的Flutter/analyze闭包、最终模拟器媒体验收汇总。本子任务移动Python验收已通过；整仓verify缺env和实际设备端到端验收不在此冒称关闭。
