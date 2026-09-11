# 2026-09-12 消息选区与动态 emoji 输入修复

状态：本地修复与代码审查完成；0.3.85-debug/2089 已覆盖安装 Mi 6，用户功能验收待进行。

## 范围与复现
- Mi 6 已装 0.3.84-debug/2088：长按含多行文字/emoji 的消息，拖动手柄并松手；检查镜片残留、局部四项菜单、触摸区域及操作内容。
- 在输入框开头输入两个以上动态 emoji，再在其后输入中文/英文、换行或移动光标，观察文字穿插及乱码。
- 用户要求仅安装 Debug 真机自测；本次不部署生产、不推送 Git、不清除设备数据。

## 根因与实际修复方向
1. EditableText 的源 UTF16 坐标与 WidgetSpan 的单个占位符不等长。仅吸附字素边界无法修复 IME 坐标。改为保留源文本布局，在 RenderEditable 的选区盒上绘制动态字形；监听真实滚动 offset，保持 native IME/选区/撤销坐标。
2. 原完整菜单与选择层的两个 Overlay 互相遮挡；恢复原菜单递归创建 session，会被旧会话销毁回调移除。使用单个会话拥有选区、完整菜单和局部菜单。拖动的稳定节点与 pointer 生命周期必须保持，镜片和菜单互斥。
3. 消息气泡仍正确使用 WidgetSpan 展示，因此选择时新增渲染坐标到源 UTF16 的字素/shortcode 映射。视觉手柄与触摸区域独立。
4. 局部转发原先仅替换预览，发送依然通过原 eventId 转发完整消息；改为明确局部加密文本发送路径，完整转发保留原路径。局部引用原先发送只有关联 ID，接收端重载整条；新增密文内容根级片段字段，保留原关联 ID 用于跳转。

## 安全与兼容审查
Astra 读取 Matrix SDK 加密实现：m.relates_to 会被移出密文并附在事件 envelope。因此禁止将片段放入 relation；io.changliao.selected_quote 必须与 body 并列进入密文。业务 API、推送、账本及密钥管理均不接触新增文本。旧客户端不识别新字段时仍保留标准引用关系，可能显示整条原引用，这是跨版本已知差异。

## 实际验证与交付
- 源码：本地分支 codex/chat-selection-20260912，commit 48fe74750ae0272d4659253e12425140f6a565cc，基线 main@1da11922；未推送 Git 或部署生产。
- 定向 Flutter 61/61 通过；完整 Flutter 2374 通过、29 失败，失败身份集合与既有 2088 原始日志完全相同，无新增失败。最终完整 flutter analyze exit0；版本契约 pytest 2/2 通过。
- HTML selection 12/12 通过，UI 契约 28 组件/356 屏通过。完整前端 155通过/11失败；从 main@1da11922 导出真实源码运行基线143通过/11失败，失败身份完全相同。比较记录见 artifacts/2026-09-12/selection/frontend-full-suite-baseline-comparison.md。
- scripts/verify.ps1：前置 policy/template gate通过，配置渲染缺少隔离工作树 .env，exit1；未复制生产秘密，不能声称全仓门禁通过。
- ARM64 Debug 源构建117秒；Apktool2.12.1重建、zipalign36独立复验exit0、固定v2/v3签名通过。27242类语义一致，339 native/assets内容未变，Manifest语义一致。外层打包命令退出码未被执行者保存；记录阶段产物及root独立复核，不虚报外层exit0。
- 最终包：com.liuhetong.mobile，0.3.85-debug/2089，143790379 bytes。SHA256：4cdcfdf524e501e5f73d190b88fd55cad67c29a29b9a1569835f88bdfb5f9634。
- 证书SHA256：75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff，与安装前实机包一致。
- 02:41:57+08 Mi6 cbd0156b 执行 adb install -r，Success/exit0。firstInstallTime仍为2026-09-11 00:42:05；未卸载或清数据。02:42拉回实际安装base.apk，与候选SHA256完全一致；见 mi6-delivery-verification.json、mi6-install-2089.log。

## 关键文件与验收边界
- emoji_text_controller.dart、wechat_emoji_input_decoration.dart、wechat_composer.dart：原生文本坐标与动画覆盖层、滚动及生命周期。
- message_text_selection.dart、message_selection_offset_mapper.dart、room_page.dart：同会话菜单、44px热区/12px视觉手柄、镜片与选区映射、取消路径。
- message_interaction_service.dart、matrix_e2ee_client.dart、room_timeline_controller.dart：选区转发与加密引用片段传输/恢复。
- frontend/src/components/selection.js 与对应注册、样式、12项测试：可操作HTML参考演示；root验证初始6项菜单、跨行部分选择、4项菜单、精确引用和全选恢复。
- 自动用例覆盖实际EmojiText布局、手柄up/cancel、选区映射、发送片段、引用解析/本地回显及输入法坐标、真实输入框滚动和卸载。没有进行用户账号真机功能操作。
- 微信级拖动手感、放大镜逐帧视觉、设备输入法、多端双方显示与弱网效果由用户真机验收；不可用widget测试代替。旧版本客户端可能仍展示整条引用；浏览器demo不是Flutter像素一致性证明。
- HTML仅本地演示，Figma已退役；不发布正式Android/iOS更新。

## 相关记录
- [实施计划](../superpowers/plans/2026-09-12-selection-emoji-repair.md)
- [任务与审查台账](../workflow/tasks/2026-09-12-selection-emoji-repair.md)
- 原始日志目录：artifacts/2026-09-12/selection/
- Figma 已退役：本次仅更新 frontend/index.html 的 ?screen=chat-selection-active HTML demo。
