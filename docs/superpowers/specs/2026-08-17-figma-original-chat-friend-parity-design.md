# 畅聊原始 Figma 聊天与好友页一致性修复规格

**状态：** 已批准  
**日期：** 2026-08-17  
**设计源：** Figma `zpzwTbnj1hqx80tyRygX78`  
**权威节点：** Chat `36:1287`，好友资料 `35:63`，补充状态 Gallery `107:3`

## 1. 决策

采用“A．原始节点严格映射”。原始模块画板是布局、尺寸与颜色的权威来源；Gallery 只能补充原始模块缺失的交互状态，不能替代或改写原始节点结构。

## 2. Chat 页面

- 浅色聊天页面背景固定映射 `color/page/background = #EDEDED`；状态栏、导航栏、输入栏映射 `color/surface/primary = #F7F7F7`；输入表面映射 `color/surface/elevated = #FFFFFF`。
- 输入栏继续保持语音、输入表面、Emoji、更多/发送的已批准顺序，但颜色、分割线和垂直位置必须与原始 Chat 画板一致。
- Chat 与好友资料是全屏详情页；进入后必须覆盖根 TabBar，不能在页面底部继续显示首页“消息 / 通讯录 / 发现 / 我”导航。
- 更多面板为 393px 宽、四列网格，包含图片、拍摄、语音通话、视频通话、红包、文件。每个单元必须给图标、间距和标签明确高度，不依赖默认正方形网格比例；393 × 852 与系统文字缩放下均不得 overflow。
- Emoji 面板只保留“最近 / 全部 / 我的表情”与内容网格。删除开源选择器默认提供的搜索按钮和删除/退格按钮。

## 3. 好友资料

严格映射节点 `35:63` 的内容顺序和尺寸：

1. 44px 页面导航；
2. 126px 白色身份卡，16px 水平内边距、24px 垂直内边距、72px 头像，正文包含昵称、畅聊号和在线状态；
3. 12px 模块间隔；
4. 120px 朋友圈模块，左侧 80px 标题区，右侧三张 87 × 88px 预览；
5. 24px 上下、16px 左右操作区，三个 361 × 48px 纵向按钮，间距 12px，顺序为发消息、语音通话、视频通话。

页面按内容自然增高，基准画板保留原始 393 × 980 高度；Flutter 小屏视口使用可滚动布局，不压缩原始间距。

## 4. Figma 状态归档

在现有文件的 `20 Messages & Chat` 模块区域内正式放置并命名独立 393 × 852 Frame：

- `chat-more-panel-original-mapped`
- `chat-emoji-recent-original-mapped`
- `chat-emoji-all-original-mapped`
- `chat-emoji-custom-original-mapped`
- `message-action-menu-original-mapped`

这些 Frame 使用原始 Chat 的 `#EDEDED / #F7F7F7 / #FFFFFF` 层级和输入栏结构。普通文本消息菜单不显示“添加到表情”；图片/GIF 菜单才显示该项。

## 5. 验收

- Widget 测试断言 Chat 背景为 `#EDEDED`。
- 从 Tab 页面进入 Chat 或好友资料后，根 TabBar 不得继续可见。
- 更多面板在 393px 宽和 1.3 倍文字缩放下无 Flutter overflow 异常。
- Emoji 面板不存在搜索与退格按钮。
- 好友资料断言 72px 头像、在线状态、三张 87 × 88px 朋友圈预览和三个纵向 361 × 48px 操作按钮。
- Figma 截图确认新增状态位于原始消息模块区域且不存在裁切。
- `dart format`、`flutter analyze`、目标测试、完整 Flutter 测试、仓库验证脚本、Debug APK 构建通过；APK 重装至当前雷电模拟器并记录证据。
