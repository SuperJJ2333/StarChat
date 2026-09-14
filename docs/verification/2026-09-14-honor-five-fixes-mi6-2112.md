# 2026-09-14 荣耀50 Plus 五项修复与 Mi 6 Debug 2112 交付

## 修复内容（commit d2b34a9c，0.3.90+2112）

1. **消息页快速点击无法进入会话（荣耀50 Plus/MagicOS 8.0，通讯录与朋友圈入口正常）**：上一轮的等待反馈用了 `showCupertinoModalPopup`——它是路由栈上的 modal；“开 modal→pop→push 房间页”在低端机慢渲染下三者的路由动画同帧竞争，房间 push 被吞（Mi 6 性能好未复现）。修复：改用 `OverlayEntry` 悬浮转圈（不进路由栈），租约就绪先移除浮层再 push，任何路径（成功/失败/异常）都保证移除。
2. **复制调整滑杆漂移/拉不动（低端机）**：手柄用 44px 命中层上的 `Listener`，手指移出命中层后 move 事件被外层 `GestureDetector`（onVerticalDragStart 取消选区）赢走——表现为拉不动；掉帧时事件稀疏+锚点重算产生漂移。修复：`onPointerDown` 时通过 `GestureBinding.pointerRouter.addPointer` 注册全局路由，后续 move/up 全部直达手柄回调，不受命中层与手势竞技场影响。
3. **相册圆圈热区过小（老年用户）**：点击热区从 24px 圆圈扩到**左上角 1/4 格**（56×80 逻辑像素，与滑动多选起始热区一致），圆圈 icon 保持 24px 不放大。
4. **发送方点自己视频报“视频加载失败，请检查网络后重试”**：不是发送问题——发送是成功的；是**回放**路径问题。发送方点击自己的视频要从服务器把刚上传的密文回下载再解密，弱网/大视频常超 30 秒超时。修复：a) 新增发送端本地回读登记（`SentVideoLocalRegistry`）：相册/拍摄视频发送时登记本机压缩产物（`deleteSourceWhenDone:false` 本就保留），点击时按 transactionId（`outgoing-<jobId>-0-n` 与 jobId 对应）命中即零下载直接播放；b) 网络路径超时 30s→120s，重试按钮保留。
5. **视频进度条无法拖动**：原 `CupertinoSlider` 每次 `onChanged` 立即 seek，且 250ms UI ticker 在拖动中持续回写旧位置（低端机掉帧时互相覆盖，表现为跳动/拉不住）。修复：自绘可拖动进度条——按住拖动仅更新预览、ticker 拖动期间暂停回写、松手统一 seek；点击任意位置跳转保留。

## 自测

- Flutter 全量 **2669 通过**（含改写的进度条拖动用例、120s 超时用例、相册热区用例）；analyze 零问题。
- 用户要求无需功能实测，交付 Mi 6 即可。

## 交付

- 固定流程：Flutter ARM64 debug（0.3.90-debug/2112，三项 HTTPS dart-define）→ Apktool 2.12.1 → zipalign 36.0.0 → 固定证书 `75b31c66…` → 语义验证通过。
- 最终 SHA256：`1FB5A61D9C2CD52542C552388BA880BBA5E630BB6CD1E145DF2781918D7AA345`
- Mi 6（cbd0156b）root 覆盖安装 Success，读回 2112/0.3.90-debug；拉回 base.apk 哈希一致，已启动。
- 未发布：仅 Mi 6 交付；不涉及服务器/更新弹窗/iOS。0.3.90+2112 源码已推送（`2ac74982`）。
