# 历史消息定位、旧媒体及iOS连续性修复

## 恢复入口

- 用户反馈：五天前聊天搜索点击显示“未找到该消息，请稍后重试”；图片/视频昨天及更早仅占位。用户确认模拟器2198和真机2196，要求预防iOS L04/L07而非报告当前iOS故障。
- 授权：本会话直接修复请求，沿原任务自主实施与ADR决策；[计划](../../superpowers/plans/2026-10-04-history-anchor-media-ios.md)、[原托管ADR](../../adr/2026-10-04-server-custodied-matrix-recovery.md)。
- 基线main3b9d7c24；新branch codex/history-anchor-media-ios-20261004，复用隔离工作树。主目录WIP不修改。当前状态：已完成源码调查，Task1即将test-first实施。
- root拥有本记录/计划/索引/最终证据；独立ios_l04_l07_investigation仅只读调查，无源码或Flutter动作。Task1/Task2顺序独占源码和工具。
- 记录时间2026-10-04 17:36+08，调查准确起始时间未知，不以文件mtime编造耗时。下一步Task1真实失败测试→最小修复；Task2真实SDK身份回归→定向修复；整批及平台交付。

## 验收台账

| ID | 预期 | 调查/实现 | 测试/发布/缺口 |
| --- | --- | --- | --- |
| H1 | 五天前可访问消息能定位气泡 | locateEvent本机数据库返回Event直接经Message类型可见性过滤，密文未解密就false；需RED确认 | 尚未修复/未新构建 |
| H2 | 旧图片视频缩略图和正文可按需加载 | loadThumbnail/loadAttachment只查已加载timeline事件，1000live窗口外旧媒体会StateError | 尚未修复/未新构建 |
| I1 | 密钥加载不会使iOS登录/账号存储永久L04/L07 | SDK newdevice内存采纳→callback旧owner drain→durable update→应用绑定rotate，callback超时可导致身份分裂；是假设，尚未真实复现 | 真实SDK/保留库失败用例待实施，不能称当前iOS故障 |

## 边界

2198 debug已装模拟器；正式Android2196/iOS2194沿上一轮发布事实，本轮需重读后冻结新debug号。原服务已启用，但不把其技术验收当真实用户历史恢复。保持本机历史/Olm/SQLCipher/keychain、房间/账号绑定、金融域及敏感日志规则；不清除数据、不重置密钥，不泄露用户事件/媒体内容。
