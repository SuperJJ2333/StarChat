# AWS 新账号 CDN 客户端兼容发布

日期：2026-11-04 HKT。用户在当前直播迁移任务中已选择“先发布兼容新域名的 App，升级后删除旧 CDN”。按既有发布流程在当前聊天执行；不改原 StarChat 工作树。

## 范围与设计

线上 Android 0.4.67+2236 的源码为 37b472702311c7f161c09e6a297970135c1d2148。该源码与维护分支的 mobile_flutter Git tree 一致。新目录独立分支 codex/aws-cdn-app-migration-20261104；原生跨项目创建和登记工具不可用，采用 Git 后备隔离目录，未登记为桌面托管工作树。

只将表情资源默认域名由 d12fjr06o6tga5.cloudfront.net 改为新账号 d29qsnrzc2iag0.cloudfront.net；严格允许这两个精确域名。HTTPS、固定路径、端口/用户信息/查询/片段拒绝、重定向与资源摘要校验不变。旧域名在升级窗口保留。保留缓存键、资源内容、Matrix/金融/认证/加密行为。

## 执行与验收

1. 先写新默认值、新域名接受、旧域名兼容及伪造主机/非HTTPS/不合法路径拒绝的失败测试，保存真实 RED。
2. 最小源码修正，执行相关表情/资源传输回归、analyze 与共享全量门禁；环境、原生DLL和源码输入绑定。已有失败不得改写为通过。
3. 发布前核对线上版本及其他任务占用号；当前候选 0.4.68+2237，最终冻结前重核。按既有 Android 重建/对齐/固定75b31签名及语义校验流程构建，不能发布原始Gradle APK。
4. 先规格符合性，再独立质量/安全审查。仅处理本任务重要问题，不改变金融和E2EE边界。
5. Android 新包先上传并验证，再切官网、manifest和Android设置，保留回退及iOS平台隔离。iOS沿用同源设备构建与企业回签流程；没有最终签名或所需设备证据时明确阻断，不发布未签名包。
6. 旧安装CDN仅在兼容包发布且用户升级后删除；旧客户端内置域名不能靠服务器改写迁移。服务器和存储迁移独立继续。

## 文件所有权

- apps/mobile_flutter/lib/features/emoji/emoji_resource_store.dart
- apps/mobile_flutter/test/features/emoji/emoji_cdn_migration_test.dart
- apps/mobile_flutter/test/features/emoji/emoji_resource_transport_test.dart（仅默认目标主机断言同步）
- 版本冻结时的 pubspec.yaml 及实际要求的版本同步文件
- 本任务计划、任务账、验证报告及 docs/verification/artifacts/2026-11-04/aws-cdn-client-compat/

不合并main，不改其他工作树，不联系第三方签名方。源代码候选推送仅用于已授权构建/发布，发布必须绑定实际候选摘要。
