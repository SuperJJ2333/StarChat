# 2026-10-23 主工作区资料整合

用户批准：冲突文件以候选发布分支正文为维护入口，主工作区独有修订以本目录 patch、哈希和保全提交留存。所有补丁由候选原文指向主树原文，仅用于历史证据还原，不应直接覆盖现行状态。

## 使用方式

先从 `8535e07f98e27047251f4f2c78202c24ad31a304` 提取对应文件至独立目录，再应用相应 patch；验证 `manifest.json` 的 LF SHA256。原始 Windows 字节及全部 78 份文件另有本任务本机 `main-before.zip` 和 SHA256 清单。实际保全提交与整合提交记录在本轮验证报告中。

## 必须保留的判断

- Android 正式发布仍为 0.4.64 / 2233，APK SHA256 `77c17e4c96b24569690a80f1954f00acb267b01b407941ffe2b95c51621bf573`，固定 75b31 签名身份。
- iOS 已发布工件仍为 0.4.46 / 2215、SHA256 `4087d408f5e294fe2482a6ccebef65bc0aeb73123cab25fb5a4547ad8ebd7aba`。严格签名校验曾失败，随后用户批准发布该确切文件；不能改写为严格签名通过。
- 2217 杀软反馈仍未解决；用户要求保留复核材料、不外发。不得因维护而重新上传包、提交申诉或恢复已撤回的 2221 发布。
- 历史本地/原生/设备/生产观察应按各记录区分；修复门禁不等于对新版本进行发布或真机验收。

## 差异索引

| 原路径 | 主树修订补丁 |
| --- | --- |
| `docs/workflow/current-state.md` | [00.patch](00.patch) |
| `docs/adr/2026-10-17-bounded-encrypted-startup-projection.md` | [01.patch](01.patch) |
| `docs/superpowers/plans/2026-10-11-im-reliability-remediation.md` | [02.patch](02.patch) |
| `docs/superpowers/plans/2026-10-17-startup-local-projection.md` | [03.patch](03.patch) |
| `docs/verification/2026-10-11-e2e-architecture-performance-review.md` | [04.patch](04.patch) |
| `docs/verification/2026-10-11-server-runtime-followup.md` | [05.patch](05.patch) |
| `docs/verification/2026-10-16-android2216-release.md` | [06.patch](06.patch) |
| `docs/verification/2026-10-16-mobile-experience-2216.md` | [07.patch](07.patch) |
| `docs/verification/2026-10-16-super-emoji-autoplay.md` | [08.patch](08.patch) |
| `docs/verification/2026-10-17-startup-feedback.md` | [09.patch](09.patch) |
| `docs/verification/2026-10-17-startup-local-projection.md` | [10.patch](10.patch) |
| `docs/workflow/tasks/2026-10-16-android-antivirus-review.md` | [11.patch](11.patch) |
| `docs/workflow/tasks/2026-10-16-android2217-candidate-download.md` | [12.patch](12.patch) |
| `docs/workflow/tasks/2026-10-16-interactive-cache-startup.md` | [13.patch](13.patch) |
| `docs/workflow/tasks/2026-10-16-mobile-experience-2216.md` | [14.patch](14.patch) |
