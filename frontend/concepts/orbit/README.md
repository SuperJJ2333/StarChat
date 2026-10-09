# ChatFlow Orbit · 官网设计预览

本目录为用户 2026-10-05 授权制作的 landing / download HTML 审核 DEMO。主题：流动的连接。正式官网、下载发布配置、Flutter 和资金逻辑不在本次范围。

## 预览

在仓库根目录使用 PowerShell 7：

```powershell
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$env:PORT = '4186'
node frontend/scripts/serve.mjs
```

- 首页：http://127.0.0.1:4186/concepts/orbit/index.html
- 下载：http://127.0.0.1:4186/concepts/orbit/download.html

用 HTTP 预览；不要双击 HTML 使用 file 协议，浏览器会限制 ES module。服务仅监听本机，手机实机不能直接打开此 localhost 地址。

## 审核点

- 首页 Three.js 球形关系网络、旋转轨道、鼠标视差。
- 功能标签可切换即时沟通、分享生活、私密连接图解，支持方向键。
- 设备端加密路径图解；界面中的聊天与连接节点均为示意，没有伪造用户量、速度或容量指标。
- 下载页设备选择、Android 架构选择、三步安装图解、现有官网二维码、iOS 企业签名提示。
- 320 / 390 / 768 / 1440px 响应式；移动端降低点数和像素比；屏幕外、后台和减少动态效果偏好暂停连续渲染；WebGL 失败保留 CSS 轨道插图。
- 下载按钮指向既有正式官网，可能实际下载安装包；iOS 引导前往正式安装页，不自动触发安装。

## 文件与依赖

`index.html`、`download.html`、`orbit.css`、`ui.js`、`scene.js`。Three.js **0.180.0** 本地副本来自 npm `three@0.180.0` 官方包，MIT 许可证保留在 `vendor/LICENSE`。预览无需 CDN 获取 Three.js。字体使用 Google Fonts，访问失败时使用系统字体。二维码复用 `frontend/assets/download-qr.png`。

这是独立官网概念稿，不属于 Flutter 组件目录；本次未修改 `packages/ui-contracts/changliao-component-registry.json` 或共享产品 token。UI 契约检查通过。Figma 已退役：本次变更仅更新 HTML demo（`frontend/concepts/orbit/`）。

2026-10-05 图标修订：使用用户提供的 `apps/mobile_flutter/assets/branding/simple_logo.png` 作为 imagegen 编辑参考，保留双气泡 / 六节点 / 六瓣连接结构，生成深绿底、青绿到冰蓝渐变品牌图标。`assets/chatflow-icon.png` 统一用于导航、页脚、首页关系图中心、下载页手机模型和 favicon。移动 APP 原始资源未覆盖。
