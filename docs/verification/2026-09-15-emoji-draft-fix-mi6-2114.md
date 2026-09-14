# 2026-09-15 emoji 草稿阻断进入修复与 Mi 6 Debug 2114 交付

## 现象与根因

用户报告：会话内最后一次输入 emoji 或文字混杂 emoji，退回“消息”页后无法再点击进入该会话。

代码级分析定位到两处相互叠加的静默失败（均在消息页 `_openRoom` 的路径上）：

1. `_restoreDraft` 无兜底：草稿读取/恢复一旦抛出（存储损坏、非预期数据形态），异常沿
   `unawaited` 冒泡未处理，RoomPage 初始化中断，页面无法完成打开。
2. `_openRoom` 的 `finally` 中 `await lease?.cancel()` 无保护：cancel 抛出会跳过
   `_openingRoom = false` 复位，此后消息页所有会话点击都被该守卫静默吞掉——正是
   “反复点击也不能进入”的机制；Mi 6 探针曾证实存在 `_openingRoom` 卡死窗口。

## 修复（commit 前后两个提交，源码 `2e5fe3aa`+）

1. `_restoreDraft` 整体 try/catch：任何异常丢弃该草稿（输入框为空、写入空草稿覆盖坏数据），
   会话照常进入——草稿永远不阻断导航。
2. `_openRoom` finally 中 `lease?.cancel()` 包 try/catch：保证 `_openingRoom` 必然复位，
   守卫不再可能永久卡死。
3. 新增 emoji 草稿回归测试：混合 emoji（非 BMP 代理对 + ZWJ 家庭序列 + 旗帜）完整往返；
   损坏负载读取返回 null 不抛（模拟重启后读到坏数据）。

## 自测与交付

- Flutter 全量 **2671 通过**（新增 emoji 草稿往返/容错用例）；analyze 零问题。
- 0.3.90-debug/2114 固定流程（Apktool 2.12.1 + zipalign 36.0.0 + 固定证书 `75b31c66…`），
  aapt 验证 `com.liuhetong.mobile` 2114/0.3.90-debug arm64。
- 最终 SHA256：`BFA730D916AABB67A0E5FFD47E8894837124F056E4DEC5794D29639C420FC554`
- Mi 6（cbd0156b）root 覆盖安装 Success（数据保留），读回 2114/0.3.90-debug，已启动；
  真机验证“输入内容→返回→再点会话”可正常进入（superJJ 会话实测两轮）。
- 未发布：仅 Mi 6 交付；服务器/更新弹窗/iOS 不变。源码已推送（`185b6850`），记录推送 `本提交`。
