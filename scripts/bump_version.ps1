<#
.SYNOPSIS
    发版升版单入口：pubspec.yaml 与 app_config.dart 成对改写，并立即运行版本契约门禁。

.DESCRIPTION
    0.3.90/2114 以来连续四次发版只改 pubspec 漏改 app_config.dart（2115、
    2116、2117、2118），每次都打红 android-ci 的 build-contract 门禁。本
    脚本把两处改写合并为一条命令，杜绝只改一半；改完自动运行
    tests/mobile/test_app_build_contract.py。发布发布仍走 release.ps1，
    其预检会再校验一次三方一致。

.PARAMETER Version
    目标版本，X.Y.Z+build，与 pubspec.yaml 的 version: 行同格式。

.EXAMPLE
    pwsh -File scripts/bump_version.ps1 -Version 0.3.91+2118
#>
param(
    [Parameter(Mandatory = $true)][string]$Version
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

if ($Version -notmatch '^\d+\.\d+\.\d+\+\d+$') {
    throw "版本格式必须是 X.Y.Z+build，收到：'$Version'"
}
$name, $build = $Version.Split('+')

$root = Split-Path -Parent $PSScriptRoot
$pubspecPath = Join-Path $root 'apps/mobile_flutter/pubspec.yaml'
$configPath = Join-Path $root 'apps/mobile_flutter/lib/core/app_config.dart'

# 保留各文件原有 BOM 状态；替换全部是单行文本，不引入换行符差异。
function Get-TextEncoding {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.UTF8Encoding]::new($true)
    }
    return [System.Text.UTF8Encoding]::new($false)
}

$pubspec = [System.IO.File]::ReadAllText($pubspecPath)
$config = [System.IO.File]::ReadAllText($configPath)

$versionLine = [regex]::Matches($pubspec, '(?m)(?<=^version:[ \t])\d+\.\d+\.\d+\+\d+(?=[ \t]*\r?$)')
if ($versionLine.Count -ne 1) { throw 'pubspec.yaml 必须恰好声明一行 version: X.Y.Z+build' }
$nameDecl = [regex]::Matches($config, "appVersionName[ \t]*=[ \t]*'[^']+'")
if ($nameDecl.Count -ne 1) { throw 'app_config.dart 必须恰好声明一处 appVersionName' }
$buildDecl = [regex]::Matches($config, 'appBuildNumber[ \t]*=[ \t]*\d+')
if ($buildDecl.Count -ne 1) { throw 'app_config.dart 必须恰好声明一处 appBuildNumber' }

$changed = @()
if ($versionLine[0].Value -cne $Version) {
    $pubspecNew = [regex]::Replace($pubspec, '(?m)(?<=^version:[ \t])\d+\.\d+\.\d+\+\d+(?=[ \t]*\r?$)', $Version)
    if ($pubspecNew -ceq $pubspec) { throw 'pubspec.yaml 替换失败——格式漂移？请人工检查' }
    $pubspecEncoding = Get-TextEncoding $pubspecPath
    [System.IO.File]::WriteAllText($pubspecPath, $pubspecNew, $pubspecEncoding)
    $changed += 'pubspec.yaml'
}
if ($nameDecl[0].Value -cne "appVersionName = '$name'") {
    $configNew = [regex]::Replace($config, "appVersionName[ \t]*=[ \t]*'[^']+'", "appVersionName = '$name'")
    if ($configNew -ceq $config) { throw 'app_config.dart appVersionName 替换失败——格式漂移？请人工检查' }
    $config = $configNew
    $configChanged = $true
}
if ($buildDecl[0].Value -cne "appBuildNumber = $build") {
    $configNew = [regex]::Replace($config, 'appBuildNumber[ \t]*=[ \t]*\d+', "appBuildNumber = $build")
    if ($configNew -ceq $config) { throw 'app_config.dart appBuildNumber 替换失败——格式漂移？请人工检查' }
    $config = $configNew
    $configChanged = $true
}
if ($configChanged) {
    $configEncoding = Get-TextEncoding $configPath
    [System.IO.File]::WriteAllText($configPath, $config, $configEncoding)
    $changed += 'app_config.dart'
}
if ($changed.Count -eq 0) {
    Write-Host "已是目标版本 $Version，无文件改动。"
} else {
    Write-Host ("已更新：{0} → {1}" -f ($changed -join ' + '), $Version)
}

Push-Location $root
try {
    python -m pytest tests/mobile/test_app_build_contract.py -q
    if ($LASTEXITCODE -ne 0) {
        throw "版本契约测试未通过（exit $LASTEXITCODE），请检查两个文件的当前状态"
    }
    Write-Host '版本契约门禁：PASS'
} finally {
    Pop-Location
}
