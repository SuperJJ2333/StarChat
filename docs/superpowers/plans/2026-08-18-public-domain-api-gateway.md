# 畅聊公网域名统一 API 网关实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Business API、Matrix、Web 与管理 API 通过已批准的 HTTPS 域名拓扑访问，并生成不含本机地址的 Flutter 域名版 APK。

**Architecture:** Nginx 作为唯一公网入口，按主域路径分流 Business API、Synapse 和 Element；`www` 只做规范化跳转；`admin` 只代理受现有 RBAC/TOTP 保护的 Business API。内部 Compose 地址保持服务名，移动端通过编译期 `dart-define` 使用主域，公网验收由独立 PowerShell 脚本完成。

**Tech Stack:** Nginx、Docker Compose、PowerShell 7、Flutter/Dart、Matrix Synapse、FastAPI、TLS。

## Global Constraints

- 实施依据：`docs/superpowers/specs/2026-08-18-public-domain-api-gateway-design.md`。
- 保留现有 Matrix ID、`MATRIX_SERVER_NAME`、房间 ID、MXC URI、包名及历史技术标识。
- 公网只允许 HTTPS；Android Release 不允许 cleartext HTTP。
- 不公开 PostgreSQL、Redis、Worker、Bot webhook 或 `/_synapse/admin/*`。
- 不向 Git 写入 `.env`、证书、私钥、Token、密码或服务器凭据。
- 远端验证必须针对公网 DNS 与 HTTPS，不能以本机 hosts、端口转发或 `-k` 跳过证书校验。

---

### Task 1: 网关域名路由与安全边界

**Files:**
- Modify: `tests/repository/Test-DeploymentPolicy.ps1`
- Modify: `infra/nginx/nginx.conf`

**Interfaces:**
- Consumes: `PUBLIC_HOSTNAME`、`WWW_PUBLIC_HOSTNAME`、`ADMIN_PUBLIC_HOSTNAME`、`SYNAPSE_PUBLIC_BASEURL` 模板变量。
- Produces: 主域 API/Matrix/Web 分流、www 301、admin API 分流及 Synapse Admin 拒绝规则。

- [ ] **Step 1: 编写失败的仓库策略断言**

在 `Test-DeploymentPolicy.ps1` 中断言：

```powershell
Assert-Match $nginx 'upstream business_api_upstream' 'Business API upstream is required'
Assert-Match $nginx 'location /api/v1/' 'Main-domain Business API route is required'
Assert-Match $nginx 'server_name \{\{WWW_PUBLIC_HOSTNAME\}\}' 'www canonical host is required'
Assert-Match $nginx 'server_name \{\{ADMIN_PUBLIC_HOSTNAME\}\}' 'admin host is required'
Assert-Match $nginx 'location \^~ /_synapse/admin/' 'Public Synapse admin denial is required'
```

- [ ] **Step 2: 运行 RED 验证**

Run: `pwsh -NoProfile -File tests/repository/Test-DeploymentPolicy.ps1`  
Expected: FAIL，指出缺少 Business API、www/admin 或 Synapse Admin 规则。

- [ ] **Step 3: 实现最小 Nginx 拓扑**

更新 `infra/nginx/nginx.conf`：

```nginx
upstream business_api_upstream { server business-api:8082; }

location ^~ /_synapse/admin/ { return 404; }
location /api/v1/ { proxy_pass http://business_api_upstream; }
location /_matrix/ { proxy_pass http://synapse_upstream; }
```

分别建立主域、www 和 admin 的 HTTP/HTTPS server block；www 保留 `$request_uri` 301 到主域，admin 根路径返回 404。

- [ ] **Step 4: 运行 GREEN 验证**

Run: `pwsh -NoProfile -File tests/repository/Test-DeploymentPolicy.ps1`  
Expected: PASS。

- [ ] **Step 5: 提交**

```powershell
git add tests/repository/Test-DeploymentPolicy.ps1 infra/nginx/nginx.conf
git commit -m "feat(infra): add public domain API gateway routes"
```

### Task 2: 生产域名配置契约与渲染验证

**Files:**
- Modify: `.env.example`
- Modify: `README.md`
- Modify: `docs/runbooks/mobile-release.md`
- Modify: `tests/repository/Test-DeploymentPolicy.ps1`

**Interfaces:**
- Consumes: Task 1 的 Nginx 模板变量。
- Produces: 可复制到服务器 Secret Manager 的生产配置契约，不包含真实秘密。

- [ ] **Step 1: 编写失败的配置契约断言**

断言 `.env.example` 声明：

```text
WWW_PUBLIC_HOSTNAME=www.example.com
ADMIN_PUBLIC_HOSTNAME=admin.example.com
BUSINESS_MATRIX_PUBLIC_HOMESERVER_URL=https://example.com/
BUSINESS_AVATAR_PUBLIC_BASE_URL=https://example.com
EMAIL_VERIFICATION_PUBLIC_BASE_URL=https://example.com
```

并断言移动发布 runbook 包含两个 HTTPS `dart-define`。

- [ ] **Step 2: 运行 RED 验证**

Run: `pwsh -NoProfile -File tests/repository/Test-DeploymentPolicy.ps1`  
Expected: FAIL，指出生产域名配置契约缺失。

- [ ] **Step 3: 实现配置与运行手册**

为 `.env.example` 添加不含真实秘密的域名变量；README 说明统一网关路径；移动发布 runbook 固定记录：

```powershell
flutter build apk --release `
  --dart-define=LIUHETONG_BUSINESS_API_URL=https://liuhetong888.com `
  --dart-define=LIUHETONG_MATRIX_HOMESERVER=https://liuhetong888.com
```

- [ ] **Step 4: 运行 GREEN 验证**

Run: `pwsh -NoProfile -File tests/repository/Test-DeploymentPolicy.ps1`  
Expected: PASS。

- [ ] **Step 5: 提交**

```powershell
git add .env.example README.md docs/runbooks/mobile-release.md tests/repository/Test-DeploymentPolicy.ps1
git commit -m "docs(deploy): define production domain contract"
```

### Task 3: 公网域名验收脚本

**Files:**
- Create: `scripts/verify_public_domains.ps1`
- Create: `tests/powershell/Test-PublicDomainVerification.ps1`

**Interfaces:**
- Produces: `scripts/verify_public_domains.ps1 -RootDomain <string> -WwwDomain <string> -AdminDomain <string>`，成功返回 0，任何 DNS/TLS/路由失败返回非零。

- [ ] **Step 1: 编写失败的脚本结构测试**

测试脚本必须拒绝 HTTP 主域、禁止跳过 TLS，并检查以下 URL：

```text
https://<root>/api/v1/health/live
https://<root>/api/v1/health/ready
https://<root>/_matrix/client/versions
https://<root>/.well-known/matrix/client
https://<admin>/api/v1/health/live
```

- [ ] **Step 2: 运行 RED 验证**

Run: `pwsh -NoProfile -File tests/powershell/Test-PublicDomainVerification.ps1`  
Expected: FAIL，因为验收脚本不存在。

- [ ] **Step 3: 实现验收脚本**

使用 `Resolve-DnsName` 和 `Invoke-WebRequest`，校验证书、状态码、www 跳转 Location、well-known JSON 及 admin 未认证保护；输出不包含响应 Token 或正文秘密。

- [ ] **Step 4: 运行 GREEN 结构测试**

Run: `pwsh -NoProfile -File tests/powershell/Test-PublicDomainVerification.ps1`  
Expected: PASS。

- [ ] **Step 5: 执行当前公网基线**

Run:

```powershell
pwsh -NoProfile -File scripts/verify_public_domains.ps1 `
  -RootDomain liuhetong888.com `
  -WwwDomain www.liuhetong888.com `
  -AdminDomain admin.liuhetong888.com
```

Expected before server deployment: FAIL with exact DNS/TLS/route boundary；不得把该失败标为通过。

- [ ] **Step 6: 提交**

```powershell
git add scripts/verify_public_domains.ps1 tests/powershell/Test-PublicDomainVerification.ps1
git commit -m "test(deploy): add public domain acceptance checks"
```

### Task 4: 公网服务器部署包与远端上线

**Files:**
- Create: `infra/nginx/production-domain.env.example`
- Create: `docs/runbooks/public-domain-deployment.md`
- Modify: `docs/verification/2026-08-18-public-domain-api-gateway.md`

**Interfaces:**
- Consumes: Task 1 网关模板、Task 2 配置契约、服务器上的证书与 Secret。
- Produces: 可审计的服务器部署步骤及公网验证证据。

- [ ] **Step 1: 创建无秘密的部署参数样例**

记录三个域名、主域 HTTPS URL、证书挂载路径和内部 upstream；真实证书、服务器地址、SSH key 与 Secret 不进入文件。

- [ ] **Step 2: 编写部署运行手册**

包括备份、渲染、`nginx -t`、滚动启动、健康检查和回滚命令；明确不能迁移 Matrix `server_name`。

- [ ] **Step 3: 检查远端部署通道**

检查受控 SSH/部署工具配置。若无服务器身份或 22/443 不可达，记录阻塞，不猜测凭据、不开放临时后门。

- [ ] **Step 4: 有部署通道时上线**

在服务器侧安装受信任证书、部署渲染后的 Nginx 配置、设置生产环境公开 URL，执行 `nginx -t` 后滚动重启。没有通道时停止远端变更，但继续完成本地制品。

- [ ] **Step 5: 执行公网验收脚本**

Run: Task 3 的 `verify_public_domains.ps1`。  
Expected after deployment: PASS；否则证据文件必须保留实际失败项。

### Task 5: Flutter 域名版构建与制品审计

**Files:**
- Create: `scripts/build_mobile_public_domain.ps1`
- Create: `tests/powershell/Test-MobilePublicDomainBuild.ps1`
- Modify: `docs/verification/2026-08-18-public-domain-api-gateway.md`

**Interfaces:**
- Produces: 使用两个 `https://liuhetong888.com` dart-define 构建的 APK，以及不含 `localhost`/局域网 API 配置的审计结果。

- [ ] **Step 1: 编写失败的构建脚本测试**

断言脚本：只接受 HTTPS 根 URL；拒绝 localhost、IP literal 和带 `/api/v1` 的 Business 根地址；同时注入 Business 与 Matrix define。

- [ ] **Step 2: 运行 RED 验证**

Run: `pwsh -NoProfile -File tests/powershell/Test-MobilePublicDomainBuild.ps1`  
Expected: FAIL，因为构建脚本不存在。

- [ ] **Step 3: 实现构建脚本**

脚本调用 Flutter Release 构建；若本机没有生产签名配置，则明确生成域名配置的 debug 验收 APK，不伪称生产签名制品。

- [ ] **Step 4: 运行 GREEN 结构测试**

Run: `pwsh -NoProfile -File tests/powershell/Test-MobilePublicDomainBuild.ps1`  
Expected: PASS。

- [ ] **Step 5: 构建并审计 APK**

构建域名版 APK，检查 Android cleartext 策略、包名、版本、制品大小和字符串边界；安装到 `emulator-5554` 仅用于启动验证，真实登录必须等公网验收通过。

- [ ] **Step 6: 提交**

```powershell
git add scripts/build_mobile_public_domain.ps1 tests/powershell/Test-MobilePublicDomainBuild.ps1 docs/verification/2026-08-18-public-domain-api-gateway.md
git commit -m "build(mobile): add public domain APK workflow"
```

### Task 6: 全仓验证与完成记录

**Files:**
- Modify: `docs/verification/2026-08-18-public-domain-api-gateway.md`

- [ ] **Step 1: 运行格式与专项测试**

Run:

```powershell
pwsh -NoProfile -File tests/repository/Test-DeploymentPolicy.ps1
pwsh -NoProfile -File tests/powershell/Test-PublicDomainVerification.ps1
pwsh -NoProfile -File tests/powershell/Test-MobilePublicDomainBuild.ps1
```

- [ ] **Step 2: 运行仓库验证**

Run: `pwsh -NoProfile -File scripts/verify.ps1`  
Expected: `Verification: PASS`。

- [ ] **Step 3: 复测公网与 APK**

记录 DNS、TLS、HTTP 状态、well-known、Business/Matrix health、APK 路径及模拟器安装状态；公网未通过时状态必须写为 `BLOCKED`，不能写“完成”。

- [ ] **Step 4: 检查差异并提交**

```powershell
git diff --check
git add docs/verification/2026-08-18-public-domain-api-gateway.md docs/superpowers/plans/2026-08-18-public-domain-api-gateway.md
git commit -m "docs: record public domain gateway verification"
```

