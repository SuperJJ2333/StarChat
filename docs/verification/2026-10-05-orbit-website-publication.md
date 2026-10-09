# Orbit 官网发布验证

已发布 [首页](https://www.liuhetong888.com/) 与 [下载页](https://www.liuhetong888.com/download)，静态版本 `orbit-20261005-v1`。用户同一会话审核视觉稿/APP图标后授权上线。未构建或发布App、修改版本设置或重启服务。

## 规格复核

首页Three.js连接网络、关系图切换、加密路径图；下载页设备模型、平台和架构选择、三步安装图解；六处品牌图标和favicon统一新图。所有资源版本化路径已在实际官网可访问。设计预览标签去除，聊天场景示意仍明确标注。

正式适配保留既有Android网络选线模块和旧客户端 `install=1` 桥接，iOS query自动展示iOS面板，安装必须显式点击。保留原始OTA、IPA桌面下载、企业签名/历史数据警示及官网二维码。继续兼容既有发布器的iOS/Android渲染契约。

## 质量、安全及生产证据

| 检查 | 结果 |
| --- | --- |
| 新生产页面测试 | red：2失败/1通过，exit1；green：3通过，exit0 |
| 前端全部测试 | 532通过，0失败，exit0，最终10.816s |
| UI契约 | 34 components / 535 screens，exit0；本任务未修改Flutter注册表 |
| 发布器 | 6通过：发布、前态漂移、候选损坏、失败恢复、保护后继发布、受保护状态漂移；exit0 |
| 既有release.render | iOS/普通Android模板兼容PASS；只读，没有包发布或设置写入 |
| 实际发布 | `STATIC_PUBLISH_PASS`、exit0，22:26:40→22:27:19 +08 |
| 服务器公网 | 首页/下载页及8项依赖SHA匹配；manifest一致；三APK入口HEAD200 |
| 工作站公网 | 严格TLS+仅loopback jumphost SOCKS；10静态SHA、manifest/registry SHA、3APK+1IPA HEAD、下载no-store、manifest XML、JS MIME，14 resources/HEADs PASS |
| 线上浏览器 | 390/1440px两页无横向溢出；场景ready；图标加载；iOS安装query面板可见；0 pageerror；真实设备尚未验证 |
| 后态保护 | 十项Android/iOS设置、manifest、Android registry、三APK别名、选线脚本、admin-home.js/admin.html/index.html、二维码、nginx和4容器ID/镜像与前态逐项一致 |
| 备份 | 私有0700目录已核实；前态与候选清单保留 |

实际Android分发保持0.4.33/2202、82,193,438字节；iOS保持0.4.25/2194、61,709,960字节与d532f913回签包。CDN路径、安装清单和版本弹窗设置均保持。原有2196测试依据过时，已按生产2202身份修订断言；旧CSS结构断言更新为实际新页的警示样式，保留签名警示、OTA顺序和精确链接检查。

复用同任务此前完整verify的启动证据，未声称该取消任务完整通过。依据现行影响范围与证据复用规则，本次纯静态站点发布不重跑无关服务/Flutter全量或构建App；新的实际候选前端全量、UI契约、发布器恢复、两平台渲染和生产分发检查全部完成。

## 回退与审计

候选压缩包SHA256：`c3b0d93454eb1695f1a512308b475db8419654b608ac9da8ec01a5a21f67e257`，上传后服务器SHA一致。逐文件SHA在 artifacts/orbit-deploy/record.json及result.json，不复制大段清单。

候选：`/opt/starchat/releases/orbit-site-20261005-2214/`。
备份：`/opt/starchat/docs/verification/artifacts/2026-10-05/orbit-site-publish-2214/`。发布锁 `/opt/starchat/.release-metadata.lock`。

失败时仅恢复仍与本次候选SHA相符的HTML，保留后继写入；测试已证明该行为。无数据库写入，不伪造SettingService审计。文件发布前后与结果构成静态审计记录。临时SOCKS已关闭。

详见 [任务记录](../workflow/tasks/2026-10-05-orbit-website-publication.md)。证据目录 `docs/verification/artifacts/2026-10-05/orbit-deploy/` 包含日志、清单、真实线上手机截图。仅小型网页资源GET与安装包HEAD，没有重复回拉完整App包。
