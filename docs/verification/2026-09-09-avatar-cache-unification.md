# 消息、通讯录与朋友圈头像一致性续修

用户反馈：消息页无法加载自定义头像，不同页面速度不同；授权 VPN 网络对照。本次在 `codex/redmi-polish-20260909` 上继续，前置提交 `59660163`。

## 原因与改动

原有控件最终都可经过 AvatarCache，但输入并不统一：消息私聊使用 Matrix 房间头像和房间 ID，群成员使用 Matrix 头像及 Matrix 用户 ID，通讯录使用业务头像和用户名，朋友圈作者使用业务头像和业务用户 ID。预热与清理又使用 Matrix 用户 ID。因此“共用缓存类”并不等于“命中同一头像缓存”。

- 消息私聊按 directPeerId 查找共享业务联系人资料，已知联系人优先使用业务头像，缓存身份与通讯录一致。
- 群聊拼图和折叠群聊复用相同资料投影；当前用户使用个人资料的 fallbackSeed，陌生成员保留 Matrix 回退路径。
- 业务资料中明确移除头像时不复活旧 Matrix 头像；联系人头像失效清理及预热使用与显示相同的用户名身份。
- 朋友圈作者头像改用用户名身份，无用户名的旧数据才回退业务用户 ID。
- 消息页既有每分钟定时器静默刷新联系人，更新短期签名链接，不清空已显示头像。
- 未修改 Matrix 鉴权、登录状态机、TLS 验证或后端部署。

## 测试与审查

证据均位于 `artifacts/2026-09-09/redmi-polish/`。

- `conversation-avatar-red.log`：业务头像优先、缺失 Matrix 头像、本人身份、显式移除四项先失败。
- `avatar-removal-red.log`：证明联系人移除头像后，原清理键不能清除页面使用的 retained 图片。
- `conversation-avatar-green-final.log`：六项身份/清理回归与四项消息页已有测试通过。
- `moment-avatar-red.log` / `moment-avatar-green.log`：朋友圈作者与通讯录缓存身份一致，先失败后通过。
- 最终全量 1497 项全部通过，静态分析 No issues found：`flutter-avatar-unified-final.log`、`analyze-avatar-unified-final.log`。
- `repository-verify-conversation.log`：仓库验证 PASS，包括 OpenAPI、迁移与 Compose 渲染。
- 规格审查：好友与本人按权威资料选择头像，未知 Matrix 成员保留原路径；不把群房间自定义头像当作某个好友头像。
- 质量/安全审查：用户名仅用作现有业务账号域内头像身份，不用于 Matrix 登录或授权；不将 token 放入键或日志；显式删除不会从 Matrix 恢复已移除头像。代码不访问或改变聊天密钥。

## 网络与设备观察

开始时 Android VPN 设置开关已关闭，状态栏也无 VPN 标志；本轮没有开关 VPN，最终保持初始关闭状态。因此这不是同一轮严格控制变量的 VPN 开/关实验，不能声称已证明某个 VPN 应用是唯一原因。

关闭状态下，旧 2069 版本冷启动后也成功加载全部消息页头像，说明此前的 TLS 失败与纯 UI 缓存差异需要分别处理。2070 的首次安装观察中，登录自动恢复，消息页三个私聊头像及群头像均正常，通讯录来回三轮后仍保持显示。该观察进程日志统计 HandshakeException、AvatarLoadError、FATAL EXCEPTION、RenderFlex overflowed 均为零，见 `conversation-device-check.json`；这不等于无限时长零错误保证。

朋友圈顶部本人头像也恢复显示；封面仍无本地 URL，未修改用户封面。因头像数据涉及真实用户，临时界面截图不进入交付证据或 Git。

## 交付

Debug `0.3.67-debug / 2070`，沿用本次已授权的设备 Debug 签名，覆盖安装并保留数据。

- 最终文件：`artifacts/2026-09-09/redmi-polish/ChatFlow-0.3.67-debug-2070-redmi-rebuilt.apk`，142224210 字节。
- SHA-256：`7c91709db818c6bf540625772c4e4eafe933ad921169a47956a62ee7f0b196b5`。
- `avatar-unified-delivery-verification.json`：设备已安装包与交付文件哈希相同；与固定签名版的应用载荷一致。
- `package-avatar-unified/verification.json`：全量 apktool 重建 DEX/资源，Manifest 语义、类与原生资产核验通过；16KB 对齐及既有 Debug 证书验证通过。

最后仅补入朋友圈作者用户名缓存身份后再次构建/安装，安装哈希已核对。三轮消息/通讯录及零错误统计来自该补丁前的同次 2070 构建；最终补丁由头像 widget 回归和 1497 项全量测试验证。最终安装后设备已在其他功能页面，未再次强行切换以免打断用户操作，不能把之前进程的零错误计数冒充最终进程计数。

原七项任务的其他真机限制、Figma 暂缓与后端迁移协调事项仍见 `2026-09-09-redmi-polish.md`，本续修不将它们自动标记完成。
