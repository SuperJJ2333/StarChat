# 财务客服结算参考显示

日期：2026-09-30。工作树：codex/wallet-alert-only-payout-void。

- 用户目标：结算参考显示汇总信息；只读生产源证实reserve-valuation仍要求SYSTEM_ADMIN。
- 状态：修复、审查、生产发布及用户真实客服页面验收完成。
- 已批准ADR：../../adr/2026-09-30-finance-reference-read-access.md。
- 已批准计划：../../superpowers/plans/2026-09-30-finance-reference-read-access.md。
- 验收R1：有效财务客服查看三项汇总；R2：身份和角色拒绝边界；R3：故障文案准确；R4：增量生产发布与真实页面验收。
- 本次调查只读源与线上同一路由，未伪造客服会话。精确阶段起止未记录。
- 用户已确认三项信息正常显示；本任务无剩余必需步骤。
## 实施与验证

- 用户明确批准ADR和计划，授权按计划修复上线。基线85a6232b；本任务仅拥有recharge.py路由、admin-recharge-panel.js、两组测试和文档。既有pubspec.lock保留。
- 使用公开TokenService.admin_session校验有效管理身份，FINANCE_REVIEW限制财务客服，只返回三项汇总。不调用个人提现保护/写入grant；原订单读写鉴权保持。管理员响应仍5字段。
- 后端红：2项预期财务客服读取403；初次额外管理员夹具错误使用APP令牌，改用管理会话后又发现测试issuer与Settings默认liuhetong不一致，已修测试。最终22 passed /73.32s，覆盖12类拒绝、保护期读取允许而订单仍403、管理员响应兼容。
- 前端红4 failed/40 passed；绿329 passed/0failed，1623.53ms；涵盖401/403/服务异常分类、null估值和其他汇总显示。
- OpenAPI --check PASS，授权Header已有契约无变更。verify.ps1实际执行：repository/deployment/template PASS；render-only缺.env退出1，未借用生产密钥。精确门禁退出依据日志，未宣称完整verify通过。
- 规格/领域审查先PASS，再质量安全PASS。双角色最终候选续期门禁PASS；API d791c7fc，worker00c0e109保持。
- 候选API基于902eaefc，只替换线上reserve-valuation函数；保留线上其他任务submit接口与绑定变更。静态基于线上文件精确修改导入缓存和文案，避免旧admin-home覆盖。
- 16:09左右红测试、16:10现场基线、16:13合同核验；精确实施起止未记录，不估算总耗时。候选构建在审查期间完成，尚未切换。
- 证据位于docs/verification/artifacts/2026-09-30/reference-{red,ui-red,green-final,ui-green,verify,openapi,image-gate}.log及reference-release/manifest.json。所有测试使用合成身份，不伪造真实客服会话。

## 发布与正式验收

- 2026-09-30 16:20:42 +08仅API切换至sha256:d791c7fc2facaf5d44ee9c082903aaf62fd1eec37c1352ef87b1abc42e085f95；健康/0restart，worker00c0e109不变，其余29容器不变。guard当前配置/opt/starchat/releases/guarded-098dz4_1/compose.json。
- 16:20:43静态三文件切换，缓存版本20260930-reference；manifest哈希现场与公网均匹配。服务器及工作站经既有loopback SOCKS访问HTTPS保留证书验证，JSONready200，未登录reserve-valuation401，切换后新错误行0。
- 首次健康探针误用/health/ready返回非2xx；核路由后改为/api/v1/health/ready确认JSON200。未将错误路径当作服务故障或忽略失败。
- 回退：/opt/starchat/releases/finance-reference-20260930/rollback.json保留旧API902eaefc；rollback/存静态备份。配置目录0700/文件0600。无迁移或生产金融写入。
- 用户用真实财务客服账号刷新后明确确认“三项已正常显示”，R1/R4正式验收闭合。R2测试权限拒绝与管理员兼容通过，R3前端错误分类测试通过。
- 证据reference-deploy.log、reference-static-deploy.log、reference-https.log，候选api源sha256 069e4ed68fbae0e23ff077f00a7afce4510c705f82a30c2940039a0de60f1c6b，公开panel sha256 f49550e348c0f5a79e6f12fb921f57559d669177f9e7859ebf5247684fc8430e。