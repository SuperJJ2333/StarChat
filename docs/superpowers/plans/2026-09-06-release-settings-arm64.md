# 发布配置与 ARM64 发行修复计划

状态：用户于 2026-09-06 授权执行上一轮明确提出的 TEXT 扩容、原子发布、单架构 APK 方案并替换线上 APK。

## 设计与范围
数据库 value 扩容为 TEXT，保留 API notes 2000 / URL 500 契约；五个发布字段及审计一次事务提交，读取一次查询快照。迁移不删除数据，回退应用可保留 TEXT，收窄必须拒绝长值而非截断。Android 发行只打包目标架构，保持推送/音视频/加密功能、固定 75b31c66 签名及常规 Apktool 重建。新版 0.3.46+49，非 split 构建以保留正式 versionCode 序列。debug 不全局限制 ARM64，以保留模拟器调试能力。

## 步骤与文件归属
1. 后端任务 owns services/business-api/app/modules/settings/{models,service}.py、app/api/{admin,app_update}.py、migrations/versions/0038*、tests/business_api/settings 与更新 API 测试：先失败用例，再扩容、批量原子写与快照读；真实 PostgreSQL 验证长度、迁移和失败回滚。
2. 主任务 owns apps/mobile_flutter/android/app/build.gradle.kts、pubspec.yaml、scripts/verify_android_release.py 与相应测试、发布 runbook 和本证据目录：建立真实 APK ABI 检查，旧包失败，新 ARM64 包成功；源构建 release、Apktool 2.12.1、16K 对齐、固定签名，源码/最终产物等价性验证。
3. 先规格审查再质量审查；运行聚焦测试、全仓 scripts/verify.ps1、Flutter analyze，记录结果。
4. 检查服务器当前镜像与 schema，仅部署必要后端更改及非破坏迁移。上传不可变新版 APK，核对 SHA256 与公网完整下载，再原子发布五项配置并切换 latest 符号链接；保留旧包/镜像回退。不得泄露密钥或修改用户数据。
5. 提交推送，记录大小变化、发布 URL、实际版本/签名、后端迁移与发布验证。不声称未执行的真机验收。
