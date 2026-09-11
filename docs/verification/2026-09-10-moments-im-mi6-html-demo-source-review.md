# Mi 6 图片编辑、图库与朋友圈 HTML demo 交接

日期：2026-09-10，Asia/Hong_Kong。工作树 `codex/moments-im-mi6-20260910`。授权见本次 moments-im-mi6 计划；本分工未运行 npm/Flutter/合同测试、analyze、构建或浏览器交互测试。精确阶段起止时间未记录，耗时未知。

## 演示入口

打开 `frontend/index.html` 的目录，按以下 screen ID 选择：

- `chat-image-editor-ready`：底部五工具画笔/表情/文字/裁剪/马赛克，右上撤销/重做，右下完成。
- `chat-image-editor-complete-sheet`：完成后的转发/保存到相册/收藏菜单。
- `chat-image-editor-loading`、`chat-image-editor-error`：打开过程与失败状态。
- `chat-image-gallery-ready`：当前聊天的三张本地示例图片，横向滚动/键盘翻页、编辑入口。
- `moments-detail-own-comment`：自己的评论短按不弹菜单，长按或右键显示单个复制删除菜单。

`frontend/src/components/image-editor.js` 新增 AppImageEditor/AppRoomImageGallery。Canvas 使用程序绘制的本地风景插画作为演示素材，无外部图片下载；五工具实际修改画布，历史快照实现 undo/redo。完成保存导出实际 PNG；转发/收藏生成 Blob 并发出 demo 事件，界面明确标注演示，没有伪称连接生产账号。取消恢复原始画布，图库编辑取消返回原图。

## 对齐与登记

`packages/ui-contracts/changliao-component-registry.json` 新登记 `WeChatImageEditorPage`、`RoomImageGalleryPage` 的文件/props/states/HTML 标签，screen expectedCount 从332调整为338。`contracts.js`、`register.js`、`screens.js`、`screens/messaging.js` 配套登记。

`components.css` 复用既有颜色、间距、字号、圆角、touch size 与 overlay token；风景插画颜色是素材像素，不是新的 UI token。`components/moments.js` 补充自己评论的长按/右键菜单与复制/删除演示；`screens/moments.js` 移除预先叠加的评论 sheet，避免短按菜单的旧示例。

Figma 已退役：本次变更仅更新 HTML demo（frontend/index.html），没有新增 Figma 登记，既有历史 keys 未做无关清理。

## 证据与限制

仅源码审查，未运行测试、页面渲染或交互验收，未宣称视觉或功能通过。尚待用户查看编辑导出、移动端长按、图库滚动和小屏布局。生产版真实网关在 Flutter 的现有发送/收藏/相册路径中由 root 交付，本 HTML 仅使用演示事件。
