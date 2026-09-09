# 群聊 @、历史加载、日期筛选与 Redmi debug

## 实现和规则

- 仅群聊计算结构化 `m.mentions.user_ids` 包含本人或 `m.mentions.room=true` 的消息；排除本人发送、撤回及本地删除。昵称相同或正文出现普通 @ 不算提及。
- 首次在本设备建立状态时，保存现有 Matrix 已读事件 ID 作为边界。边界之后未被实际查看的提及进入队列；普通已读回执、进入/离开房间、历史加载不会整体清空它。按账号、房间、事件 ID 保存本地状态，不宣称跨设备同步。
- 使用 Matrix 时间线相对顺序，不用服务器时间戳决定提及先后。点击从最新待查看事件向旧事件逐条定位；失败不消费，移除旧 20 页定位上限。只有前台且当前路由中对应消息行可见达到 `min(行高的50%, 可用视口高的90%)` 持续 500ms 才标记查看；超长消息采用后一个阈值。pending 为空时列表前缀和标签消失。
- 扫描完成 checkpoint 与最新观察事件分开保存；网络失败不推进完成 checkpoint，下一次 sync 补扫缺口。本地隐藏、撤回保留已处理事件身份，防止同步重现。
- 列表摘要以独立红色 `#FF0000` TextSpan 前置 `[有人@你]`，保留原摘要。房间右上角显示 `↑ 有人@你`。
- 历史预取在距离已加载历史边缘约两屏时触发，60 条增量，单飞请求；列表稳定 key、reverse 锚点不变。不插入加载动画/状态行。耗尽由 SDK 分页状态判断，状态事件页或过滤掉的页不能被当成末尾；失败保留内容以便下次滚动重试。
- 查找页使用动态时间线并按需扩展历史，媒体缩略图/结果点击绑定新增消息；关键词、成员、媒体仍为 AND 组合。退出、清空或改变查询后，旧遍历在当前页完成后停止。
- 日期页按所选月份加载到该月起点，跨月/跨年复用 CalendarMonth 边界计算。空月提示“本月暂无聊天记录”；失败可重试；快速切月采用 generation 校验，旧月结果不能覆盖新月；日期重复点击只返回一次。可点击已确认有消息的历史日期，定位该日最早可展示消息。日期是定位入口，打开/取消不会清空媒体等筛选条件。

## 色值及可访问性

复用 `WeChatColors.elevatedSurface` 与 `resolveTextPrimary`。浅色白底 `#FFFFFF`、文字 `#191919`，对比度 17.58:1；深色 `#232323`、文字 `#F5F5F5`，14.42:1。选中使用 brandPrimary 15% 透明叠加现有页面背景，浅色约 `#CBE6D8`、文字 `#191919`，13.27:1。只高亮实际选中的媒体类型，日期和其他类型不被连带高亮。

## 验证

- Red：浅色筛选按钮测试发现实际为 50% 深灰而非白色；接线回归发现 MentionBannerButton、历史 token 状态接口缺失；撤回后重复同步测试发现提醒复活。均已修复。
- Flutter 全量：1,404 项通过；之后审查修正的重点回归 38 项通过；最终取消 20 页上限后的 6 项回归通过。
- Flutter analyzer 最终：No issues found。
- UI contract：PASS（17 components, 330 screens）。
- 独立审查：先规格符合性、后质量/安全审查；发现的问题经两次定向复查关闭。未引入业务资金写入或明文外传。
- 总门禁最终 `Verification: PASS`。Infra 102、Getui 28、Matrix Bot 9、后端 1,400、移动端边界 66 项通过；34 项后端环境相关跳过。UI contract、迁移离线生成、OpenAPI drift 和 Compose render 通过。已有 Starlette/Pydantic 弃用提示记录在输出中，未隐去。移动端边界扫描耗时 493.30 秒。
- Figma 远端工具不可用，未修改远端节点。更新了 `frontend/artifacts/figma-state.json` 和 `packages/ui-contracts/changliao-component-registry.json` 的本地修订记录；不能视为远端设计同步完成。

## 安装策略

设备：Redmi Note 7，adb serial `cbd0156b`。原包 `com.liuhetong.mobile` 为 0.3.73-debug / 2077，证书 SHA256 `34999c8b561affc263f11df0a3865e8c03c0386997a8c37bd12110380e5bc1f1`，不同于 runbook 的固定签名，故不卸载、不清数据。

源码提供仅 debug 可用的 opt-in `chatflowParallelDebug=true`。交付 `com.liuhetong.mobile.debug`，显示名“畅聊 Debug”，0.3.74-debug / 2078，与旧包并存。新安装需要用户自行登录；旧包数据完整保留。build command 使用显式 `--android-project-arg=chatflowParallelDebug=true`；环境变量方式未生效的产物被包名门禁拦截，没有安装。

构建保留三个 HTTPS dart-define。按 Apktool 2.12.1 完整解包/重建、build-tools 36.0.0 `zipalign -P 16 -f 4`、用户规定固定证书签名，再重解包核对 smali、manifest、全部 native/Flutter assets；debug 门禁确认单 ARM64 ABI、debug kernel、debuggable 标记及版本身份。运行记录位于 `artifacts/2026-09-10/mention-history/delivery-apk/`。

交互体验由用户本人在真机验收；自动测试不代替真实网络条件下的流畅度判断。

## 最终产物及设备证据

- APK：`artifacts/2026-09-10/mention-history/delivery-apk/final.apk`，140,957,761 bytes。
- SHA256：`6f95c3f012dc0f6570c009ac67dde1761e1f062cfa944cbd6e71fca2a04445a9`。
- 固定证书：`75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff`；签名和签名后对齐通过。
- 原始/重建各 24,912 个类，smali 核对无变化；332 项 native/Flutter assets SHA256 一致；manifest 语义一致，resources 和 DEX 已重建。
- `adb install -r`：Success；设备查询为 0.3.74-debug / 2078，debug 包与旧主包同时存在。
- 第一次 `am start -W` 等待 10 秒超时；随后确认新包进程 PID 17409 存活、MainActivity 为 `mResumedActivity`，读取最近 AndroidRuntime 错误通道无异常。未替用户登录、发送消息或操作聊天记录。
- 源码产物未误安装；环境变量未生效的并存候选被包名校验拦截，交付使用显式 Gradle 参数生成的最终重建包。
