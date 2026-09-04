<#
.SYNOPSIS
    一键发布 ChatFlow Android 版本（构建 → 上传 → 别名 → 发布 → 回拉验证）。

.DESCRIPTION
    把过去十几步手动 SSH 发布固化为一条命令。SSH 限流对策：所有远程
    操作经 Invoke-Remote 指数退避重试（30s→2m→5m→9m），且上传/别名/
    哈希核对合并为单次会话批处理。

.PARAMETER Version
    要发布的版本（X.Y.Z）。必须与 pubspec.yaml 和 app_config.dart 三方
    一致（预检强制，防止版本漂移发布）。

.PARAMETER Notes
    更新弹窗文案（用户可见）。不传则中止并提示。

.PARAMETER SkipBuild
    跳过预检+构建，直接使用 build 输出目录中的现有产物（发布重放/修复
    场景）。仍执行上传/发布/回拉。

.PARAMETER SkipPublish
    完成上传+别名但不调 publish API（准备模式：先传包，稍后人工确认发布）。

.PARAMETER KeepPrevious
    默认 true：保留上一发布版作为回滚包，清理更旧版本。

.EXAMPLE
    pwsh -File scripts/release.ps1 -Version 0.3.35 -Notes "0.3.35 更新：……"
#>
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Notes,
    [switch]$SkipBuild,
    [switch]$SkipPublish,
    [switch]$KeepPrevious  # 默认行为；显式 -KeepPrevious:$false 可关闭
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$mobileRoot = Join-Path $root 'apps/mobile_flutter'
$downloadsDir = '/opt/starchat/frontend/downloads'
$sshTarget = 'root@207.56.8.8'
$sshPort = '23421'
$publicBase = 'https://www.liuhetong888.com/downloads'
$abiMap = @{
    'arm64' = @{ source = 'app-arm64-v8a-standard-release.apk'; prefix = 2000 }
    'arm32' = @{ source = 'app-armeabi-v7a-standard-release.apk'; prefix = 1000 }
    'x86_64' = @{ source = 'app-x86_64-standard-release.apk'; prefix = 4000 }
}
$apkDir = Join-Path $mobileRoot 'build/app/outputs/flutter-apk'

# ── 工具函数 ──────────────────────────────────────────────────────────
function Write-Step([string]$msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

function Invoke-Remote([scriptblock]$Action, [string]$Label) {
    # SSH 限流退避：30s → 2m → 5m → 9m（docs/verification/2026-09-03 记录
    # 最长 25 分钟窗口；4 次退避覆盖多数场景）。
    $delays = @(0, 30, 120, 300, 540)
    foreach ($delay in $delays) {
        if ($delay -gt 0) {
            Write-Host "  [$Label] 连接被限流，退避 ${delay}s 后重试…" -ForegroundColor Yellow
            Start-Sleep -Seconds $delay
        }
        try { return & $Action }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match 'Connection reset|Connection refused|timed out') { continue }
            throw
        }
    }
    throw "[$Label] 远程操作在退避重试后仍失败（SSH 限流窗口可能长达 25 分钟，请稍后重试或检查网络）"
}

function Read-PubspecVersion {
    $pubspec = Get-Content -LiteralPath (Join-Path $mobileRoot 'pubspec.yaml') -Raw -Encoding UTF8
    if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') {
        throw 'pubspec.yaml must declare version: X.Y.Z+build'
    }
    @{ name = $Matches[1]; build = [int]$Matches[2] }
}

# ── 0) 预检 ──────────────────────────────────────────────────────────
$pubspecVersion = Read-PubspecVersion
$expectedBuild = $pubspecVersion.build
$versionCodeArm64 = 2000 + $expectedBuild

if ($pubspecVersion.name -ne $Version) {
    throw "版本不一致：pubspec=$($pubspecVersion.name)（+$expectedBuild）但请求发布 $Version。先递增 pubspec + app_config.dart（合同测试强制三方一致）。"
}
Write-Step "预检：版本 $Version+$expectedBuild（arm64 versionCode=$versionCodeArm64）"

# app_config 合同校验（复用 tests/mobile 逻辑，双保险）
$appConfig = Get-Content -LiteralPath (Join-Path $mobileRoot 'lib/core/app_config.dart') -Raw -Encoding UTF8
if ($appConfig -notmatch [regex]::Escape("appVersionName = '$Version'") -or
    $appConfig -notmatch "appBuildNumber = $expectedBuild") {
    throw "app_config.dart 与 pubspec 版本不一致（tests/mobile/test_app_build_contract.py 也会拦截）"
}

if (-not $SkipBuild) {
    Write-Step '门禁 A：flutter analyze'
    Push-Location $mobileRoot
    try {
        flutter analyze 2>&1 | Tee-Object -Variable analyzeOut | Out-Null
        if ($LASTEXITCODE -ne 0 -or $analyzeOut -match 'error -') { throw 'flutter analyze 未通过' }
        Write-Host 'analyze: 0 issues'

        Write-Step '门禁 B：全量 flutter test'
        flutter test 2>&1 | Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0) { throw 'flutter test 未通过' }

        Write-Step '门禁 C：scripts/verify.ps1（仓库聚合门禁）'
        Pop-Location
        & pwsh -NoProfile -File (Join-Path $root 'scripts/verify.ps1') 2>&1 |
            Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0) { throw 'verify.ps1 未通过' }
    }
    finally { Pop-Location -ErrorAction SilentlyContinue }

    Write-Step "构建（含 origin/aapt/libapp 守卫）"
    & pwsh -NoProfile -File (Join-Path $root 'scripts/build_mobile_public_domain.ps1') `
        -SygnalUrl 'https://liuhetong888.com' -GetuiUrl 'https://liuhetong888.com'
    if ($LASTEXITCODE -ne 0) { throw 'APK 构建失败' }
}

# ── 1) 本地产物核对 ──────────────────────────────────────────────────
Write-Step '本地产物核对（三 ABI + SHA256）'
$localHashes = @{}
foreach ($abi in $abiMap.Keys) {
    $apk = Join-Path $apkDir "ChatFlow-$Version-$abi.apk"
    if (-not (Test-Path -LiteralPath $apk)) { throw "缺少产物：$apk（先构建或去掉 -SkipBuild）" }
    $localHashes[$abi] = (Get-FileHash -Algorithm SHA256 $apk).Hash.ToLower()
    Write-Host "  $abi : $($localHashes[$abi])"
}

# ── 2) 上传 + 别名 + 哈希核对 + 回滚清理（单次 SSH 批处理）──────────
Write-Step '上传三 ABI → 服务器'
Invoke-Remote -Label 'upload' -Action {
    $files = $abiMap.Keys | ForEach-Object { Join-Path $apkDir "ChatFlow-$Version-$_.apk" }
    & scp -P $sshPort -o BatchMode=yes -o ConnectTimeout=30 @files "${sshTarget}:$downloadsDir/"
    if ($LASTEXITCODE -ne 0) { throw 'scp 上传失败' }
} | Out-Null

Write-Step '服务器端：SHA256 核对 + ln -sfn 别名 + 回滚保留'
$keepFlag = if ($KeepPrevious) { 'true' } else { 'false' }
Invoke-Remote -Label 'server-side' -Action {
    $hashChecks = ($abiMap.GetEnumerator() | ForEach-Object {
        "if ! echo `"$($localHashes[$_.Key])  ChatFlow-$Version-$($_.Key).apk`" | sha256sum -c - >/dev/null 2>&1; then echo HASH_MISMATCH_$($_.Key); exit 1; fi"
    }) -join ' && '
    $aliasCmds = ($abiMap.Keys | ForEach-Object {
        "ln -sfn ChatFlow-$Version-$_.apk latest-$_.apk"
    }) -join ' && '
    & ssh -p $sshPort -o BatchMode=yes -o ConnectTimeout=30 $sshTarget @"
set -e
cd $downloadsDir
$hashChecks
$aliasCmds
KEEP=$keepFlag VERSION=$Version bash -c '
  if [ "`$KEEP" = "true" ]; then
    # 保留策略：保留上一发布版（按 versionCode 数字序取次新），清理更旧版本
    ls ChatFlow-*.apk | sed "s/ChatFlow-\(.*\)-\(arm64\|arm32\|x86_64\).apk/\1/" | sort -uV | head -n -1 | while read -r old; do
      [ "`$old" = "`$VERSION" ] && continue
      rm -f ChatFlow-`$old-*.apk
      echo "cleaned: `$old"
    done
  fi
'
echo SHA256_ALIASES_OK
ls -l latest-*.apk | awk "{print \`$9, \"->\", \`$11}"
"@
    if ($LASTEXITCODE -ne 0) { throw '服务器端核对/别名失败' }
}

# ── 3) 发布（业务 API PUT）──────────────────────────────────────────
$idempotencyKey = "app-update-publish-$Version-$(Get-Date -Format 'yyyyMMdd')"
if (-not $SkipPublish) {
    Write-Step "发布（幂等键 $idempotencyKey）"
    # Python 单引号字符串安全：' → \'（.Replace 避免 -replace 的正则/引号陷阱）
    $notesEscaped = $Notes.Replace("'", "\'")
    $publishScript = @"
import json, os, sys, urllib.error, urllib.request
from datetime import datetime, timezone
from uuid import uuid4

sys.path.insert(0, '/opt/business-api')
from sqlalchemy import create_engine, text
from app.core.config import Settings
from app.core.database import create_session_factory

RELEASE_VERSION = '$Version'
RELEASE_BUILD = $expectedBuild
MIN_SUPPORTED_BUILD = 3
IDEMPOTENCY_KEY = '$idempotencyKey'
APK_URL = '$publicBase/ChatFlow-$Version-arm64.apk'
NOTES = '$notesEscaped'

settings = Settings(_env_file=None, environment='production')
engine = create_engine(os.environ['BUSINESS_DATABASE_URL'])
factory = create_session_factory(engine)
now = datetime.now(timezone.utc)
with factory() as session:
    row = session.execute(text(
        "select u.id, d.id as device_id, f.id as family_id from users u "
        "join user_roles r on r.user_id = u.id and r.role_code = 'SUPER_ADMIN' "
        "join identity_devices d on d.user_id = u.id and d.revoked_at is null "
        "join refresh_token_families f on f.device_id = d.id and f.revoked_at is null "
        "where u.username = 'liuhetong_admin' and u.status = 'ACTIVE' limit 1"
    )).first()
    assert row, 'no super-admin session'
    user_id, device_id, family_id = row

import jwt
claims = {'sub': user_id, 'device_id': device_id, 'family_id': family_id,
          'iss': os.environ.get('BUSINESS_JWT_ISSUER', 'liuhetong'),
          'iat': int(now.timestamp()), 'exp': int(now.timestamp()) + 300,
          'jti': str(uuid4())}
token = jwt.encode(claims, os.environ['BUSINESS_JWT_SECRET'], algorithm='HS256')
headers = {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json',
           'Idempotency-Key': IDEMPOTENCY_KEY}

def call(method, path, payload=None):
    req = urllib.request.Request('http://127.0.0.1:8082' + path,
        data=json.dumps(payload).encode() if payload else None, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as r: return r.status, json.load(r)
    except urllib.error.HTTPError as e: return e.code, json.loads(e.read() or b'{}')

_, before = call('GET', '/api/v1/admin/app-update-settings')
print('BEFORE', json.dumps(before, ensure_ascii=False))
status, published = call('PUT', '/api/v1/admin/app-update-settings', {
    'latest_version': RELEASE_VERSION, 'latest_build': RELEASE_BUILD,
    'min_supported_build': MIN_SUPPORTED_BUILD, 'notes': NOTES, 'apk_url': APK_URL})
print('PUBLISH', status, json.dumps(published, ensure_ascii=False))
status, latest = call('GET', '/api/v1/app-updates/latest')
print('LATEST', status, json.dumps(latest, ensure_ascii=False))
ok = (status == 200 and latest.get('configured') and
      latest.get('latest_version') == RELEASE_VERSION and
      latest.get('latest_build') == RELEASE_BUILD and latest.get('apk_url') == APK_URL)
print('PUBLISH_RESULT', 'PASS' if ok else 'FAIL')
if not ok: raise SystemExit(1)
"@
    $publishOutput = Invoke-Remote -Label 'publish' -Action {
        # 先落本地临时文件再 scp（避免 stdin 管道与引号歧义）
        $tmpLocal = Join-Path $env:TEMP "release_publish_$Version.py"
        Set-Content -LiteralPath $tmpLocal -Value $publishScript -Encoding UTF8
        $tmpRemote = "/tmp/release_publish_$Version.py"
        & scp -P $sshPort -o BatchMode=yes -o ConnectTimeout=30 $tmpLocal "${sshTarget}:$tmpRemote"
        if ($LASTEXITCODE -ne 0) { throw 'publish 脚本上传失败' }
        & ssh -p $sshPort -o BatchMode=yes -o ConnectTimeout=30 $sshTarget `
            "docker exec -i starchat-business-api-1 python - < $tmpRemote"
        if ($LASTEXITCODE -ne 0) { throw 'publish 执行失败' }
    }
    $publishOutput | ForEach-Object { Write-Host "  $_" }
    if (($publishOutput -join "`n") -notmatch 'PUBLISH_RESULT PASS') {
        throw 'PUBLISH_RESULT 非 PASS——检查 BEFORE/LATEST 输出'
    }
} else {
    Write-Host '已按 -SkipPublish 跳过发布（包已上传+别名就绪）' -ForegroundColor Yellow
}

# ── 4) 公网回拉三重验证 ──────────────────────────────────────────────
Write-Step '公网回拉验证（SHA256 + aapt versionCode）'
$pullback = Join-Path $env:TEMP "pullback-$Version-arm64.apk"
Invoke-Remote -Label 'pullback' -Action {
    & curl.exe -sS -o $pullback -C - "$publicBase/ChatFlow-$Version-arm64.apk" --max-time 480
    if ($LASTEXITCODE -ne 0) { throw '公网下载失败' }
} | Out-Null
$pullbackHash = (Get-FileHash -Algorithm SHA256 $pullback).Hash.ToLower()
if ($pullbackHash -ne $localHashes['arm64']) { throw "回拉 SHA256 不一致：$pullbackHash" }
Write-Host "  SHA256 一致：$pullbackHash"

$aapt = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Android\Sdk\build-tools') -Filter 'aapt.exe' -Recurse -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
$badging = & $aapt dump badging $pullback 2>$null | Select-Object -First 1
if ($badging -notmatch "versionCode='$versionCodeArm64' versionName='$Version'") {
    throw "回拉 aapt 版本不符：$badging"
}
Write-Host "  aapt：versionCode=$versionCodeArm64 versionName=$Version"

# ── 5) 摘要与落档 ────────────────────────────────────────────────────
$stamp = Get-Date -Format 'yyyy-MM-dd'
$artifactDir = Join-Path $root "docs/verification/artifacts/$(Get-Date -Format 'yyyy-MM-dd')"
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
$summary = @"
RELEASE $Version+$expectedBuild ($stamp)
arm64 SHA256: $($localHashes['arm64'])
arm32 SHA256: $($localHashes['arm32'])
x86_64 SHA256: $($localHashes['x86_64'])
Idempotency-Key: $idempotencyKey
Publish: $(if ($SkipPublish) { 'SKIPPED (-SkipPublish)' } else { 'PASS' })
Pull-back: SHA256 + aapt ${versionCodeArm64}/${Version} VERIFIED
Rollback: 上一版保留于 $downloadsDir（PUT 回上一版 + ln -sfn 指回即可回滚）
"@
$summary | Tee-Object -FilePath (Join-Path $artifactDir "release-$Version.log") | Write-Host

Write-Step "发布完成：$Version（build $expectedBuild / arm64 $versionCodeArm64）"
