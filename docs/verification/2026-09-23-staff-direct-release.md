# 客服直接结算及 Debug UI 发布（2026-09-23）

用户明确授权已核验充值由客服直接发放、拒绝原因下拉及生产部署；移动页清理与Mi6 Debug覆盖安装。后端和管理后台已上线；Mi6 0.4.4+2163 Debug也已保留数据安装并启动。

## 已上线
- 同一操作弹窗确认最终汇率/点钻，自动prepare→execute，已保存绑定沿用冻结金额；无需另一管理员审批。不伪造reviewer，普通财务调整保持审批。
- 系统核验付款、客服处理权/五分钟租约、提交前会话/RBAC重验、唯一凭证消费、服务端账本幂等与平衡、审计/Outbox均保留。
- 拒绝原因下拉默认“用户未及时支付”；还有主动取消、重复申请、付款来源不符、网络/币种不符。结果仍由服务端规则决定，菜单不能绕过到账保护。
- 订单列表处理改模态、参考卡/刷新图标、昵称畅聊号、铃铛侧通知与历史基线修复一并发布；HTML/模块入口更新版本查询避免旧缓存。

## 生产证据
基于API e2577705bc27（保留诊断接口）和worker97467ae9a913逐文件叠加；API6文件、worker4文件、7静态。335源文件身份逐角色核验。最终API ba801c6c26822d62134ce9333c870b5fc61192c657937a88029c050b26ed1e8b；worker07019a1b76d1b4780ee911580be03ecdbd8a570b9db2a78eb15c42a544c183ba。schema0087，无生产迁移。

生产备份在0700远端目录 /opt/starchat/releases/staff-direct-settlement-20260923；隔离恢复136表217931行，upgrade head前后原数据一致。API/worker healthy/restart0/无新异常；22其他容器ID/启动时间未变。服务器与工作站jumper双侧HTTPS证书校验、health JSON200、鉴权401、登录空请求422、7资源SHA均通过。工作站首次探测早于SOCKS监听，exit7；监听就绪后重试全部通过，失败日志保留。

## 验证口径
上一轮完整verify已exit0（后端2688/67条件跳过、mobile108/1）；本轮金融变更不冒称被旧全量覆盖。相邻充值103/4条件跳过、ledger17、含真实PG并发/提交前撤权最新专项15、提交后宕机worker恢复1、真实HTTP激活管理会话/APP拒绝/禁用拒绝/成功直发1均通过。独立规格领域之后质量安全复审通过。最新frontend295/0、UI32组件398屏、OpenAPI通过。

独立Flutter冻结目录保留先前已验证图片/Outbox/诊断优化27覆盖文件（包括本轮UI/版本），排除主目录正在编写的其他room_page/search增量；Flutter全量3921通过、analyze0 issue，版本门禁2通过。0.4.4+2163源码构建首轮AAPT2 daemon启动失败；原日志保留，直接version/daemon均可运行，系统剩余内存约1.3GB。资源目标限制两worker后37秒通过，构建目录采用两worker重跑；未改源码或依赖版本以绕过失败。工具已有Gradle/Kotlin插件弃用提示，不宣称零warning。

## 回退
独立复审发现旧服务无法登记新无reviewer直发；已构建兼容回退镜像：基底仅修改mark_credited兼容方法，不开放直接执行。回退保留schema/账本/审计，不回滚真实资金记录。命令 python3 /opt/starchat/releases/staff-direct-settlement-20260923/release.py rollback；镜像/静态漂移保护防覆盖后续发布。

未发测试短信、未代客服处理生产资金；实际充值业务效果由用户测试。部署工件与复审见[证据目录](artifacts/2026-09-23/staff-direct-settlement-release/)，手机工件在[Debug2163](artifacts/2026-09-23/staff-direct-debug-2163/)。

## 最终Android交付
19:55:28+08已保留数据覆盖安装Mi6 0.4.4+2163 Debug并启动。固定证书75b31c…ba61fff；首次安装时间2026-09-20 09:35:24未变。设备sha256与最终包一致：afa5ed50bd931e93753946eef1c8e8539bfc7da564853b1d2c61e45ca8fda925。27317个类、339项原生库/Flutter资产完整一致，清单语义相同，DEX和资源确已重建；zipalign与apksigner通过。构建/独立验包exit0；首次失败证据保留。实际用户支付与二维码相册保存效果由用户真机复验，未代操作生产资金。
