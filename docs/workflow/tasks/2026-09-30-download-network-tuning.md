# 现有双线路下载优化

## 范围与授权

- 用户2026-09-30明确批准：统一测速入口、调整2秒超时、保留CDN/香港备用/断点续传、验证旧客户端兼容。执行既有已批准安装包分发计划的Task6。
- 工作树C:/Users/Administrator/.codex/worktrees/installer-s3-cdn/StarChat；基线c545addc，开始时干净。拥有download-network.js、download-network-selector.js、对应两组测试、本记录及计划追加。生产download.html仅缓存版本增量。
- 不新建云资源，不新安装包，不改业务API/更新设置、iOS安装行为、APK alias或财务状态。
- 现网首页arm64主按钮及更新设置已走/download?platform=android&install=1；下载页主按钮由JS测速，缺能力时原生APK备用。不得将latest-arm64.apk改为HTML，破坏旧客户端/下载器。

## 决策与验收

|ID|要求|实现/验证|状态|
|---|---|---|---|
|D1|主下载走当前同版本双线路测速|现场首页桥接检查、registry严格绑定、真实浏览器测延迟线路|已完成|
|D2|高延迟可用线路不被2秒误淘汰|单请求4s、selector总9s、registry2s、bootstrap总11s；2轮每轮256KiB不变|专项通过|
|D3|备用/取消/失败与传输上限|既有取消/异常/源绑定/最多1MiB回归；总预算耗尽不发探测|专项通过|
|D4|旧客户端与Range断点续传|既有APK直链不变，实际206/Content-Range/If-Range/ETag核验|已完成|
|D5|精确发布与回退|仅三静态文件，before SHA漂移保护、备份/回退、其他容器/registry/两端包不变|已完成|

## 证据与计时

- 两生产网络模块SHA与工作树原输入相同。生产首页主入口已统一，无需覆盖较新的admin-home.js。download-redirect.js生产已含iOS13风险提示，本任务不复制工作树旧版本。
- 红：新高延迟/registry/预算/4秒超时4failed、39passed，4503ms；绿47passed，8908ms。两轮2200ms首字节线路可入选，registry1500ms仍可测速，断网和全部失败回退保持。
- 发布器/旧平台兼容48passed，8.13s；完整verify执行，repository/deployment/template通过，render-only缺.env退出1，不借用生产密钥，不声称全仓通过。
- 临时证据仅docs/verification/artifacts/2026-09-30/download-tuning/。开始/阶段精确时间未完整记录，不估算总耗时。
- 当前：修复、审查、浏览器/兼容验证、生产发布与公网后验均完成。
- 可实现保障为限时选优、原生备用和Range能力；公网任何条件>=1MB/s不作保证。外部浏览器下载中途无法由页面自动接管；没有新增客户端下载器。

## 审查前验收补充

- 全前端342passed，9711.74ms；47专项与48发布兼容门禁通过。node --check/diff check通过。
- 真实Chromium使用合成同版本registry与2200ms首字节响应：自动开始选择CDN、30s内再次点击复用结果、全失败回退PASS。浏览器fixture不代表大陆运营商真实速度。
- 严格TLS实际legacy与CDN均支持offset1048576的Range+If-Range，206、Content-Range正确、各只读1024bytes；未整包下载。
- 实时设置app_latest_version0.4.24/build2193，app_apk_url已是统一测速页，未改设置。首页arm64按钮实际同页，其他ABI仍native。
- 候选只改生产两网络JS和download.html script query，较新iOS启动JS/首页JS/版本registry/manifest保护哈希不变。准备器最初根目录层级写错，打包失败、上传未执行；修正parents[4]后打包与预检成功，未改生产。
- 规格领域PASS；质量安全PASS。静态CAS发布与公网后验完成。

## 发布结案

- 2026-09-30 16:57:42 +08以before/after SHA校验更新2网络JS和线上download.html缓存query；按照selector→consumer→HTML顺序切换。两JS现场Cache-Control:no-store，依赖不留缓存版本不匹配窗口。
- 生产3文件公网及工作站经既有loopback SOCKS严格TLS GET的SHA与candidate manifest完全匹配，JSONready正常。后验Range/If-Range两线路再次206/正确偏移/各1024bytes。
- 容器ID/镜像、5个保护文件哈希、当前2193包alias路径/大小/mtime均不变。旧latest-arm64.apk仍是APK，不重定向HTML；iOS manifest和新的风险提示启动脚本完整保留。
- 回退文件位于/opt/starchat/releases/download-tuning-20260930/rollback/，发布证据deployment-proof.json留服务器；目录0700。无迁移、更新设置写入、AWS写入或新安装包。
- 证据：red.log/green.log/frontend-all.log/compatibility.log/verify.log/browser-dom.html/range-before.log/cache-before.log/deploy.log及candidate/manifest.json；副作用范围仅3静态文件。
- 主工作区回填限定2JS/2测试/独立任务文档，先与c545addc内容或候选内容比较，禁止覆盖未知漂移；计划只追加Task6，其他脏改动保留。
- 没有大陆用户本次长下载速度测量，不宣称已达到固定MB/s；用户可通过测速入口复验。本任务配置与兼容验收已完成，无待执行部署步骤。