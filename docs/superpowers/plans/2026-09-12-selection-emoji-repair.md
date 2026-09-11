# 消息选择与动态 emoji 输入修复计划

用户2026-09-12明确指定行为并要求Debug安装Mi6；以该交互规格作为批准范围，无需重新确认同一设计。Astra负责定位/设计/实际diff审查，明确gpt-5.6-terra实施。仅客户端与HTML演示，禁止生产部署/推送Git/金融及E2EE变更。

基线13d52ce5，独立当前仓库工作树.worktrees/select12，保留main现有改动。开始01:50+08。证据docs/verification/artifacts/2026-09-12/selection。

## 设计与根因待验证

- S1 菜单/选区仅一个会话控制：避免两个全屏overlay互相挡住菜单或吞掉pointer up。以原始pointer生命周期结束拖动，菜单状态idle/dragging/settled/dismissed，cancel和dispose清理一致。
- S2 手柄视觉线高等于文字行高、圆点恢复12；独立44以上透明触区，不用拉长视觉来扩大触区。移动镜片但焦点指向指尖覆盖文字，坐标统一到overlay并补边框偏移/安全边界。
- S3 富文本消息WidgetSpan索引与源文字UTF16之间需显式映射；映射字素及已有[表情名]边界，部分复制/引用/转发使用源文本substring，复制复用emojiToShortcodes。
- E1 输入WidgetSpan占1 UTF16而emoji可能2/多个码元；现有控制器仅吸附边界不能解决显示/IME偏移差异。优先保持EditableText原文UTF16文本布局，再在真实emoji矩形上覆盖动态字形，保留彩色动画与IME，不把输入正文替换占位符。实现前用真实EditableText证明反例；不可仅用controller setter自测。

## 分工/顺序

- [ ] E1 Terra emoji：仅emoji_text_controller.dart、wechat_composer.dart/chat_composer_bar.dart、必要新emoji编辑装饰文件、相应专属tests。不得修改room_page.dart/message_text_selection.dart/emoji_text.dart。先红后绿；保持文本原值、IME composing、光标、撤销、发送接口；多emoji开头+中文/英文/删除/中间插入/选区替换/换行/ZWJ实测自动化。提出更好方案先报Astra。
- [ ] S1-S3 Terra selection：仅message_text_selection.dart、room_page.dart、必要专属offsetmap/helper、专属selection tests。不得修改emoji controller/composer。完整原菜单与4项局部菜单共用MessageBubbleMenu；全选恢复且不创建第二session；pointer up/cancel立即去镜片；大触区/小视觉；滚动/空白/发送/切换取消；文字范围映射与引用/转发实际调用链。
- [ ] U1 两批源代码完成后Astra审查，再由Terra串行更新HTML demo/registry/token及运行契约；不能两个代理改同文件。图形style采用已有token，Figma退役。
- [ ] V1 聚焦tests、analyze、最终Flutter全量；预检verify.ps1后按影响复用未变金融/服务端门禁，公开29既有钱包失败。所有新相关失败必须修复。
- [ ] D1 核对Mi6实际包/签名/版本，选新build；最终源码normalpub+ARM64Debug+Apktool2.12.1+zipalign+固定签名+语义验证，显式--android-project-arg=chatflowParallelDebug=false；install-r不清数据不降级。用户手工验收，记录包SHA及实际installed身份。

Flutter工具单槽：先E1运行，S可写tests但执行需交接。根审查同时推进打包预检和文档，不运行冲突工具。
## 审查追加的S3实施边界
现存视图替换未接通真实发送，新增任务S3b：由Terra selection独占必要Matrix interaction/lease/timeline viewmodel与专属tests，局部转发显式发送选中文字到目标加密房间；局部引用将片段保存在加密事件的项目命名空间字段并保留原event anchor，客户端解析/本地echo/接收/重进后优先显示片段。不修改E2EE算法、鉴权、业务金融接口。验证实际payload、full路径不变、selected quote解析/模型复制/更新以及UI显示，不接受仅预览测试。
U1改由Terra emoji独占frontend/registry，S专注上述链路；两个执行者不得编辑相同文件。
