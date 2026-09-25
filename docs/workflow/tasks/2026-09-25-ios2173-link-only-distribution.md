# 2026-09-25 iOS 0.4.7/2173 官网链接分发

## 恢复入口

- 目标与授权：用户回传最终企业签 IPA 并要求分发；已确认只更新官网下载/安装链接，不触发应用内更新弹窗。此前“不卸载覆盖并保留旧数据”的要求继续适用。
- 关联计划：[企业分发](../../superpowers/plans/2026-09-24-ios-047-enterprise-distribution.md)、[最终 IPA 门禁](../../superpowers/plans/2026-09-24-ios-enterprise-ipa-validation.md)、[L07 恢复](2026-09-24-ios2144-old-account-l07.md)。本轮未改源码。
- 当前状态：**分发阻断，生产零写入**。签名身份和生产 APNs 通过，但非签名 Payload 比对失败；无健康旧版 iPhone 的同 SHA 保留数据覆盖证据。
- 负责人、工作树与文件所有权：`codex/online-room-refresh`；只新增本任务、独立验证记录和索引；其他代理只读。
- 最后更新时间：2026-09-25 08:20 +08。
- 下一条具体操作：签名方从原始 `ChatFlow-0.4.7-build2173-ci.ipa` 关闭注入/加固后纯回签，保留本次正确的 Team/App ID/Keychain/生产 APNs。回传新 IPA 后重跑最终签名与 CI Payload 比对，在健康 2144 iPhone 上不卸载覆盖并确认聊天记录、登录、钥匙串及后台提醒。通过后只更新官网 IPA、manifest、下载页/首页 iOS 链接，`app_ios_*` 保持原值。

## 验收台账

| ID | 场景 | 证据 | 状态 |
| --- | --- | --- | --- |
| IOS2173-SIGN | 旧企业身份、Keychain、生产 APNs | [验证记录](../../verification/2026-09-25-ios2173-link-only-distribution.md) | 通过 |
| IOS2173-PAYLOAD | 与 CI 原包仅签名差异 | 新增 2 dylib、`flag`；Runner 加载命令变化 | **失败** |
| IOS2173-UPGRADE | 健康 2144 持旧数据不卸载覆盖 | 当前连接故障机，无健康基线 | 未执行 |
| IOS2173-WEB | 官网链接 2173、无应用内弹窗 | 生产仍 2144；本轮零写入 | 未执行 |

## 版本与证据

| 对象 | SHA256 / 大小或版本 | 状态 |
| --- | --- | --- |
| CI 原始 IPA，run 36044338640 | `d05e4ea1178121fa37d5db7a85e2d0e901b1ae57ea5fb9eb5df64544488b63c1` / 60,869,118 字节 | 候选 |
| 用户回签 IPA | `29d9946b3469d59c64d73d679838623873930f8a7c2ae7c087eb2e5589acc3d0` / 61,495,036 字节 | 拒绝分发 |
| 生产 iOS / Android | 0.3.102/2144 / 0.4.7/2172 | 2026-09-25 08:19 +08 只读核验 |

回签 IPA 与 JSON 报告在根工作区 `docs/verification/artifacts/2026-09-25/ios2173-candidate/`、`docs/verification/artifacts/2026-09-25/ios2173-distribution/`。没有复制或改写用户包。

## 阶段计时与交接

| 阶段 | 时间（+08） | 结果 |
| --- | --- | --- |
| 本地签名/Payload 核查 | 起点未单独采集；08:20 前完成 | 签名退出码 0、Payload 退出码 1 |
| 生产只读快照 | 08:19 | iOS 仍 2144，未上传 2173 |
| 设备只读检查 | 08:20 前完成 | iPhone 8/iOS 16.7.16；无健康 2144 旧数据验收 |

- 未执行设备安装、文件上传、官网切换、设置写入或回滚，故无本轮生产备份或审计号。
- `release_metadata.py publish` 会写 iOS 版本/build，触发旧客户端自动弹窗，不适用于本次官网链接单独切换。后续须按发布当时线上快照制作静态候选、备份与逐项回读，并证明 `app_ios_*` 未变。
- 下一次先重新读取现网及审计，确认无并行漂移；新回签 IPA 必须重新取 SHA 和跑门禁，不复用失败包的记录。
