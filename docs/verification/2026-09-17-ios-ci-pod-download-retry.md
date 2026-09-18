# iOS CI 依赖下载 504：重试修复与 Pods 平台固定（提交 `c6b6f755`）

- 日期：2026-09-17（Asia/Hong_Kong）
- 背景：`.github/workflows/ios-compatibility.yml` 的 `production-compile` 作业在 **pod install 阶段**失败，
  尚未进入 Xcode 编译：

```
OpenSSL-Universal (3.6.2000)
https://github.com/krzyzanowskim/OpenSSL/releases/download/3.6.2000/OpenSSL.xcframework.zip
curl: (56) The requested URL returned error: 504
```

## 1. 根因判定

CocoaPods 从 **GitHub Release 资产**下载二进制 pod（`OpenSSL-Universal` 的 xcframework zip）。
GitHub 的 release 资产下载会间歇性返回 **504/502**。CocoaPods 自身对下载有重试，但**重试次数有限且窗口很短**，
因此一次 504 就可能让整个 `flutter build ios` 失败。

**这不是**应用代码、Xcode、Swift Package Manager 警告或 Podfile 警告引起的问题：
- `[Xcode]` 编译阶段根本没有开始；
- SPM 提示与 Podfile 平台提示是既有噪声，与本次失败无因果关系；
- 依赖 `flutter_openssl_crypto` / `sqlcipher_flutter_libs` **无需**改动——它们只是把该 pod 带进来。

## 2. 修复一：整段依赖安装 + 构建重试（工作流）

`.github/workflows/ios-compatibility.yml` → `Compile complete device app without signing`：

- 在**同一步骤、同一次依赖安装**上重试最多 3 次（覆盖 `pod install` + 构建），
  因此 504 后的重建会重新尝试下载，而不是在半个已解包的状态上继续；
- 保留 `set -o pipefail`（原命令即依赖它把 `flutter build` 的失败透出管道）；
- 退避 `attempt * 20`（20s / 40s）；
- **每次尝试各自一份日志** `production-compile-attempt-<n>.log`；
- 成功后 `exit 0`，三次皆失败则打印 `All iOS build attempts failed` 并 `exit 1`；
- 既有 `Preserve full production compilation evidence`（`if: always()`）继续上传整个
  `$RUNNER_TEMP/production-compile/`，因此失败尝试的日志同样可下载诊断。

提交内容与本轮设计**逐字一致**（已用 `git show HEAD:…` 复核）。

## 3. 修复二：显式声明 Pods 平台

**重要事实（与本轮指令的前提不同）**：仓库此前**没有** `ios/Podfile`，且它**不在** `.gitignore` 中。
Podfile 是由 `flutter build ios` 从 Flutter SDK 模板生成的：

- `flutter_tools/lib/src/macos/cocoapods.dart`：`if (podfile.existsSync()) { …; return; }` → **只有缺失时才生成**；
- 模板 `packages/flutter_tools/templates/cocoapods/Podfile-ios` 里平台行是**注释掉的**：
  `# platform :ios, '13.0'` → 这正是 `Automatically assigning platform iOS with version 16.0` 警告的来源。

因此“在已有 Podfile 里加一行”无法执行；正确做法是**提交一份 Podfile**，使平台声明真正生效。
新增 `apps/mobile_flutter/ios/Podfile`：

```ruby
platform :ios, '16.0'
```

- 取值为 **16.0**，与 `Runner.xcodeproj/project.pbxproj` 的 `IPHONEOS_DEPLOYMENT_TARGET = 16.0`（3 处，全部一致）相同；
- 已确认 `flutter_ios_podfile_setup`（`podhelper.rb`）**不会**给 Runner target 强加版本
  （只在 <13 时删除 `IPHONEOS_DEPLOYMENT_TARGET` 使其继承），因此显式 16.0 不会与 Flutter 冲突；
- 其余内容与 Flutter 3.44.9 模板**逐行相同**（仅注释除外），并包含需要的
  `flutter_ios_podfile_setup` / `flutter_install_all_ios_pods` / `flutter_additional_ios_build_settings`；
- **不含** Flutter 会硬失败（throwToolExit）的过时模式（如 `.flutter-plugins'` 引用）。

## 4. 验证（本机，无 macOS）

| 检查 | 命令 / 方法 | 结果 |
| --- | --- | --- |
| 全部工作流 YAML 可解析 | `yaml.safe_load` 遍历 `.github/workflows/*.yml` | **9/9 OK** |
| 步骤 shell 语法 | 抽出 `run` 块 → `bash -n` | **exit 0** |
| 重试循环：瞬时 504 后成功 | 用 stub `flutter`（第 1 次 `exit 1` 模拟 504，第 2 次成功）跑真实 `run` 块 | 输出 `iOS build attempt 1/3` → `Build attempt 1 failed; retrying in 20s...` → `iOS build attempt 2/3` → `iOS build succeeded on attempt 2/3`；**exit 0** |
| 重试循环：持续失败 | stub 改为每次失败 | 三次尝试后 `All iOS build attempts failed`；**exit 1** |
| Podfile 与模板一致性 | 去注释后 `difflib` 比对 Flutter 3.44.9 模板 | 唯一差异：`+platform :ios, '16.0'` |
| Podfile 平台与工程一致 | `project.pbxproj` 部署目标统计 | `16.0` ×3（一致） |
| 应用门禁不受影响 | `flutter analyze`；`flutter test --timeout 120s` | **No issues found**；**`+3170: All tests passed!`** |

## 5. 未验证 / 剩余风险

- **未在 macOS 上真实执行**：本环境无 Xcode/macOS，无法运行 `flutter build ios` 或 `pod install`。
  重试逻辑已用 stub 完整走通（成功与失败两条路径）、语法与 YAML 已校验，但**真实的 pod 下载修复效果
  需要下一次 macOS CI 运行确认**。
- **提交 Podfile 的维护含义**：仓库现在**拥有**该文件，Flutter 不再自动生成它。
  若未来 Flutter 模板变更（例如插件清单机制调整），可能需要同步更新；反之 Flutter 在检测到过时模式时会
  抛出明确的 `Warning: Podfile is out of date` + 重新生成指引，不会静默出错。
- **首次 CI 可能重新解析依赖**：此前依赖由自动生成的 Podfile 决定，现在由提交的 Podfile 决定。
  由于仅新增 `platform` 一行，且取值与工程部署目标相同，pod 解析结果预期不变；但仓库未提交
  `Podfile.lock`，因此 CI 每次仍会重新 resolve（这是既有行为，本次未改变）。
- 504 属于 GitHub 侧瞬时故障，重试只能提高成功率、无法根除；若长期高频出现，应考虑镜像/自托管 pod 源。
