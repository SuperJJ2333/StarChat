# 超级表情自动播放回归修复

## 恢复入口
- 用户最新要求：修复超级表情需要手动点击，并评估内存与保留方案。覆盖上一轮静态优先/点击播放的选择；沿用已授权的修改产品与模拟器 Debug 验证。
- 工作树：C:/Users/Administrator/.codex/worktrees/im-reliability/StarChat；分支 codex/mobile-experience-2216-20261016；基线7093a1ff。
- 关联计划：[2216实施计划](../../superpowers/plans/2026-10-16-mobile-experience-2216.md)，本次增补仅恢复可见消息自动播放。
- 文件所有权：root 独占 super_emoji_message.dart、emoji_resource_glyph.dart 注释、对应 widget/player 测试、HTML experience/catalog/registry 与文档。播放器预算和账户/E2EE语义不变。
- 当前状态：09:28+08 修复与Android实际main验收完成。源码544b61b6；共享全量6038PASS/9SKIP/0FAIL，Android最终SHA21553235…8ceab5已保数据install-r至5556；真实无点击0→40帧/2秒，后台/离屏停止，恢复/滚回自动50帧，当前帧0.5MiB。新iOS IPA SHA df32ef4f…4bd6d已构建/验包并复制Downloads；重复且输入未变的存储job主动取消，保留原21PASS/2ERROR及4PASS/4SKIP限制。下一步是匹配签名iPhone播放/APNs、低内存Android Profile与Release验收；不阻塞已完成源码/模拟器修复。详见[报告](../../verification/2026-10-16-super-emoji-autoplay.md)。
- 证据目录：docs/verification/artifacts/2026-10-16/super-emoji-autoplay/。不得覆盖原2216证据。

## 验收台账
| ID | 场景及预期 | 实现 | 测试及证据 | 发布 | 缺口 |
| --- | --- | --- | --- | --- | --- |
| E1 | 可见消息无需点击，加载期间立即显示静态预览 | 完成 | RED→GREEN，实际main旧0→新40帧/2秒 | 仅候选 | 真机待验 |
| E2 | 离屏/后台停止，返回自动恢复，共享同资源解码 | 完成 | 60专项，实际后台0/恢复50/离屏0/滚回50帧 | 仅候选 | 全ROM未测 |
| E3 | 内存结论区分当前帧预算与完整进程/native | 完成初评 | 0.5MiB当前帧、PSS点采样337–368MiB、受限日志OOM0 | 不涉及 | 长期/低内存真机待验 |
| E4 | Android保数据覆盖与HTML同步 | 完成 | 固定签名重建与install-r保持UID/安装时间；UI34/540 | 不改正式渠道 | iOS新IPA已构建，签名真机待验 |

## 阶段计时
| 阶段 | 开始 | 结束 | 类型 | 结果 | 下一步 |
| --- | --- | --- | --- | --- | --- |
| 定位 | 2026-10-16 08:51:24+08 | 08:56:11+08 | 主动/工具 | 确认消息行显式手动模式；没有OOM证据 | RED |
| RED/实现/专项/双审 | 08:56+08 | 约09:04+08 | 主动/工具，区间近似 | RED环境修正一次；60PASS/analyze0/HTML4PASS/SPEC→QUALITY | 全量 |
| 最终共享全量 | 09:01:27+08 | 09:17:36+08 | 工具，约969秒 | 6038PASS/9SKIP/0FAIL，退出0 | Android构建 |
| iOS CI | 09:07:22+08 | 09:16查询device已完成 | 外部，和本地并行 | 新IPA校验0；native job仍进行中 | 下载/签名真机 |
| Android构建 | 09:17:40+08 | 09:23:17+08 | 工具，337秒 | 常规重建/固定签名/语义验证PASS | 安装 |
| Android安装 | 09:23:46+08 | 09:23:58+08 | 工具，12秒 | UID/首次安装/SHA保持 | 真动画 |
| 实际A/B播放 | 约09:20+08 | 约09:27+08 | 主动/工具，与构建后段重叠 | 旧包0帧；新包无需点击/共享/前后台/滚动通过 | 记录与交付 |
| iOS重复job收口 | 约09:22+08 | 09:27查询完成 | 外部 | 仅未完成存储job取消；device SUCCESS保留，旧错误保留 | 真机 |

## 回退
恢复本任务前的消息行/演示代码即可回到点击播放，无数据库迁移。旧 main Debug SHA ae7e9eabd7bd1fb56eafd1e5907c279fea2232e688654656aa7791a1f5d9d619 保留，可同签名 install-r；禁止卸载/清数据。正式Android/iOS2215未由本任务发布。
