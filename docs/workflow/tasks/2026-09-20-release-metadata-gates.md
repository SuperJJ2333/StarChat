# 发布流程轻量加固

用户授权：2144签名问题已解决；加固流程，不下载安装包验包，删除耗时最长步骤。此确认来自用户，不写成技术复验。
计划：docs/superpowers/plans/2026-09-20-release-metadata-gates.md。
工作树 codex/release-metadata-gates，基线eecdf525；文件所有权 scripts/release_metadata.py、legacy发布脚本、元数据CI、相关测试和4份入口runbook、新release-metadata.md。无移动端/服务端业务代码修改。

## 交付
- 统一release JSON驱动iOS官网/下载链接/XML和两端设置；XML序列化及实际解析。
- HEAD检查包大小和可访问性；元数据GET上限256KiB；无APK/IPA GET。
- 服务器发布加锁、0700持久备份、漂移检查、静态验证失败自动回退；检查通过才调用SettingService，单平台审计更新，保留minimum/notes。
- 旧release.ps1/release_ci.ps1要求SkipPublish，旧publisher和server-pull --publish停止写设置；删除重复整包回拉下载和aapt复验，原始构建/上传完整性不删除。
- 新CI只运行测试与可选只读公开元数据检查；不发布弹窗、不启动移动构建。

## 验证
先RED：新模块不存在导致契约测试失败；实现后专项14通过。mobile+enterprise相邻87通过（1.21s）；网页安装入口6通过（0.11s）；两项仓库策略通过，PowerShell AST通过，git diff检查通过。
旧enterprise测试要求已废弃文案“安装验证中”，本轮改为实际安装按钮及不卸载提示约束；没有修改页面来迎合旧断言。
verify.ps1前置检查：独立worktree无.env；该脚本配置渲染依赖.env，未启动全仓耗时门禁；本轮无业务API/Flutter变化，未重跑构建和业务全量，不能宣称全仓verify通过。
规格复核：用户三类加固和取消整包回拉已覆盖；安全复核：固定HTTPS站点、受限URL、单平台键集、最小写入、审计、备份/回退、无管理员token伪造、无签名强行通过。
限制：发布人签名交接是人工确认；HEAD不是完整文件内容验证。后台人工设置不被这个CLI拦截，应使用新入口；本轮未改后台服务。真正安装结果仍由设备反馈。

## 计时与状态
2026-09-20 Asia/Hong_Kong执行；细分人工时间未精确计量。未下载安装包、未修改生产弹窗/包/版本。下一步：提交整合，并将新脚本作为后续发布入口；首个实际版本发布按新文档执行，不为验证流程自行发布2144。
