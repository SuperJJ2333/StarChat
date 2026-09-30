# iOS 2189 新团队包直接替换下载入口实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 将用户回传的 `畅聊 ChatFlow (13).ipa` 设置为官方 iOS 下载页和 OTA 清单的唯一当前包，保留旧不可变包作为回退，不触发已安装 2189 用户的更新弹窗。

**Architecture:** 复用现有单份 release JSON 发布器。先以新不可变文件名上传并核对本地/服务器 SHA 和大小，再从实时生产页面渲染三份小型静态文件；发布器保存 0700 前态、原子切静态、经公网检查后以 SettingService CAS 对齐 iOS 三项设置。同版本同 build 的设置值预期不变。Android、API、Matrix 与数据库不发布。

**Tech Stack:** PowerShell 7、SSH 跳板、Python 3 `scripts/release_metadata.py`/`scripts/release_settings.py`、HTTPS OTA plist、Business API SettingService。

**用户决策与风险:** 用户先选择只更新下载/安装入口，随后在已获知 Team `ZXB3TS7QD4`→`A9HAF6NT6S`、旧 Keychain 不可由新 Team 读取且可能丢失旧本机聊天后，明确要求“只发布新团队的，直接替换”。旧 Team 已不可用、无外存 Matrix 恢复密钥。`(13)` 的 Bundle ID 与签名 application-identifier 不一致，且没有 iPhone 安装证据；发布完成只证明下载入口及元数据正确，不宣称安装或会话连续性通过。[可行性证据](../../verification/2026-09-28-ios13-migration-feasibility.md)。

**执行结果（2026-09-28 18:24 +08）：** 新 IPA、OTA 和官网直链已切换，旧不可变包及 0700 发布备份保留。发现原网页的旧签名覆盖提示会误导用户，先以 CAS 更正文案，再将警示移至安装按钮前并与按钮关联。质量审查再发现 iOS `install=1` 旧链接可绕过警示；红测试复现后改为停留页内并需主动点击安装。两轮静态修正均使用发布器相同的 `flock` 锁、逐文件 SHA CAS 与 0600 备份。最终页面 SHA `4488a024…d984`、脚本 `a8f27e54…c827`、CSS `0fd42fb3…8ae5`，公网严格 TLS GET 同值，`METADATA_CHECK_PASS`。回退守卫与备份已核对，未触发实际回退。详情见[发布记录](../../verification/2026-09-28-ios13-direct-release.md)。

---

### Task 1: 冻结记录与生产前态

**Files:**
- Create: `docs/verification/artifacts/2026-09-28/ios13-distribution/release.json`
- Create: `docs/verification/artifacts/2026-09-28/ios13-distribution/staged/`
- Update: `docs/workflow/tasks/2026-09-28-ios13-distribution.md`

- [x] **Step 1:** 核对本机 `(13)` 文件大小 `61871675`、SHA256 `a2f8a145c5819ac6fc5488ad19f1c526e60c7fe2a0e6e699109f8520d930a9c0`；复用已留存的包内 Bundle/版本/签名核验，不重复解包或构建。
- [x] **Step 2:** 用 `scripts/starchat-server.ps1 -Action Command` 读取当次生产 iOS/Android 设置、下载页/home JS/manifest SHA、API/worker/PG 容器及 schema，确认 iOS `0.4.20/2189`、Android `0.4.21/2190`，与上一阶段前检差异逐项解释。未知漂移停止发布。
- [x] **Step 3:** 记录 JSON：`platform=ios`、`version=0.4.20`、`build=2189`、`artifact_url=https://www.liuhetong888.com/downloads/ios/ChatFlow-0.4.20-2189-enterprise-a2f8a145.ipa`、`artifact_bytes=61871675`、`bundle_id=com.liuhetong.liuhetongMobile`、`signing_confirmed_by` 写明本次用户签名回传及直接替换授权。
- [x] **Step 4:** 只使用主目录与现网同 SHA 的当前发布脚本 `e555035a…357`，核对服务器现有副本同 SHA。`prepare` 的 root 输入必须是与当次现网同 SHA 的 `frontend/`，输出到上述任务 `staged/`；检查渲染后 Android2190/CDN 与香港线路仍存在、iOS manifest 指向新不可变 URL。

### Task 2: 顺序上传不可变 IPA

**Files:**
- Local source: `C:/Users/Administrator/Downloads/畅聊 ChatFlow (13).ipa`
- Remote stage: `/opt/starchat/releases/ios13-direct-2189-a2f8a145-r1/`
- Remote immutable object: `/opt/starchat/frontend/downloads/ios/ChatFlow-0.4.20-2189-enterprise-a2f8a145.ipa`

- [x] **Step 1:** 在服务器创建本次 0700 stage，检查目标不可变路径不存在或已存在且 SHA/大小完全相同；保持旧 `…6afd6827.ipa` 不变。
- [x] **Step 2:** 经 `scripts/starchat-server.ps1 -Action Upload` 顺序传输到 stage；若单次传输中断，按前缀无覆盖地顺序分块续传，未完成前不清理任何块。服务器 `sha256sum` 和 `stat` 必须与 Task 1 精确相同。
- [x] **Step 3:** 服务器将完整 stage 包以 no-clobber 方式原子放到不可变目标；先严格 TLS HEAD 验证公网 `200` 与 `Content-Length=61871675`，再进入元数据切换。旧文件继续可下载。

### Task 3: 单平台切换与验收

**Files:**
- Local record/publisher: Task 1 JSON 与主目录 `scripts/release_metadata.py`、`scripts/release_settings.py`
- Remote release directory: `/opt/starchat/releases/ios13-direct-2189-a2f8a145-r1/`
- Remote backup: `/opt/starchat/docs/verification/artifacts/2026-09-28/ios13-direct-2189-a2f8a145-r1/`
- Update: `docs/workflow/tasks/2026-09-28-ios13-distribution.md`, `docs/workflow/current-state.md`

- [x] **Step 1:** 上传已冻结的 JSON 与两个 SHA 一致的发布脚本；远端核对 SHA，并再次读取即时静态前态和完整十键设置，确认 Task 1 的 CAS 前提仍成立。
- [x] **Step 2:** 在服务器运行 `python3 release_metadata.py publish release.json --root /opt/starchat/frontend --output /opt/starchat/docs/verification/artifacts/2026-09-28/ios13-direct-2189-a2f8a145-r1`。备份路径必须不存在；若运行异常，先查 0700 备份、静态 SHA、十键设置与审计，再决定安全重试，禁止盲目二次发布。
- [x] **Step 3:** 服务器及工作站分别运行严格 TLS 小元数据检查：新旧 IPA HEAD/长度，manifest XML/MIME/no-store/Bundle/build/新 URL，官网下载 IPA 与 OTA 按钮，iOS 设置仍 `0.4.20/2189` 且指固定安装页；Android2190 的版本、CDN/香港链接、十键设置、容器身份/schema、匿名 401 均不变。执行 `release_metadata.py check` 并记录真实退出码。未接入真机时把覆盖安装、APNs、旧历史读取写为未验证。
- [x] **Step 4:** 若需回退，仅在三份实时静态 SHA 仍等于本次生成值时，从本次 0700 备份原子恢复原清单/页面/JS并检查旧 release JSON；iOS 设置本次值相同，通常无需数据库回退。保留新旧不可变包和审计。
- [x] **Step 5:** 更新任务记录、当前状态索引与验证报告，区分“已切官网入口”“同版本无弹窗”“真机安装和聊天历史未知”。

### Task 4: 将正式下载直链回填源码

**Files:**
- Modify: `frontend/tests/home-ios-download.test.mjs:20`
- Modify: `frontend/download.html:36`
- Update: `docs/workflow/tasks/2026-09-28-ios13-distribution.md`

- [x] **Step 1:** 在主目录确认 `frontend/download.html` 当前 SHA 仍为发布前 `1cd4b943d55a668ff4ddef74e9053fabfa0ba5f2d69b608e8a0621647f4c2691`，该文件只有旧 IPA 直链需要更换；不要从旧工作树拷贝整页，也不要把主目录被 Git 忽略的旧 manifest 当成生产基线。
- [x] **Step 2:** 先把 `frontend/tests/home-ios-download.test.mjs` 的预期不可变 IPA 路径改为 `ChatFlow-0.4.20-2189-enterprise-a2f8a145.ipa`，运行 `node --test frontend/tests/home-ios-download.test.mjs`，确认因页面仍含旧 `6afd6827` 而失败。
- [x] **Step 3:** 仅替换 `frontend/download.html` 第36行的旧 IPA 文件名为新文件名；检查该文件 SHA 与发布后的线上 `download.html` 完全相同。重跑定向 Node 测试、Android 下载入口相关测试和 `git diff --check`。不要改 `frontend/src/admin-home.js`，它同版本渲染前后字节不变。
- [x] **Step 4:** 记录源码回填的提交或文件 SHA，让后续网站部署不会把官网电脑端下载链接恢复到旧包。若线上发布未成功，则不要执行此任务。
