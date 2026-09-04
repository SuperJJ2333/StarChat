<#
.SYNOPSIS
    CI 发布（本地只触发）：tag 推送 → GitHub Actions 签名构建 → GitHub
    Release → 服务器下行拉取部署 →（人工确认后）publish 更新弹窗 → 公网回拉验证。

.DESCRIPTION
    替代 release.ps1 的"本地上传 180MB"环节：GitHub Actions 在云端构建
    签名包并挂到不可变 tag 的 Release；服务器从 GitHub 下行拉取（公开
    仓库匿名下载，数据中心下行带宽 >> 本地上行）。

    分工：
    - 本机：版本预检 → tag v<X.Y.Z> 推送（触发 android-release.yml）→
      轮询 Release 资产就绪 → scp 三个脚本到服务器 → ssh 执行
      server_pull_release.sh（sha256 校验+部署+别名+可选 publish）→
      本地公网回拉 SHA256+aapt 双验。
    - GitHub：签名构建（含 origin/aapt/libapp 守卫）+ Release 创建。
    - 服务器：下行拉取 + 部署 + publish（business API）。

    红线：publish 默认不执行（-SkipPublish 显式跳过、默认执行——发布
    由"运行本命令"这个人工动作触发）；工作树必须干净（CI 构建的是 git
    内容，本地脏文件不会进包——与 release.ps1 本地构建不同，必须防
    "测过的和发出去的不一致"）。

.PARAMETER Version
    要发布的版本（X.Y.Z）。必须等于 pubspec.yaml 与 app_config.dart
    （三方一致预检）。

.PARAMETER Notes
    更新弹窗文案（用户可见）。

.PARAMETER SkipPublish
    只部署包+别名，不调用 publish API（准备模式）。

.EXAMPLE
    pwsh -File scripts/release_ci.ps1 -Version 0.3.36 -Notes "0.3.36 更新：……"
#>
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Notes,
    [switch]$SkipPublish
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$mobileRoot = Join-Path $root 'apps/mobile_flutter'
$repoSlug = 'SuperJJ2333/StarChat'
$sshTarget = 'root@207.56.8.8'
$sshPort = '23421'
$publicBase = 'https://www.liuhetong888.com/downloads'

function Write-Step([string]$msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

function Invoke-Remote([scriptblock]$Action, [string]$Label) {
    $delays = @(0, 30, 120, 300, 540)
    foreach ($delay in $delays) {
        if ($delay -gt 0) {
            Write-Host "  [$Label] 连接被限流，退避 ${delay}s 后重试…" -ForegroundColor Yellow
            Start-Sleep -Seconds $delay
        }
        try { return & $Action }
        catch {
            if ($_.Exception.Message -match 'Connection reset|Connection refused|timed out') { continue }
            throw
        }
    }
    throw "[$Label] 远程操作在退避重试后仍失败"
}

# ── 0) 预检：三方版本一致 + 工作树干净 ───────────────────────────────
Write-Step "预检：版本 $Version"
$pubspec = Get-Content -LiteralPath (Join-Path $mobileRoot 'pubspec.yaml') -Raw -Encoding UTF8
if ($pubspec -notmatch "(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$") {
    throw 'pubspec.yaml must declare version: X.Y.Z+build'
}
$pubVersion, $pubBuild = $Matches[1], [int]$Matches[2]
if ($pubVersion -ne $Version) { throw "pubspec=$pubVersion ≠ 请求 $Version（先递增 pubspec + app_config.dart）" }
$appConfig = Get-Content -LiteralPath (Join-Path $mobileRoot 'lib/core/app_config.dart') -Raw -Encoding UTF8
if ($appConfig -notmatch [regex]::Escape("appVersionName = '$Version'") -or
    $appConfig -notmatch "appBuildNumber = $pubBuild") {
    throw 'app_config.dart 与 pubspec 版本不一致'
}

# CI 构建的是 git 内容：脏文件不会进包（与本地构建的本质差异）。
$dirty = & git -C $root status --porcelain -- apps/mobile_flutter .github scripts services docker-compose.yml
if ($dirty) {
    Write-Host $dirty
    throw '工作树有未提交变更（上面列出）。CI 只会构建已提交内容——先 commit（保证"测过的=发出的"）再发布。'
}

$tag = "v$Version"
$tagSha = & git -C $root rev-parse -q --verify "refs/tags/$tag^{commit}"
if (-not $tagSha) { throw "缺少 tag $tag（git tag $tag && git push origin main $tag）" }

# ── 1) 轮询 GitHub Release 资产就绪（tag 触发的构建约 15-25 分钟）────
Write-Step "等待 GitHub Actions 构建 + Release $tag 资产"
$deadline = (Get-Date).AddMinutes(45)
$assets = $null
while ((Get-Date) -lt $deadline) {
    # 404（Release 未建）会抛异常——必须 try/catch，SilentlyContinue 压不住。
    $rel = $null
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repoSlug/releases/tags/$tag" `
            -Headers @{ 'User-Agent' = 'starchat-release-ci' }
    } catch { $rel = $null }
    if ($rel -and $rel.assets) {
        $names = @($rel.assets | ForEach-Object { $_.name })
        $need = @("ChatFlow-$Version-arm64.apk", "ChatFlow-$Version-arm32.apk",
                  "ChatFlow-$Version-x86_64.apk", 'SHA256SUMS')
        $missing = @($need | Where-Object { $names -notcontains $_ })
        if (-not $missing) { $assets = $rel.assets; break }
        Write-Host "  资产不全（缺：$($missing -join ', ')），继续等待…"
    } else {
        # 打印一次最近运行状态（公开仓库可匿名查询）
        $runs = $null
        try {
            $runs = Invoke-RestMethod -Uri "https://api.github.com/repos/$repoSlug/actions/runs?event=push&per_page=1" `
                -Headers @{ 'User-Agent' = 'starchat-release-ci' }
        } catch { $runs = $null }
        if ($runs -and $runs.workflow_runs) {
            $r = $runs.workflow_runs[0]
            Write-Host "  最新运行：$($r.name) [$($r.status)/$($r.conclusion)] $($r.html_url)"
            if ($r.status -eq 'completed' -and $r.conclusion -ne 'success') {
                throw "构建失败（$($r.conclusion)）：$($r.html_url)"
            }
        }
    }
    Start-Sleep -Seconds 60
}
if (-not $assets) { throw "等待 Release $tag 资产超时（45 分钟）——检查 Actions 运行" }
Write-Host "  Release $tag 就绪：$(@($assets | ForEach-Object { $_.name }) -join ', ')"

# ── 2) 服务器下行拉取（scp 三个小脚本 + ssh 执行）────────────────────
Write-Step '服务器下行拉取部署'
$notesLocal = Join-Path $env:TEMP "release-notes-$Version.txt"
[IO.File]::WriteAllText($notesLocal, $Notes, [Text.UTF8Encoding]::new($false))
$publishArgs = ''
if (-not $SkipPublish) {
    $publishArgs = "--publish --notes-file /tmp/notes-$Version.txt --publish-script /tmp/publish_app_update.py --build $pubBuild"
}
$output = Invoke-Remote -Label 'server-pull' -Action {
    & scp -P $sshPort -o BatchMode=yes -o ConnectTimeout=30 `
        (Join-Path $root 'scripts/server_pull_release.sh') `
        (Join-Path $root 'scripts/publish_app_update.py') `
        "${sshTarget}:/tmp/"
    if ($LASTEXITCODE -ne 0) { throw 'scp 脚本上传失败' }
    & scp -P $sshPort -o BatchMode=yes -o ConnectTimeout=30 `
        $notesLocal "${sshTarget}:/tmp/notes-$Version.txt"
    if ($LASTEXITCODE -ne 0) { throw 'scp 文案上传失败' }
    & ssh -p $sshPort -o BatchMode=yes -o ConnectTimeout=30 $sshTarget `
        "bash /tmp/server_pull_release.sh $Version $publishArgs"
    if ($LASTEXITCODE -ne 0) { throw '服务器拉取部署失败' }
}
$output | ForEach-Object { Write-Host "  $_" }
if ((($output -join "`n") -notmatch 'PULL_DEPLOY_OK') -or
    ((-not $SkipPublish) -and (($output -join "`n") -notmatch 'PUBLISH_RESULT PASS'))) {
    throw '服务器侧结果缺少 PULL_DEPLOY_OK / PUBLISH_RESULT PASS——检查上方输出'
}

# ── 3) 公网回拉验证（SHA256 对照 GitHub Release + aapt versionCode）──
Write-Step '公网回拉验证'
$releaseSums = Invoke-RestMethod -Uri "https://github.com/$repoSlug/releases/download/$tag/SHA256SUMS"
$arm64Hash = ($releaseSums -split "`n" | Where-Object { $_ -match "ChatFlow-$Version-arm64\.apk" }) -split '\s+' | Select-Object -First 1
if (-not $arm64Hash) { throw 'SHA256SUMS 缺 arm64 条目' }

$pullback = Join-Path $env:TEMP "pullback-ci-$Version-arm64.apk"
Invoke-Remote -Label 'pullback' -Action {
    & curl.exe -sS -o $pullback -C - "$publicBase/ChatFlow-$Version-arm64.apk" --max-time 480
    if ($LASTEXITCODE -ne 0) { throw '公网下载失败' }
} | Out-Null
$pullbackHash = (Get-FileHash -Algorithm SHA256 $pullback).Hash.ToLower()
if ($pullbackHash -ne $arm64Hash) { throw "回拉 SHA256 与 GitHub Release 不一致：$pullbackHash ≠ $arm64Hash" }
Write-Host "  SHA256 与 GitHub Release 一致：$pullbackHash"

$aapt = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Android\Sdk\build-tools') -Filter 'aapt.exe' -Recurse -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
$badging = & $aapt dump badging $pullback 2>$null | Select-Object -First 1
$versionCodeArm64 = 2000 + $pubBuild
if ($badging -notmatch "versionCode='$versionCodeArm64' versionName='$Version'") {
    throw "回拉 aapt 版本不符：$badging"
}
Write-Host "  aapt：versionCode=$versionCodeArm64 versionName=$Version"

# ── 4) 落档 ──────────────────────────────────────────────────────────
$stamp = Get-Date -Format 'yyyy-MM-dd'
$artifactDir = Join-Path $root "docs/verification/artifacts/$stamp"
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
$summary = @"
RELEASE-CI $Version+$pubBuild ($stamp)
Path: tag $tag -> GitHub Actions build -> GH Release -> server pull
GitHub Release arm64 SHA256: $arm64Hash
Publish: $(if ($SkipPublish) { 'SKIPPED' } else { 'PASS' })
Pull-back: SHA256(vs GH Release) + aapt ${versionCodeArm64}/$Version VERIFIED
"@
$summary | Tee-Object -FilePath (Join-Path $artifactDir "release-ci-$Version.log") | Write-Host

Write-Step "CI 发布完成：$Version（build $pubBuild / arm64 $versionCodeArm64）"
