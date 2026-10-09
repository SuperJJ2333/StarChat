# Landing / Download · Orbit HTML 审核稿

## 恢复入口

- 目标与授权：用户 2026-10-05 要求美化两页，移动适配、Three.js 科技感、以图形表达特点、有创造力，先给 HTML DEMO 审核。授权制作独立可交互预览；未授权生产替换。
- 设计依据：产品现代化规格、CONTEXT 品牌词汇、UI HTML 工作流。官网历史结构参考 `docs/superpowers/plans/2026-08-27-admin-homepage-ui-implementation.md`；本次不执行该历史计划的管理员功能或发布步骤。
- 范围：官网概念页，与 Flutter catalog/注册组件无共享实现。UI registry/token 不变，不适用 Flutter 分析/构建。
- 文件所有权：`frontend/concepts/orbit/**`、`frontend/tests/orbit-demo.test.mjs`、本任务记录、`docs/verification/2026-10-05-orbit-demo.md`、本任务 artifacts 子目录。
- 基线：主目录 `D:/pythonProject/outsource/StarChat`，观察 HEAD `4c8c16c7`；已有大量无关改动，包括正式 download.html，均未修改。
- 当前状态：DEMO 已完成，待用户审核；未提交、未发布、无移动安装包。
- 更新时间：2026-10-05 19:10 +08；完整精确起点未知，不虚构总工时。
- 下一步：在本机预览两页，按用户反馈调整此同一目录；正式替换作为后续明确任务。

## 验收台账

| ID | 场景 | 结果 | 证据 |
| --- | --- | --- | --- |
| D01 | 320/390/768/1440px 两页 | 无横向溢出，场景 ready | 验收报告与截图 |
| D02 | Three.js 视觉 | 本地固定依赖，轨道球与设备连接场景 | scene.js / vendor |
| D03 | 产品特点图解 | 三种关系图、加密流程、安装流程 | 标签切换浏览器实测 |
| D04 | 可交互 DEMO | 平台切换、方向键、arm32/x86_64 链接切换 | 浏览器实测 |
| D05 | 动效偏好和异常 | reduce 时跑马灯 none；丢失 WebGL 后 fallback opacity 1 | 浏览器模拟 |
| D06 | 用户审核 | 待用户 | 两页已请求在 Codex 打开 |

## 证据与时间

详见 [验证记录](../../verification/2026-10-05-orbit-demo.md)。18:27:32 +08 为首个显式时钟观察；18:43–19:05 完成浏览器验证、布局修正和门禁观察。早期设计/实现的精确分段时长未知；不将工具等待算成主动编写时间。

CDN 下载失败一次，改 npm pack 固定版本成功。修正手机 flex 容器中 Three.js 区域被收窄的问题。全仓门禁已启动，因无关业务全量耗时且下载基线已存在失败，在业务阶段主动停止，未声称全仓通过。

## 预览与回退

- 本任务预览进程：Node serve，127.0.0.1:4186，保留供审核。
- 无后台/移动端/生产写入；概念文件不被正式入口引用。
- 恢复时先检查端口是否仍可用，再按概念目录 README 启动。
