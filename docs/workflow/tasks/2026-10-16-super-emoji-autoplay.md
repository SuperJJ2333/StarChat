# 超级表情自动播放回归修复

## 恢复入口
- 用户最新要求：修复超级表情需要手动点击，并评估内存与保留方案。覆盖上一轮静态优先/点击播放的选择；沿用已授权的修改产品与模拟器 Debug 验证。
- 工作树：C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat；分支 codex/mobile-experience-2216-20261016；基线7093a1ff。
- 关联计划：[2216实施计划](../../superpowers/plans/2026-10-16-mobile-experience-2216.md)，本次增补仅恢复可见消息自动播放。
- 文件所有权：root 独占 super_emoji_message.dart、emoji_resource_glyph.dart 注释、对应 widget/player 测试、HTML experience/catalog/registry 与文档。播放器预算和账户/E2EE语义不变。
- 当前状态：08:56+08 已定位显式 playOnTap:true，测试先行；下一步验证无点击自动加载 RED，再恢复默认自动模式。
- 证据目录：docs/verification/artifacts/2026-10-16/super-emoji-autoplay/。不得覆盖原2216证据。

## 验收台账
| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 缺口 |
| --- | --- | --- | --- | --- | --- |
| E1 | 可见消息无需点击，加载期间立即显示静态预览 | 待做 | 无点击资源加载、帧推进 | 仅候选 | 真机待验 |
| E2 | 离屏/后台停止，返回自动恢复，共享同资源解码 | 复用既有播放器 | 生命周期与共享专项、模拟器 | 仅候选 | 全ROM未测 |
| E3 | 内存结论区分当前帧预算与完整进程/native | 调查 | 资源尺寸、诊断、PSS | 不涉及 | 不假设OOM |
| E4 | Android保数据覆盖与HTML同步 | 待做 | 固定签名常规重建、install-r、UI契约 | 不改正式渠道 | iOS新包待构建 |

## 阶段计时
| 阶段 | 开始 | 结束 | 类型 | 结果 | 下一步 |
| --- | --- | --- | --- | --- | --- |
| 定位 | 2026-10-16 08:51:24+08 | 08:56:11+08 | 主动/工具 | 确认消息行显式手动模式；没有OOM证据 | RED |

## 回退
恢复本任务前的消息行/演示代码即可回到点击播放，无数据库迁移。旧 main Debug SHA ae7e9eabd7bd1fb56eafd1e5907c279fea2232e688654656aa7791a1f5d9d619 保留，可同签名 install-r；禁止卸载/清数据。正式Android/iOS2215未由本任务发布。
