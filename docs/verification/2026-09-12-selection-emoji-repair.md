# 2026-09-12 消息选区与动态 emoji 输入修复

状态：实施与验证中，尚未交付新版 APK。

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

## 待填最终证据
- 定向测试、全量 Flutter、分析、HTML 契约及行为测试：待冻结后补入实际结果。
- scripts/verify.ps1：配置渲染阶段缺少隔离工作树 .env，exit1；未复制生产秘密。通过的前置 policy/template gate不能替代后续门禁。
- APK source→Apktool2.12.1→zipalign36→既有固定签名→清单/DEX/资产语义验证：待执行。
- Mi6 install-r、实际包版本/证书/哈希/firstInstallTime：待执行。
- 微信级真实拖动手感、多端双方显示以及设备输入法效果：由用户真机验收，不以 widget 测试代替。

## 相关记录
- [实施计划](../superpowers/plans/2026-09-12-selection-emoji-repair.md)
- [任务与审查台账](../workflow/tasks/2026-09-12-selection-emoji-repair.md)
- 原始日志目录：artifacts/2026-09-12/selection/
- Figma 已退役：本次仅更新 frontend/index.html 的 ?screen=chat-selection-active HTML demo。
