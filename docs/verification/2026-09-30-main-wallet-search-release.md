# Main、钱包与搜索更新验收（2026-09-30）

用户要求检查并整合所有分支、删除钱包重复申请链接、充值仅展示最新订单、修复搜索好友备注和头像，并自动发布 Android、提供 iOS IPA 供用户企业签名。用户已预先批准必要计划和 ADR。执行计划见 [计划](../superpowers/plans/2026-09-30-main-wallet-search-release.md)，恢复入口见 [任务](../workflow/tasks/2026-09-30-main-wallet-search-release.md)。

## 源码及验收

- 19 个原分支与 origin/iOS 分支逐项核对，独有增量合入 main；已经被最新源码替代的旧版本保留可追溯合并历史。45 个工作树的源码补丁和非敏感未跟踪文件先保存快照。所有删除的分支头均验证为 main 祖先；脏工作树脱离分支前后状态逐字节一致。根目录原未提交工作保存为 stash `16018d5cdcc593c5d01339d8d789df232d2f0e0a`，不盲目回放覆盖新版本。最后再次清理并行工作重新创建的已合并分支。
- 钱包移除下方绿色重复申请入口，顶部申请通知保留。充值表单按创建时间选最新一单；历史记录保留，未完成本地操作仍能恢复。
- 搜索及多命中聊天记录采用当前联系人备注、头像与当前房间投影，保留精确事件定位；原始 room ID 不再作名称。以 `!` 或 `@` 开头的合法群名仍正常显示。
- 合并后修复两项实际问题：匿名启动诊断的三种关联 header（含尾斜杠 307）不进入响应/性能关联记录；监控非 advisory 证明失败使旧储备证据失效，同时不新增全局冻结。管理员主动暂停、资金覆盖门槛、账本、事故、权限、审计及幂等断言保留。

## 验证结果与复用范围

证据目录为 `docs/verification/artifacts/2026-09-30/main-wallet-search/`，命令环境 Windows、PowerShell 7、Python UTF-8。

| 门禁 | 结果 | 证据 |
| --- | --- | --- |
| Flutter 全量 | 5136 passed、9 条件跳过，退出 0 | flutter-full.log |
| Flutter 最终钱包/搜索 | 40 passed，新增合法群名前缀回归 | review-mobile-green.log |
| Flutter analyze | 退出 0，无问题 | analyze-final.log |
| 前端最终全量 | 519 passed、0 failed，退出 0 | frontend-release-npm-final.log |
| Mobile/infra | 1217 passed、1 条件跳过，退出 0 | mobile-infra-final4.log |
| API/Worker 初次全量 | 3822 passed、40 failed、117 条件跳过 | business-final.log |
| 合并增量后端 | 244 passed、0 failed，退出 0 | merged-backend-green.log |
| 钱包/Worker 最终全量 | 1445 passed、31 条件跳过，退出 0 | wallet-worker-final.log |
| 启动诊断/时间线 | 142 passed、0 failed，退出 0；新增 2 项 RED→GREEN | privacy-red.log、privacy-green.log |
| 储备证明故障 | 12 passed；初次全量 9 项失败提供 RED，新资金门槛断言纳入钱包全量 | reserve-proof-green.log |
| 发布元数据 | 3 项 RED→GREEN，最终前端全量通过 | release-metadata-red.log |
| UI 契约 | 33 components、518 screens，PASS | 既有契约日志 |

初次后端 40 个失败已逐项处理：2 个夹具不再污染 Redis 类/提交只读字段；9 个证明失效用例修复真实回归；29 个旧自动冻结期望按已批准告警策略调整，主动管理员暂停明确初始化。其余未变输入的已完成门禁依据交付手册复用，没有虚称重新执行全仓绿色。唯一 Python warning 为现有 Starlette/httpx 弃用提示；条件跳过包含平台及 PostgreSQL 专项环境用例，不视为已执行。`verify.ps1` 的仓库/部署/模板门禁通过，整体停在缺本地 `.env`，未复制生产凭据，不宣称该整体门禁通过。

## Android 发布

- 版本 `0.4.25+2194`，包名 `com.liuhetong.mobile`，ARM64。
- 冻结源码 `05c05793cf089312a0ae8001aeb742ad19e8ff95`；1811 文件 manifest SHA256 `93f7896caf38f533c940dacaa8240200a15a2ea3e3977439c72d4bf0800205d5`。后续提交只修改后端、发布元数据、测试与文档，移动源码未变。
- 最终 APK 81,767,454 bytes；SHA256 `97d26386b520a3296925ff2d340cf377ab010c21a3366507143410dc0b4aa8d6`；原用户稳定证书 `75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`。
- 源构建、Apktool 2.12.1 常规重建、对齐、原密钥 v2/v3 单签名、最终独立解包、资源/DEX/Manifest/资产内容比对、锁屏边界全部通过。缺失历史工具从官方固定版本恢复；DPAPI 密码文本换行修正后复用原对齐包签名，没有轮换密钥或重复源构建。
- [正式安装入口](https://www.liuhetong888.com/download?platform=android&install=1) · [固定 APK](https://www.liuhetong888.com/downloads/ChatFlow-0.4.25-build2194-arm64.apk)。HK 与 S3 文件校验一致，CloudFront 仅新增第四条精确文件授权，保留三条旧路由；公开 HEAD 200、Range 206、TLS 验证及元数据均通过。
- 版本/build/URL 通过既有 SettingService、十键 CAS 与审计发布；弹窗文案“钱包申请提醒不再重复；充值页只显示最新订单；修复搜索好友备注、头像及聊天记录显示。”只有 Android notes 变化，一条审计。iOS 五项设置及最低版本均保留。
- 新上传脚本按线上 LF 字节记录静态 hash，与 Windows CRLF 源码内容等价，不覆盖现有下载脚本。后台业务容器由另一批准任务发布，最终观察 API `40ad213c`、Worker `3efd5924`；本任务不部署后台或执行退款。

## iOS 签名交接及回退

CI [36712413903](https://github.com/SuperJJ2333/StarChat/actions/runs/36712413903) 使用冻结 main 源码，模拟器及 signed build 两个 job 均成功。模拟器覆盖 SQLCipher/WAL、Keychain、会话通知与原生导航 XCTest；正式包验证严格 codesign、生产 APNs、iPad、权限、SQLCipher 加载顺序。App Store 渠道候选交付用户企业重签，不自动替用户做企业签名。最终 IPA 61,363,376 bytes，SHA256 `a2f7db096df422c87ab472869909a073c38c8144729b2d1d049e7f7cca3ab6d1`；ZIP CRC、版本/包名/签名 entitlement、冻结 HTML 与 SQLCipher 存在性本地复核通过。完整身份见 `ios-release/ipa-identity.json`。

下一步：用户返回企业签名 IPA 后，运行 `verify_ios_enterprise_ipa.py` 检查最终身份/签名渠道，运行 `compare_ios_ipa_payload.py` 对照本次冻结候选，确认数据保留与安装验证，再分发。当前线上 iOS 仍为 `0.4.20+2189`。

生产私有备份均在 `/opt/starchat/docs/verification/artifacts/2026-09-30/`：`main-wallet-search-2194-standard-20260930T124100Z`、`main-wallet-search-2194-network-20260930T124400Z`、`main-wallet-search-2194-popup-20260930T124500Z`。需要回退时先核对十键配置与审计漂移，再用公用 SettingService 事务回到保存基线；先将入口/版本恢复，再切 `latest-arm64.apk` 到旧 2193，保留不可变包及旧 CDN 精确授权。响应不确定时只读检查，不盲目重试或静默退款。
