# 2026-09-12 Android CI Maven 仓库顺序修复

## 范围

仅 `apps/mobile_flutter/android/build.gradle.kts`（仓库顺序按环境选定）。不发布 APK/IPA/服务，不改业务行为。

## 根因

android-ci 的 `android-debug-build` 跑在 GitHub Actions 海外 runner，但首个仓库是阿里云镜像。Gradle 仅在 404（仓库无此构件）时尝试下一个仓库；镜像返回 5xx（2026-09-04 首跑 502）直接判定依赖解析失败，不发生依序回落。原配置"镜像优先+官方回退"对 502 场景无效，注释中的回落假设有误。

## 修改

- `GITHUB_ACTIONS` 环境变量存在（CI）：`google()` / `mavenCentral()` / `gradlePluginPortal()` 优先，项目仓库不含阿里云。
- 本地（国内）构建：保持阿里云 `repository/google` 优先，官方源回落；另注意本机 `~/.gradle/init.d/aliyun-mirror.gradle` 会向所有项目 buildscript 注入三个阿里云镜像，本地行为不变。

## 验证证据（2026-09-12，Windows 10 / Gradle 9.1.0）

- `./gradlew help`（本地模式）退出码 0；`GITHUB_ACTIONS=true ./gradlew help`（CI 模式）退出码 0。
- init 脚本 `artifacts/2026-09-12/check-repos.gradle`（本地排除，不入库）打印实际仓库顺序：
  - CI 模式根项目 `PROJECT_REPOS=[Google, MavenRepo, getui, storage.googleapis.com/download.flutter.io, ...]`，无阿里云。
  - 本地模式根项目 `PROJECT_REPOS=[maven(aliyun/google), Google, MavenRepo, getui, ...]`，镜像优先。
  - 注意：切换模式前需 `gradlew --stop`，复用旧 daemon 读不到新的客户端环境变量。
- `python -m pytest tests/mobile -q`：68 通过 / 2 失败，失败均为工作区其他任务的既有问题（finance-chat 验证工件目录缺失；`matrix_home_page.dart` 搜索页断言），与本改动无关，两者不读取 build.gradle.kts。
- 阿里云当前对报错 URL 已恢复（返回 404），本次修复保证下次 5xx 时 CI 不再失败。

## 下一步

推送后 android-ci 的 `android-debug-build` 任务为权威验证；CI runner 无用户级 init 脚本，项目配置即最终生效。
