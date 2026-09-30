# Android 正式诊断增量及更新弹窗

## 恢复入口

- 用户授权：“请你推送Android版本的更新弹窗，部署新版本更新”。正式Android/ARM64下载别名及更新三键审计；沿用已批准修复和诊断设计。
- [计划](../../superpowers/plans/2026-09-27-android-public-diagnostics-update.md)。worktree network-failure-diagnostics，移动冻结f433381a、1779项；root拥有版本/工件/发布/文档，agent只读review。
- 当前：**0.4.19/2188已于2026-09-27T22:14:48.550551+08:00正式发布，更新弹窗设置生效**。签名/上传/双侧HTTPS/三审计/17生产容器及平台隔离通过。
- 下一步：用户设备启动/恢复或关于页检查更新获取新包；真机弹窗/安装及K80功能反馈单独验收。授权发布范围已完成。

## 验收台账

| ID | 预期 | 实际证据 | 缺口 |
| --- | --- | --- | --- |
| D01 | 验证码拒绝/锁屏/消息性能与历史索引/请求失败诊断 | 1777冻结输入不变，仅版本两项；实际新libapp和固定诊断标记核对 | K80真机体验待反馈，历史2184原因仍未知 |
| D02 | ARM64 release、固定签名、版本递增重建 | 最终aa402236aa2dbf06c5322358c6f8ad66e50f06ab5487bc08871ae34934d5e220，81,505,310bytes；所有正式门禁/独立spec→security PASS | 未真机安装，不用Debug代替正式检查 |
| D03 | 不可变APK/ARM64别名/更新弹窗三键审计 | ANDROID_PUBLICATION_PASS/PUBLISH_PASS，三成功审计，最新平台投影正确 | 已运行设备需触发下一次检查 |
| D04 | 平台/其他ABI/static/runtime保持与TLS | iOS2173/minimum3/notes保持，17生产容器/0090保持；8公网探针/隧道清理PASS | 不伪造生产JWT，不将直接投影当已登录HTTP成功 |

## 版本、测试与时间

源码f433381a，manifest263f9499…0054、锁314504b9…76bf3；版本Python31/Flutter21、包装器20，独立先规格后安全与最终工件/发布复核PASS。正式源/最终release、非debuggable、固定75b31c签名、对齐、smali/资源/manifest/资产/锁屏边界通过。共享完整门禁复用[诊断任务](2026-09-27-network-failure-diagnostics.md)，原全量exit1和影响闭环保持，未冒称重跑全绿。

构建完成2026-09-27T22:08:09.8157502+08:00；首轮开发注册失败、纠正后成功；外层相对计时文件失败已按绝对路径闭环，准确构建总起点未知。上传2026-09-27T22:10:43.9723472+08:00→2026-09-27T22:12:42.8681610+08:00，发布2026-09-27T22:14:33.7835324+08:00→2026-09-27T22:14:50.1074679+08:00，工作站2026-09-27T22:16:51.2739646+08:00→2026-09-27T22:16:53.6252483+08:00，均exit0。首次MIME假设失败保留，生产旧/新均octet-stream/no-store，验证闭合修正后8探针通过，无重复发布或生产修改。两轮隧道关闭。具体工具/hash与计时见[发布报告](../../verification/artifacts/2026-09-27/android-public-diagnostics-update/server-publish/report.md)。

## 交接与回退

APK及安全证据在docs/verification/artifacts/2026-09-27/android-public-diagnostics-update，完整构建/解包在E mirror android-release/run-20260927-220400。0700备份/opt/starchat/docs/verification/artifacts/2026-09-27/android-public-diagnostics-update-2188-20260927T141437Z；SettingService三个审计键和别名分阶段CAS恢复，保留旧2185包和审计。无API、迁移、iOS或Git远端推送。本轮未替换/删除已有编译junction；独占缓存复用，正式工件独立保存。
