# Executes only the extracted preflight function with a local synthetic command.
# Never calls adb, builds, maps drives or touches any device.
param([Parameter(Mandatory)][string]$Helper, [Parameter(Mandatory)][string]$Evidence)
$ErrorActionPreference='Stop'
$utf8=[System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=$utf8
[Console]::OutputEncoding=$utf8
$OutputEncoding=$utf8
$env:PYTHONUTF8='1'
$env:PYTHONIOENCODING='utf-8'
$tokens=$null
$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($Helper,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Helper does not parse'}
$fn=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq 'Assert-EmptyFixturePackage'},$true)
if(!$fn){throw 'Expected isolated preflight function missing'}
$probe=$fn.Body.GetScriptBlock()
$adb='Invoke-SyntheticAdb'
$device='emulator-5558'
$package='com.liuhetong.mobile.debug'
function Invoke-SyntheticAdb {
  $global:LASTEXITCODE=0
  if($args -contains 'get-state'){
    if($script:scenario-eq 'offline'){$global:LASTEXITCODE=1; return 'offline'}
    return 'device'
  }
  if(!($args -contains 'packages')){throw 'Unexpected mocked command'}
  switch($script:scenario){
    'installed' {return "package:$package"}
    'retained-data' {if($args -contains '-u'){return "package:$package"}; return}
    'inspection-failed' {$global:LASTEXITCODE=1; return}
    'different-package' {return "package:$package.extra"}
    'empty' {return}
    default {throw 'Unexpected synthetic scenario'}
  }
}
$results=@()
foreach($case in @(
  @{scenario='empty';reject=$false},
  @{scenario='installed';reject=$true},
  @{scenario='retained-data';reject=$true},
  @{scenario='offline';reject=$true},
  @{scenario='inspection-failed';reject=$true},
  @{scenario='different-package';reject=$false}
)){
  $script:scenario=$case.scenario
  $rejected=$false
  try {& $probe} catch {$rejected=$true}
  $results+=@{scenario=$case.scenario;expected_rejection=$case.reject;actual_rejection=$rejected;passed=($rejected-eq $case.reject)}
}
$report=@{helper_workspace_sha256=(Get-FileHash -LiteralPath $Helper -Algorithm SHA256).Hash.ToLowerInvariant();scope='synthetic local function only; no device commands';cases=$results}
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Evidence -Encoding utf8NoBOM
$report | ConvertTo-Json -Depth 5
if($results.passed -contains $false){exit 1}
