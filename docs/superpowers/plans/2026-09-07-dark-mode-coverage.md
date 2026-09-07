# 全页面深色模式热修复

用户授权修复深夜模式的导航、页面背景、朋友圈、通讯录及各页面切换异常，参考微信视觉层级。沿用现有浅色/深色/跟随系统设置和持久化，不新增设置流程。

设计：浅色保留既有色值；深色页面 #111111、导航/次级面 #191919、卡片/输入面 #232323、主文字 #F5F5F5、分隔线 #2C2C2C。照片/视频/二维码及有品牌意义的彩色操作保持语义色。使用上下文解析公共颜色，不使用全局可变亮度或全页面滤镜。

Root owns foundation/wechat_tokens.dart、theme、wechat_scaffold.dart、wechat_nav_title.dart、app_home.dart 必要颜色补丁、HTML tokens/组件、Figma ledger/registry 和汇总测试/文档。保留当前未提交钱包/iOS工作，不并入其业务逻辑。
UI 任务 owns ui 下其它共享组件与对应测试；页面任务 owns features 下页面与对应测试（排除 wallet 现有改动；发现钱包问题向 root 报告）。各任务先 RED 后 GREEN，文件不交叉编辑。
公共 API：WeChatColors.resolve(context, color) 按现有亮度显式解析已知语义色，WeChatColors.pageBackground(context)、navigationBackground(context)，现有 elevatedSurface/resolveTextPrimary 保留。

1. 公共导航/底色及通讯录文字建立真实渲染回归；根标签、二级页和切换前后检查。
2. 分别审计共享组件和功能页面，修复固定浅色背景、黑字、分隔线；逐项记录保留的图片/二维码/品牌色。
3. 同步 HTML 深色 token、设计登记及节点链接。当前无 Figma callable tools，按 docs/ui-development-figma-workflow.md 热修复 Deferred 路径记录远程同步，不能伪造远程 PASS。
4. 全量 Flutter、analyze、HTML/契约、仓库校验；独立规格审查后质量审查。记录运行模式切换和持久化、视觉截图及限制。
