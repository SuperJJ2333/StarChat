# “按住说话”交互反馈与页面布局精准优化 — 验证证据（2026-08-30）

依据微信“按住说话”参考图（文件传输助手会话截图）完成四项优化。发布：**0.3.12+15**。

## 1. 布局与显示时机

- **根因（左侧 1/3 割裂）**：覆盖层作为 Stack 非定位子项参与布局，Column 宽度收缩至最宽子项（取消区 168px），毛玻璃只覆盖了屏幕左侧一条——正是用户看到的“左三分之一割裂”。
- 修复：调用处改为 `Positioned.fill`，覆盖层根节点显式 `width/height = double.infinity`，毛玻璃与内容铺满全屏。
- **对齐参考图布局**：居中绿色圆角气泡（CustomPaint 波形纹）+ “松手 发语音”提示（截图同款文案逻辑）；底部左右两大圆角目标区铺满宽度——左“取消”（武装态高亮）、右“滑到这里 转文字”（转文字为规划中能力，当前滑入松手会取消发送并提示“语音转文字即将上线”，不做假功能）；附实时时长 `n″/60″`。
- **显示时机**：控制器 `start()`（覆盖层同一帧渲染）先于音频启动与权限请求执行，页面不等待任何音频回调。

## 2. 按钮与键盘切换

- 语音模式行布局改为：**键盘图标（左） → “按住说话”（Expanded） → 表情 → 更多/发送**；文字模式：**麦克风（左） → 输入框 → 表情 → 更多/发送**。
- 点击键盘图标即刻切回文字输入（展示输入框，可拉起系统键盘）；再点麦克风即刻回到按住说话——回调为同步 setState，无异步等待。
- 测试：`tapping the mic button switches to the hold-to-talk field`（点击路径）+ `voice panel replaces...`（面板内布局）+ `voice panel hides send...`（语义）。

## 3. 图片模块分段加载

- 根因：`loadDeviceGalleryPhotos(limit: 600)` 一次性取 600 条并**串行解码**全部缩略图。
- 重构为 `DeviceGalleryPager` 分页器：`getAssetListRange` 按页取数，每页 **20 张**、缩略图统一 **200px** 解码；相册耗尽自动停止。
- `ImagePickerPage`：首屏仅加载第一页；网格滚动到距末尾 4 项时**帧末预取**下一页（postFrameCallback，不在 build 期 setState）；底部“加载中…”转圈+文字提示；加载异常静默降级为可继续浏览。
- 测试：`gallery loads 20 per page with loading footer and prefetch`（首屏 20 张、预取触发、第二页追加与提示消失），分页器逻辑用 FakePager 注入验收。

## 4. 拍摄功能处理

- 原流程“拍了直接发”无预览。新增 `CapturePreviewPage`：拍摄完成进入预览，**页面仅展示 200px 缩略图**（`instantiateImageCodec` 定向解码），原图不加载。
- 点击缩略图进入大图查看：
  - 左下角“**查看原图 xxK**”——xxK 按拍摄文件实际字节数动态显示；点击前仅占位缩略图，点击后按需读取原图并切换展示（按钮变为“已展示原图”）；
  - 右下角“**下载**”（photo_manager 存入相册，带权限失败提示）与“**转发**”（底部弹层选择目标加密会话，逐会话加密发送）两个圆形操作按钮；
  - 右上角“发送”回传会话页加密发送（拍摄参数 maxWidth 2160 / quality 92）。
- 测试：`capture_preview_page_test` 2 项（三操作按钮就位与大小回退；点击按需加载原图，文件 IO 走 runAsync）。

## 回归与发布

- 触达测试 26 项（overlay/controller/composer/picker/capture）全过；全量 `flutter test` **439 passed**；`flutter analyze` 零问题。
- 0.3.12+15 三架构签名 APK 上传（arm64 SHA256 `008FE2CFD85E5D430BF5C04E30255B0BA8163CE1D85655D666B890BC8BFB7A26`，服务端比对一致；55.0MB）；更新设置（幂等键 `app-update-publish-0.3.12-20260830`）确认下发；外部验证 PASS。
- 已知边界：右下“转文字”为占位目标区（无 ASR 能力），滑入松手会取消发送并明确提示；后续接入语音识别后在此处扩展。
