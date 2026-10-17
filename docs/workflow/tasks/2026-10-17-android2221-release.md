# Android 2221 普通更新发布

用户授权：2026-10-17「好的，请你推送Android新版本更新弹窗」。发布已验收的冷启动反馈修复0.4.52+2221 ARM64正式包及普通更新；保留iOS、最低支持版本与其他服务。

工作树 interactive-cache-startup，产品45355d5f，构建HEAD f409de3c。Root拥有构建、发布脚本和交付文档；按既有批准计划独立SPEC→QUALITY审查后由root发布。所有证据位于docs/verification/artifacts/2026-10-17/android2221-release/。不更改产品源码。

验收：REL-01 固定75b31签名ARM64源码构建及常规重建门禁；REL-02 真实共享/原生证据按变化范围复用并保留历史失败/限制；REL-03 新鲜生产基线、精确不可变APK/CDN/静态/设置CAS及审计；REL-04 公开HEAD/元数据与十设置、35容器保留；REL-05 源码精确回填及清理。

20:38+08：已启动ARM64源码构建，HK只读快照确认Android2216、iOS2215、minimum3、schema0095、35容器、新2221对象不存在。SG基线采集中。未执行生产写入。完整全仓verify仍缺本地.env；不导入生产秘密。

已知限制：旧K80安全软件告警未确认解决；既有libcrypto 16KiB限制不作修复声明；ARM64真机和旧客户端弹窗人工观察尚未覆盖。旧Debug/API28原生证据不等同ARM64真机。

当前已完成发布和后验，下一步是用户用低于2221的正式Android客户端观察普通更新弹窗；已装2221Debug不重复提示。没有待执行的生产写入。

20:47+08：REL-01完成，构建12:38:19.347–12:47:24.030UTC，9分4.684秒，20steps全部exit0。正式包73,524,314B，SHAab4652c05c3d1b1cef7a001ce542ba21a22103b7dd5fd6e709d3efc759b9e572，packagecom.liuhetong.mobile，arm64-v8a，固定75b31签名。源/重建native及Flutter资产一致；13非app原生库与2216逐字节相同，新libapp静态LOAD16KiB检查通过，旧libcrypto问题仍在。

REL-02按不变输入复用：原全量6134PASS/9SKIP/2FAIL exit1保留，29fixture修正、15final+41未变覆盖、fullanalyze0与五场景nativePASS。冻结包f08eeb715dce7e2047de013f996bc0bc1b9c3878ae263e282da2998592a30e8a，源码HEADf409de3c/mobile同45355；独立审查中。发布脚本35专项PASS；前次2FAIL为旧测试期待17规则/2215链接，已按新鲜19规则/2216基线校正，运行时断言未放宽。原PG6例仅在事务源码/四实际依赖/schema精确相同闭包下复用，未新跑PG。

源码回填第一次prepare拒绝primary版本registry漂移：primary仍2213，工作树和生产均2216；download.html两边与生产一致。原失败目录保留；local-backfill-r2精确锁定primary旧文件hashd551fb5d…d83d63及2213身份，备份后仅在生产publish/audit确认后同步2221。不是放宽生产CAS，也未动任何其他用户改动。

## 最终验收与计时

| ID | 结果 | 证据 |
| --- | --- | --- |
| REL-01 | PASS | arm64-final20步骤，固定75b31成品SHAab4652…9e572 |
| REL-02 | PASS限定覆盖 | gates三报告；历史失败和真机限制保留；独立SPEC→QUALITY通过 |
| REL-03 | PASS | runtime新鲜检查20:50:16；5块上传20:52:06、合并20:52:08；不可变落盘20:52:11；CDN提交20:52:30、Deployed/HEAD20:53:13；alias20:53:30、publish20:53:44、audit20:53:47（均+08） |
| REL-04 | PASS | public-check/public-receipt.json全部true；postflight20:54:21保留35容器/schema/guards/旧APK/十设置，备份0700 |
| REL-05 | PASS | local-backfill-r2/applied.json，两文件/两工作区CAS；自建隧道停止，W映射清理 |

构建工具9分4.684秒；其间基线/脚本/证据准备并行，不累加计时。独立审查12:49:00→12:49:32UTC。生产阶段20:50:16→20:54:21+08约4分5秒；此前准备完整主动时间没有单独精确计时。原始35测试修正前33PASS/2旧期待FAIL记录保留；无产品返工或重复构建。

更新审计trace android2221-startup-20261017-2221；备份/opt/starchat/docs/verification/artifacts/2026-10-17/android2221-startup-20261017-2221，mode0700。旧2216文件未删。若后续回退，先读settings/alias/static/trace并评估客户端已升级事实，不直接降低build或重放本次操作。

最终状态：REL-01至05完成；ARM64真机/旧版可见弹窗等待用户实际观察，不宣称手机已收到。详见[报告](../../verification/2026-10-17-android2221-release.md)。
