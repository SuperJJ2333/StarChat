# 0.3.46 发布配置与 ARM64 发行修复

状态：已完成代码修复、服务器部署、APK 公网完整校验和发布配置切换。
用户授权：针对上一轮查明的问题「修改代码，并替换线上 APK」。
源码修复提交：917d989；计划：2026-09-06-release-settings-arm64。

## 修复与验证

- `app_settings.value` 扩为 TEXT；API 文案 2000、URL 500 字符限制保留。
- 五个发布字段及审计在单个事务中提交；PostgreSQL 发布锁覆盖首次写入竞争，
  管理与客户端使用一条 SQL 读取完整配置。
- 0038 从线上已有 0036 独立迁移；本次未部署 0037 钱包变更。
  仓库 0039 是无 DDL 合并节点，未来全量部署仍需先审查 0037。
- Gradle 非 split 构建按显式 target-platform 筛选所有插件 ABI，保持其他目标
  与 split 构建能力。pubspec 和 AppConfig 备用版本同步为 0.3.46+49。
- 增加真实 APK 内容门禁，旧 0.3.45 因多出 ARMv7/x86_64 库被拒绝，
  新源 APK 和最终包均只包含 ARM64 和完整 Flutter AOT/引擎库。
- 全仓 `scripts/verify.ps1` PASS：17 infra、28 Getui、9 Matrix Bot、
  349 business/worker、65 mobile 测试通过；19 个既有环境依赖用例跳过。
  UI 契约、AST、Alembic 单 head/offline SQL、OpenAPI、Compose 门禁均通过。
- 聚焦设置/API/迁移/APK 测试 29 通过；Flutter analyze 零问题。
- 独立临时 PostgreSQL 16.9 容器：旧列拒绝长值、TEXT Unicode2000/URL500
  往返、长值回退拒绝且保留数据、安全收窄后再扩容、首次竞争发布、审计失败
  整批回滚，以及 60 次竞争发布/123 次一致快照读取均通过。测试容器和网络已清理。
- 规格审查与质量审查无阻断问题。顺带修复一个既有 Windows 浮动计时测试：
  使用假时钟替代 60ms sleep，推送生产代码不变。

## 最终 APK

| 项目 | 实际结果 |
|---|---|
| 文件 | ChatFlow-0.3.46-arm64.apk |
| 包名/版本 | com.liuhetong.mobile / 0.3.46 / versionCode 49 |
| ABI/模式 | 仅 arm64-v8a / release，无 debug kernel/debuggable 标记 |
| 大小 | 75,928,516 字节，约 72.4MiB |
| 旧包 | 121,797,267 字节，约 116.1MiB |
| 减少 | 45,868,751 字节，约 37.7% |
| SHA256 | a8afd2702bc6850a433eb0c3eed1ea9e22d42d9be2a6480fee6f58cd6c4e3be9 |
| 签名 SHA256 | 75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff |

源构建 standard/release/target android-arm64，保留三个 HTTPS dart-define。
Apktool 2.12.1 完整重建；build-tools36 zipalign16K；既有固定 RSA3072 密钥
签名，未生成新密钥。apksigner v2/v3 与签名后对齐验证通过。
重解包核对 24,573 个类全部一致，331 个原生库/Flutter资产逐项 SHA256 一致，
完整清单语义一致；DEX 与 resources.arsc 确实经过重建。

最终文件位于独立工作目录的
`docs/verification/artifacts/2026-09-06/release-settings-arm64/final/`。
同任务目录外层的较早候选 APK 已废弃，未发布；线上只使用 final 子目录校验的 SHA。

## 线上状态与回退

- 后端镜像：`starchat-business-api:settings-arm64-0.3.46`，
  基于实际线上 cache-entry-0.3.45，仅覆盖必要四个源文件和 0038 迁移。
- 线上迁移 head：0038_app_settings_text，value 实际类型为 text。
- 运维目录：`/opt/starchat/releases/settings-arm64-0.3.46/`；
  当前 compose 使用该目录 `compose.override.yml` 覆盖已有三个基础配置
  与 cache-entry-0.3.45 覆盖文件。
- 通过应用自身校验和一次 set_many 发布 0.3.46/build49/min3，
  成功保存 **326 字符**文案，trace `release-0.3.46-build49` 对应 **5 条**
  settings.update 审计；五项回读一致，更新路由的服务端读取结果为 0.3.46/49。
- 公网不可变下载 URL：
  https://www.liuhetong888.com/downloads/ChatFlow-0.3.46-arm64.apk
- 本地、服务器文件、公网分段完整下载合并的 SHA256 完全一致。
  latest-arm64.apk 已原子切换到新文件，公网200、Content-Length75928516。
- 后端 ready 返回200/database ready；重启阶段短暂502已恢复。
- 旧0.3.45 APK仍保留。回退应用使用 `compose.rollback.yml` 中的
  `starchat-business-api:settings-schema-0.3.45`（旧应用+0038定义），保留TEXT；
  不使用不认识0038的旧镜像直接启动Alembic，也不执行数据截断。
- 未执行本轮真机安装或实际用户登录升级测试。Mi6此前debug签名不同，
  本次正式包保持线上签名，不卸载手机应用或清理用户数据。

构建中既有插件 Kotlin 迁移/Java deprecated 提示、Python依赖弃用提示仍存在；
未关闭检查、忽略新失败或改变生产依赖来隐藏它们。
