# 2026-09-25 iOS 0.4.7/2173 应用内更新弹窗

## 恢复入口

- 目标与授权：用户在官网 2173 分发后反馈“使用没问题”，明确要求推送更新弹窗。仅 iOS 0.4.7/2173，沿用已发布 HTTPS 安装页；保持最低支持 build 3，为非强制更新；Android 不变。用户反馈不等同于独立核验健康旧版 iPhone 的聊天数据/钥匙串保留。
- 关联：[官网链接分发任务](2026-09-25-ios2173-link-only-distribution.md)、[企业发布计划](../../superpowers/plans/2026-09-24-ios-047-enterprise-distribution.md)、[轻量发布门禁](../../runbooks/release-metadata.md)。既有普通 `release_metadata.py publish` 会拒绝此次用户明确接受的企业签注入，因此使用单独的仅 iOS 设置发布路径，不改常规门禁。
- 当前状态：**已发布并回读**。官网 IPA SHA256 `29d9946b3469d59c64d73d679838623873930f8a7c2ae7c087eb2e5589acc3d0`、61,495,036 字节；应用内 iOS 已为 0.4.7/2173，Android 仍 0.4.7/2172。发布备份及审计结果位于服务器 `/opt/starchat/docs/verification/artifacts/2026-09-25/ios2173-popup-20260925T0944HKT/`，审计 trace 为 `ios-popup-0.4.7-2173-20260925T0944HKT`。
- 文件所有权：独立代理拥有新 `scripts/publish_ios_update_popup.py` 与 `tests/mobile/test_ios_update_popup_release.py`；root 拥有本任务/验证记录、生产发布与回读。无并发编辑同一文件。
- 最后更新时间：2026-09-25 09:48 +08。
- 下一条具体操作：用户在旧版 iPhone 上核对应用内非强制弹窗、跳转官网并直接覆盖安装；继续单独收集健康旧版设备的聊天数据/钥匙串保留及后台提醒反馈。

## 验收台账

| ID | 场景及预期 | 当前证据 | 状态 |
| --- | --- | --- | --- |
| IOS2173-POPUP | 旧 iOS 看到 0.4.7/2173 可关闭更新弹窗 | 客户端/API 路由源码、生产设置 2173；实际旧机 UI 待反馈 | 服务端已通过，真机待验 |
| IOS2173-NONFORCE | 最低支持 build 3 不变 | 发布前后十键快照均为 3 | 已通过 |
| IOS2173-LINK | 弹窗跳已发布 HTTPS 安装页及 2173 IPA | 官网 HEAD/manifest、服务器 SHA、公网检查通过 | 已通过 |
| IOS2173-ISOLATION | Android 五项设置不变 | 发布前后十键快照一致，独立回读一致 | 已通过 |
| IOS2173-AUDIT | 三项 iOS 设置通过 SettingService 留审计 | trace 下恰有三条成功审计，before/after 匹配 | 已通过 |

## 阶段计时及交接

| 阶段 | 时间（+08） | 结果 |
| --- | --- | --- |
| 当前生产与路由调查 | 约 09:25–09:38 | 官网 2173 包/静态未漂移；iOS 设置仍 2144，Android 2172；API 无凭据 401 |
| 发布器红绿测试与审查 | 约 09:38–09:44 | 相关 97 项通过；实际发布记录预检通过；独立规格/质量审查无阻断 |
| 生产写入及回读 | 约 09:44–09:48 | 仅改三项 iOS 设置；三条审计；十项设置及官网再次回读通过 |

## 生产证据与限制

- 发布器 SHA256 `8dd5c8fbfc29c4f66ddcfbd3def30d2727a254f235411707c08e558af3799265`，服务器上传后哈希一致、`py_compile` 通过。它复核发布记录、已发布官网三个静态文件及最终 IPA 哈希/大小，不下载公网完整 IPA；在共享锁内保存 0700 私有前态后经 `SettingService.set_many` 更新三键。
- 首次发布返回 `IOS_UPDATE_POPUP_PUBLISH_PASS`、`audit_count=3`。发布后服务器备份 `result.json` 记录三条 `settings.update`/`SUCCESS`/`ADMIN_SETTING_UPDATED` 审计，before/after 分别为 iOS 2144→2173、0.3.102→0.4.7 和旧版→新版说明。
- 独立首次十键回读的 `docker exec` 进程退出 137，期间 API 容器被重建。随后新容器 `running,false,0` 且 healthy，十键回读成功，iOS 为 2173、Android 为 2172，公网 ready HEAD 与 `METADATA_CHECK_PASS` 成功。此次瞬断不掩盖；未发现设置回退。
- 设置前态检查与 `SettingService.set_many` 不在同一数据库事务，存在极短的并发写覆盖窗口。本次写入前检查与发布后审计/十键回读一致；后续改进应将 expected 校验纳入设置事务。

- 用户仍须用实际旧版设备确认更新弹窗及直接覆盖后的数据；设置回读不能替代设备事实。
- 若发布结果不确定，先读取 SettingService 当前值与审计，不盲目重放；回退只在三键仍是本次目标时经 SettingService 用新审计恢复原值，官网静态与旧包保持。
