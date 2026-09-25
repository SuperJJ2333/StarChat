# 2026-09-25 iOS 0.4.7/2173 官网链接分发

## 恢复入口

- 目标与授权：用户回传最终企业签 IPA 并要求分发；已确认只更新官网下载/安装链接，不触发应用内更新弹窗。用户随后明确指出两个动态库与 `flag` 是其企业签方式的必要处理，并再次要求直接发布，因此本次对**精确 SHA 与四项已知差异**记录一次性例外；不宣称注入代码的运行安全或旧数据覆盖验收已完成。
- 关联计划：[企业分发](../../superpowers/plans/2026-09-24-ios-047-enterprise-distribution.md)、[最终 IPA 门禁](../../superpowers/plans/2026-09-24-ios-enterprise-ipa-validation.md)、[L07 恢复](2026-09-24-ios2144-old-account-l07.md)。本轮未改源码。
- 当前状态：**官网 iOS 0.4.7/2173 链接已发布**；下载页、首页和 manifest 公网回读一致。应用内 iOS 更新检查仍 0.3.102/2144，Android 仍 0.4.7/2172；未启用 2173 应用内弹窗。健康旧版 iPhone 的覆盖升级/数据保留测试仍缺。
- 负责人、工作树与文件所有权：`codex/online-room-refresh`；发布器与专项测试由独立代理编写并复核，root 负责生产操作、静态页面与任务证据。根工作区未改动。
- 最后更新时间：2026-09-25 08:47 +08。
- 下一条具体操作：在原本可正常登录且保有聊天记录的 2144 iPhone 上**不卸载**从官网安装此 SHA 的 2173，确认登录、旧聊天记录、后台通知/来电；故障 L07 设备另行验证新设备恢复。若失败按本任务私有备份恢复官网静态链接，保留旧包和证据。

## 验收台账

| ID | 场景 | 证据 | 状态 |
| --- | --- | --- | --- |
| IOS2173-SIGN | 旧企业身份、Keychain、生产 APNs | [验证记录](../../verification/2026-09-25-ios2173-link-only-distribution.md) | 通过 |
| IOS2173-PAYLOAD | 与 CI 原包的差异被精确枚举 | 新增 2 dylib、`flag`、2 条 Runner 加载命令；与归档 2144 企业签形态一致，用户明确接受该例外 | 例外发布；纯回签门禁仍失败 |
| IOS2173-UPGRADE | 健康 2144 持旧数据不卸载覆盖 | 当前连接故障机，无健康基线 | 未执行，待真机 |
| IOS2173-WEB | 官网链接 2173、无应用内弹窗 | `STATIC_IOS_LINKS_PUBLISH_PASS`、公网 HEAD/manifest/页面、设置前后 10 键一致 | 通过 |

## 版本与证据

| 对象 | SHA256 / 大小或版本 | 状态 |
| --- | --- | --- |
| CI 原始 IPA，run 36044338640 | `d05e4ea1178121fa37d5db7a85e2d0e901b1ae57ea5fb9eb5df64544488b63c1` / 60,869,118 字节 | 候选 |
| 用户回签 IPA | `29d9946b3469d59c64d73d679838623873930f8a7c2ae7c087eb2e5589acc3d0` / 61,495,036 字节 | 官网已发布；真机待验 |
| 生产官网 iOS / 应用内 iOS 检查 / Android | 0.4.7/2173 / 0.3.102/2144 / 0.4.7/2172 | 约 08:44 +08 公网回读 |

回签 IPA 与 JSON 报告在根工作区 `docs/verification/artifacts/2026-09-25/ios2173-candidate/`、`docs/verification/artifacts/2026-09-25/ios2173-distribution/`。用户原件未改写；同 SHA 字节已上传服务器私有暂存及官网不可变路径。

## 阶段计时与交接

| 阶段 | 时间（+08） | 结果 |
| --- | --- | --- |
| 本地签名/Payload 核查 | 起点未单独采集；08:20 前完成 | 签名退出码 0、Payload 退出码 1 |
| 生产只读快照 | 08:19 | iOS 仍 2144，未上传 2173 |
| 设备只读检查 | 08:20 前完成 | iPhone 8/iOS 16.7.16；无健康 2144 旧数据验收 |
| 用户明确接受企业签注入、私有上传及脚本门禁 | 08:20–08:42，上传与审查并行 | 历史 2144 同形态；服务器两 IPA SHA 与证据一致；发行专项 92 通过，移动 232 通过/1 跳过，前端入口 6 通过 |
| 官网静态发布 | 约 08:42–08:44 | 初试发布记录 SHA 抄写不全，写入前失败；修正后 `STATIC_IOS_LINKS_PUBLISH_PASS` |
| 公网与设置复核 | 08:44–08:47 | 服务器及工作站 SOCKS HTTPS 通过；IPA HEAD 200/61,495,036；10 项设置前后相同 |

- 本轮未对 iPhone 安装/卸载，也未写应用内版本设置或数据库审计。使用独立 `publish_ios_static_links.py`，没有调用会写 `app_ios_*` 的 `release_metadata.py publish`。服务器 0700 备份：`/opt/starchat/docs/verification/artifacts/2026-09-25/ios2173-link-only-release/backup-20260925T0842HKT`；本地同任务 artifacts 含发布 JSON、前后设置与公网小元数据快照。静态后态 SHA：download `583fb07b…bb42`、admin-home `8f55e625…1e01`、manifest `430f5f0b…64eb`。
- `release_metadata.py check` 报 `METADATA_CHECK_PASS`；服务器公网与工作站经既有 jumper SOCKS 的页面、manifest、首页哈希一致，IPA HEAD 200。工作站直连下载页曾超时，随后通过既有 jumper 路径验收，临时隧道已关闭。
- 下一次先读取生产当前态；若需回退，按备份中的 before.json 和三个静态原件做哈希 CAS 恢复，不删除已发布不可变 IPA 或覆盖 2144 旧包。真机覆盖尚未通过时不得宣称旧数据已保留。
