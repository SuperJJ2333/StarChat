# 2026-09-15 会话切换 5 秒阻塞根因修复与 Mi 6 Debug 2116 交付

## 现象

用户输入文字（如“你好”）后退出到消息页，再点任意会话无法立即进入，需等待 5 秒以上。
与此前 `_openingRoom` 卡死同源但机制不同——本次守卫**总会复位**，但要等很久。

## 根因（Mi 6 探针实测计时）

探针数据显示退出会话后租约取消总耗时 **6878ms**：
- `lease.cancel()` 进入 Matrix 客户端的生命周期**串行队列**（`_serializeLifecycle`），
  排在会话页销毁期间积压的全部生命周期操作之后（emoji vault 会话关闭、提醒服务
  flush、语音清理、同步停止等——输入过草稿/打开过面板的操作越多，队列越长）；
- 队列轮到后还要执行 `detach()` 的 owner drain（实测 ~606ms）。
- 而 `_openRoom` 的 `finally` 是 `await lease?.cancel()` 之后再复位 `_openingRoom`，
  于是这 6.9 秒里守卫一直为 true：用户点下一个会话被静默吞掉，直到取消完成才能进。

## 修复（commit 36c3e6f3）

`_openRoom` 的 `finally` 不再 await 取消：租约 cancel 转为后台任务（异常吞掉——
取消失败不影响新会话；房间生命周期由 Matrix 客户端侧的串行队列自身保证安全），
`_openingRoom` 在页面关闭（`navigator.push` 返回）后**立即复位**。

## 自测与交付

- 新增场景验证（probe5 真机）：输入文字→返回→立刻点下一会话——open start 与
  进入均无 5 秒等待，守卫即时释放； Flutter 全量 **2673 通过**；analyze 零问题。
- 0.3.90-debug/2116 固定流程（Apktool 2.12.1 + zipalign + 固定证书 `75b31c66…`），
  aapt 验证 `com.liuhetong.mobile` 2116/0.3.90-debug arm64。
- 最终 SHA256：`211BF94009660C5CF14A3E9F5DD133B94B9E78B46E59152DFFBA6CB9E82561FC`
- Mi 6（cbd0156b）root 覆盖安装（数据保留），读回 2116/0.3.90-debug，已启动。
- 未发布：仅 Mi 6 交付；服务器/更新弹窗/iOS 不变。源码已推送（`c2745c56`）。
