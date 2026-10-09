# Orbit HTML DEMO 验证 · 2026-10-05

交付：首页 `frontend/concepts/orbit/index.html`、下载 `frontend/concepts/orbit/download.html`。同目录 CSS / UI / Three.js 场景共用，正式网站未替换。主题：深色青绿连接网络。Figma 已退役：本次变更仅更新 HTML demo（`frontend/concepts/orbit/`）。官网概念不增加 Flutter registry 或共享 token，现有契约保持不变。

## 规格符合性

用户五项：移动端适配；Three.js 科技视觉；产品特点用关系图、加密流程图与安装流程图表达；抽象轨道场景与设备浮层；两个可直接预览的 HTML 页面。均已实现，用户审美验收待反馈。聊天内容和关系节点为示意，未声称实际容量、性能或用户数量。

## 质量与安全检查

- 320、390、768、1440px 两页浏览器检查 `scrollWidth === clientWidth`，无横向溢出；场景 WebGL `scene-ready=true`。
- 首页「分享生活」切换显示照片、视频、朋友圈、评论节点与对应标题。
- 下载平台切换正确隐藏不活动 panel；方向键从 iOS 回到 Android，aria-selected 与面板可见性一致。
- Android select 切换 arm32 / x86_64 后分别指向官网对应 latest 别名。
- iOS 企业内部使用及签名换团队警示保留，安装按钮关联 `aria-describedby`。前往现有正式页，无自动安装/跳转。
- reduce 偏好模拟：跑马灯 animationName=none；场景静态。WebGL 丢失模拟：CSS fallback opacity=1。
- 正常导航控制台 0 errors / 0 warnings；故意丢失上下文的模拟日志不计作普通场景错误。
- Three.js 0.180.0 从 npm 官方包固定到本地，MIT LICENSE 保留；Google 字体可回退系统字体。
- 无资金、认证、E2EE 运行逻辑改动，无生产操作或用户数据请求。

## 命令证据

Windows / pwsh 7 / Node.js 原有环境 / Python 3.12.10。基线观察 HEAD `4c8c16c7`，本任务仅新建文件，未改现有依赖锁。

| 命令 | 结果 |
| --- | --- |
| `node --test frontend/tests/orbit-demo.test.mjs`（实现前） | exit 1；3 失败，缺失尚未创建的目标文件 |
| 同一命令（实现后） | exit 0；3 通过 |
| `python scripts/verify_ui_contract.py` | exit 0；33 components / 528 screens PASS |
| `npm --prefix frontend test` | exit 1；525 tests，523 pass，2 fail |
| `node --test frontend/tests/download-published-2196.test.mjs frontend/tests/download-redirect.test.mjs` | exit 1；8 tests，6 pass，2 fail；单独运行未经本次修改的正式页面测试，复现同样两项失败 |
| `pwsh -NoProfile -File scripts/verify.ps1` | 启动后主动停止（实际 exit -1），未通过完整门禁；已完成前置策略/模板/配置/基础测试，进入与本次页面无关的业务 API 全量，停止前日志记录至 21% 没有新失败。此取消不等于通过 |

两项既有前端失败：`Android release registry names the published 2196 artifact on both exact routes`、`iOS install query shows the signing warning and waits for an explicit tap`。测试期望更新后的发布标识（含 2202-network），当前已有 download.html 保留旧版本。未通过修改别人发布状态来修复概念稿门禁。

原始日志、固定 npm 包和截图：`docs/verification/artifacts/2026-10-05/orbit-demo/`。浏览器实测为本机 Chromium，不代表手机 GPU/触控或 Safari 真机验收；未点击实际下载执行安装。

## 输入 SHA256

以下为首版 DEMO 身份；后续图标修订改变 HTML/CSS，修订证据见文末。

| 文件 | SHA256 |
| --- | --- |
| index.html | 2A615E5F9D0D87BEAEB5219A7DC0192F9D3C8F23E58C1B63F0967F30F0CF32B2 |
| download.html | E7FB2E0B08DDE539A703BABF078FB87A03F7222C308426BB6E381A1F212F89BB |
| orbit.css | 58760667FC562E51E774DEE78E3AAAD2247CCEFA69694F1062EDB266B767B14D |
| scene.js | 378181C9051A31B9680B1CEAD6939CF02F51F56AC5F26A3C95CF511750C1273D |
| ui.js | EBDFE040CA1FE0EF91E002999D3B74CF022BF55A273E9DDAC4C0670975C8F79F |

## 可审核入口

- http://127.0.0.1:4186/concepts/orbit/index.html
- http://127.0.0.1:4186/concepts/orbit/download.html

Node 预览服务仅监听本机，保留供用户审核。完整启动说明在概念目录 README。未经生产发布、Flutter 分析或真机验证，不能声称正式官网已完成改版。

## 2026-10-05 22:12 +08 · 用户指定 APP 图标美化与替换

- 授权：用户提供 `apps/mobile_flutter/assets/branding/simple_logo.png`，要求美化并替换此前设计页面的 icon。
- 使用 imagegen 编辑原图；最终选择深绿底青绿/冰蓝渐变版本，保留双气泡及六组中心结构。透明候选边缘质量不足，未用于页面。
- 文件：两页 HTML、orbit.css、`assets/chatflow-icon.png`；原始 APP 图标未覆盖，正式网站和 Flutter 不变。
- 新图标 SHA256：`935CD0D64A32FC32B04F967FBEF0C09F973950DC87C08C4DB1A06427E29D9E50`；1,227,178 bytes。
- 浏览器检查两页各 3 处 img.brand-icon 均加载成功，旧 `.brand-icon i` 元素计数 0，favicon 指向新资产。桌面与 390px 无横向溢出。
- `node --test frontend/tests/orbit-demo.test.mjs`：exit 0，3 pass。限定路径 diff 检查 exit 0。纯品牌资产替换不重跑无关后端/Flutter 全量；首版门禁限制仍按上文保留。
- 新截图：`artifacts/2026-10-05/orbit-demo/download-icon-refresh.png`、`download-icon-mobile.png`。
