# 2190 基线整合与模拟器 Debug 交付 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 从真实 Android 2190 冻结源码实施本任务补丁，完成受影响验证，并把固定签名 Debug 候选保留数据安装到 emulator-5556。

**执行状态（2026-09-29）：** 2190 基线整合及 2191 固定签名构建、保留数据安装和启动已完成；聚焦测试通过，整库 `verify.ps1` 仍在运行。下方复选框是原实施清单，已完成事项及未验收边界以[任务台账](../../workflow/tasks/2026-09-28-chat-search-jank-diagnostics.md)为准。有界 crash/ANR 缓冲区中本包匹配数为 0；模拟器尚未完成账号内的搜索及输入法操作，10 万条完整搜索与 Redmi K80 性能也未实测。

**Architecture:** 先按正式包冻结清单将准确源文件叠加到独立分支并提交基线，再执行三个互不覆盖的实施计划。所有代码通过后冻结新的 Debug 输入、源码构建、Apktool 常规重建、固定签名与独立验包，最后覆盖安装模拟器。

**Tech Stack:** PowerShell 7、Python 3 UTF-8、Flutter/Dart、Android SDK 36、Apktool 2.12.1、Git、ADB。

---

## 文件所有权与依赖

本计划由 /root 独占：docs/workflow/tasks/2026-09-28-chat-search-jank-diagnostics.md、新任务验证目录、2190 基线导入脚本、新 Debug 构建脚本及 apps/mobile_flutter/pubspec.yaml。其他计划分别独占搜索、Matrix/房间和诊断代码。此计划的基线 Task 1 必须在任何产品 RED 测试前完成；Debug Task 3 必须在三计划的代码与受影响验证结束后执行。

### Task 1: 复原正式 Android 2190 源码

**Files:**
- Read: docs/verification/artifacts/2026-09-28/client-diagnostic-fidelity/android-release/frozen-mobile-input-2190-r3.json
- Read only source: C:/Users/Administrator/.codex/worktrees/diagnostic-fidelity/StarChat/apps/mobile_flutter
- Create: docs/verification/artifacts/2026-09-28/chat-search-jank/restore-2190.py
- Modify by verified copy: apps/mobile_flutter 下冻结清单所列 1793 个源输入

- [ ] **Step 1: 写入验证后复制脚本。** 脚本先逐一验证源文件 SHA，全部通过才复制；每个输出路径必须解析在当前工作树的 apps/mobile_flutter 内，拒绝绝对路径和 ..。脚本内容：

```python
from __future__ import annotations
import argparse
import hashlib
import json
import shutil
from pathlib import Path

ROOT = Path(r'C:/Users/Administrator/.codex/worktrees/chat-search-jank/StarChat')
SOURCE = Path(r'C:/Users/Administrator/.codex/worktrees/diagnostic-fidelity/StarChat')
MANIFEST = Path(r'D:/pythonProject/outsource/StarChat/docs/verification/artifacts/2026-09-28/client-diagnostic-fidelity/android-release/frozen-mobile-input-2190-r3.json')

def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def target_path(name: str) -> Path:
    rel = Path(name)
    if rel.is_absolute() or '..' in rel.parts or rel.parts[:2] != ('apps', 'mobile_flutter'):
        raise ValueError(f'unsafe manifest path: {name}')
    path = (ROOT / rel).resolve()
    if not path.is_relative_to((ROOT / 'apps/mobile_flutter').resolve()):
        raise ValueError(f'outside mobile source: {name}')
    return path

def summary(root: Path, rows: list[dict[str, str]]) -> dict[str, int]:
    out = {'matched': 0, 'mismatched': 0, 'absent': 0}
    for row in rows:
        path = root / row['path']
        key = 'absent' if not path.is_file() else (
            'matched' if digest(path) == row['sha256'] else 'mismatched')
        out[key] += 1
    return out

def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check-source', action='store_true')
    mode.add_argument('--check-target', action='store_true')
    mode.add_argument('--copy', action='store_true')
    args = parser.parse_args()
    rows = json.loads(MANIFEST.read_text(encoding='utf-8'))['files']
    for row in rows:
        target_path(row['path'])
    if args.check_target:
        result = summary(ROOT, rows)
        print(json.dumps(result, sort_keys=True))
        return 0 if result == {'matched': len(rows), 'mismatched': 0, 'absent': 0} else 1
    source = summary(SOURCE, rows)
    print(json.dumps({'source': source}, sort_keys=True))
    if source != {'matched': len(rows), 'mismatched': 0, 'absent': 0}:
        return 2
    if args.copy:
        for row in rows:
            destination = target_path(row['path'])
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SOURCE / row['path'], destination)
        result = summary(ROOT, rows)
        print(json.dumps({'target': result}, sort_keys=True))
        return 0 if result == {'matched': len(rows), 'mismatched': 0, 'absent': 0} else 3
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
```

- [ ] **Step 2: 保存失败基线。** 在本工作树运行下列命令并保存 JSON 结果；预期与 2190 清单为 1559 个相同、158 个不同、76 个缺失，证明远端主线不足以作为正式包测试对象。该失败是刻意的基线 RED，不能算产品测试失败。

```powershell
$env:PYTHONUTF8='1'; $env:PYTHONIOENCODING='utf-8'
python docs/verification/artifacts/2026-09-28/chat-search-jank/restore-2190.py --check-target
```

- [ ] **Step 3: 执行源验证与复制。** 对清单之外的现有文件，预先只读确认本分支 apps/mobile_flutter 的 tracked extra 为 0；如结果不同先停下审查。同一 PowerShell 会话设置 UTF-8 控制台/管道和 Python UTF-8 环境，然后顺序运行三个模式。预期源和目标最终各 1793/1793 哈希匹配；保存标准输出、真实退出码与脚本 SHA 在本任务验证目录。脚本不删除已有文件。

```powershell
python docs/verification/artifacts/2026-09-28/chat-search-jank/restore-2190.py --check-source
python docs/verification/artifacts/2026-09-28/chat-search-jank/restore-2190.py --copy
python docs/verification/artifacts/2026-09-28/chat-search-jank/restore-2190.py --check-target
```

- [ ] **Step 4: 只提交经清单验证的产品基线。** 检查 git status 与清单差异；基线是此前已发布源码整合，不含本任务修复。运行 git diff --check，仅暂存 apps/mobile_flutter，提交 “chore: import frozen Android 2190 source”。`docs/verification/artifacts/` 按仓库规则被忽略，验证脚本与 JSON 证据留在该目录，不强制暂存。提交后再次做 1793/1793 检查，记录 commit 和 manifest SHA。

### Task 2: 受影响门禁与平台兼容

**Files:**
- Modify: docs/workflow/tasks/2026-09-28-chat-search-jank-diagnostics.md
- Create: docs/verification/artifacts/2026-09-28/chat-search-jank/gates/ 下逐项日志

- [ ] **Step 1: 预检。** 记录源码提交、Flutter/Dart/Java/Python 版本、pubspec.lock SHA、磁盘空间、ADB online、已安装包名/versionCode、是否有 .env。当前观测 emulator-5556 是 Android 9、仅 com.liuhetong.mobile.debug 0.4.18/2187；不得把型号字符串 2509FPN0BC 当实体 Redmi K80。

隔离工作树初始缺少 `.dart_tool/package_config.json`；在首个 `--no-pub` Flutter RED 测试前只运行一次 `C:/src/flutter/bin/flutter.bat pub get`，随后核对 `pubspec.lock` 的 2190 冻结 SHA 和 `git status -- apps/mobile_flutter`，不可让依赖解析改变冻结基线。Flutter 不在默认 PATH 中，以下命令使用绝对路径。

```powershell
git rev-parse HEAD
Get-FileHash -Algorithm SHA256 -LiteralPath apps/mobile_flutter/pubspec.lock
& 'C:/src/flutter/bin/flutter.bat' --version
java -version
adb devices -l
adb -s emulator-5556 shell dumpsys package com.liuhetong.mobile.debug
```

- [ ] **Step 2: 验证三项计划的 RED/GREEN 和差异。** 对每项保存命令、退出码、相关输入 SHA、通过/失败/跳过数；先规格符合性审查，再质量/安全审查。所有受影响 Flutter tests、Matrix SDK tests、Python 接收端/triage tests、Flutter analyze 和契约/隐私门禁必须通过。运行 pwsh -NoProfile -File scripts/verify.ps1 前先检查 .env 与依赖；若缺失，保存失败及相同输入的可复用独立门禁，不把最后一个 PASS 冒充全量 exit 0。

- [ ] **Step 3: 兼容性断言。** Debug 客户端对当前生产旧诊断接收端只发送旧协议字段；仅在服务端明确声明新版本能力后上传带 UTC 的新增操作。离线 spool 中旧批次保留原版本归属，不因新客户端安装被改标。模拟器登录/聊天若无测试账号，只验证安装、启动、无崩溃及可见页面，不造账号或发送真实消息。

### Task 3: 固定身份 Debug 构建与安装

**Files:**
- Modify: apps/mobile_flutter/pubspec.yaml
- Create: docs/verification/artifacts/2026-09-28/chat-search-jank/android-debug/build-android-debug.ps1
- Create: docs/verification/artifacts/2026-09-28/chat-search-jank/android-debug/ 下冻结清单、APK 和验包证据

- [ ] **Step 1: 冻结版本。** 当次读取正式 Android 设置、其他任务已占用的 versionCode 与模拟器安装版本。若 2191 尚未占用，将 pubspec 版本从 0.4.21+2190 更新为 0.4.22+2191；若已占用，选择当时最大值加 1，写入任务记录并同步构建脚本断言。不要仅改 APK 文件名。

```yaml
version: 0.4.22+2191
```

- [ ] **Step 2: 创建当次构建脚本并做 PreflightOnly。** 以 docs/verification/artifacts/2026-09-27/network-failure-diagnostics/android-debug/build-android-2187-x64.ps1 的已验流程为基础，更新工作树、冻结 manifest、版本断言、独立验证路径和 APK 名称；保留原版的 Apktool 2.12.1、build-tools 36、固定签名证书 75b31c66…1fff、HTTPS Business/Matrix/Getui dart-define、x64 Debug ABI、DEX/资源/清单比较和签名校验。历史构建使用 E 盘 junction；本任务的 Flutter 测试已在工作树创建 `build/`，为避免更动在用目录，保留该普通目录，改由 `R:` 临时映射缩短源码路径，并在 E 盘任务验证目录保存最终产物。脚本断言 `build/` 为当前工作树目录，且 `R:` 映射只指向本工作树。复制后逐行复核差异；签名前确认 p12 与 DPAPI 文件均存在，绝不生成新密钥。脚本 -PreflightOnly 只能检查，不能构建/安装。

- [ ] **Step 3: 按当前源冻结输入并构建一次。** 先运行相关测试及 flutter analyze；从实际源码生成新冻结 manifest 和 SHA，再运行脚本构建。脚本执行 Flutter source APK → Apktool d/b → zipalign -P 16 -f 4 → 固定身份签名 → apksigner、zipalign、aapt、重解包代码、资产、ABI 与版本逐项验证。每步失败即停，保留原始日志；最终 APK SHA、证书、版本及实际源 commit 进入 artifact.json。一次构建内复用同一个 RunId，不能在装机时另选“最新”目录。

```powershell
$RunId = 'run-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$ScriptRoot = 'C:\Users\Administrator\.codex\worktrees\chat-search-jank\StarChat\docs\verification\artifacts\2026-09-28\chat-search-jank\android-debug'
$RunRoot = 'E:\StarChatVerification\docs\verification\artifacts\2026-09-28\chat-search-jank\android-debug'
$RunDir = Join-Path $RunRoot $RunId
$Manifest = Join-Path $ScriptRoot 'frozen-mobile-input.json'
$ManifestSha = (Get-FileHash -LiteralPath $Manifest -Algorithm SHA256).Hash.ToLowerInvariant()
pwsh -NoProfile -File (Join-Path $ScriptRoot 'build-android-debug.ps1') -RunId $RunId -ShortDrive R -ExpectedMobileManifestSha256 $ManifestSha
if ($LASTEXITCODE -ne 0) { throw 'Android Debug build failed' }
```

- [ ] **Step 4: 保留数据覆盖安装。** 安装前再记录模拟器 serial、包/versionCode 和数据路径，不卸载、不清数据、不使用降级或签名绕过。仅在最终 APK 的包名为 com.liuhetong.mobile.debug、构建号高于已装 2187、证书与已验证稳定身份匹配时执行：

```powershell
$FinalApk = Join-Path $RunDir 'final.apk'
if (-not (Test-Path -LiteralPath $FinalApk -PathType Leaf)) { throw 'Verified final APK missing' }
adb -s emulator-5556 install -r --no-streaming $FinalApk
if ($LASTEXITCODE -ne 0) { throw 'ADB install failed; preserve existing app data' }
adb -s emulator-5556 shell dumpsys package com.liuhetong.mobile.debug
```

预期 install 返回 Success，dumpsys 读回目标 versionCode；再启动主 Activity，取有界且脱敏的 crash/ANR 计数，检查搜索/输入法可进入。无账号时不声称真实搜索与弱网业务路径已由模拟器验收。

- [ ] **Step 5: 记录交付。** 更新任务台账和验证报告：源码/测试/构建/签名/装机分别列状态，提供 APK 绝对路径、SHA、模拟器实际版本与待 Redmi K80 实测项；不把 Debug 安装等同正式发布。若服务端候选尚未按独立发布流程上线，明确新的按畅聊号服务器查询尚不可用。
