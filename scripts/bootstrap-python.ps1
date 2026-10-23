param([string]$VenvPath = '', [string]$BasePython = '')

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $VenvPath) { $VenvPath = Join-Path $projectRoot '.venv312' }
$VenvPath = [IO.Path]::GetFullPath($VenvPath)
if (Test-Path -LiteralPath $VenvPath) {
    throw 'Environment path already exists. Verify it or choose a new path; bootstrap never overwrites environments.'
}
if (-not $BasePython) {
    $BasePython = (& py -3.12 -c 'import sys; print(sys.executable)')
    if ($LASTEXITCODE -ne 0) { throw 'Python 3.12 launcher lookup failed' }
}
& $BasePython -c 'import sys; sys.exit(0 if sys.version_info[:2] == (3, 12) and not sys.flags.optimize else "Unoptimized Python 3.12 required")'
if ($LASTEXITCODE -ne 0) { throw 'Base interpreter must be Python 3.12 without -O or PYTHONOPTIMIZE' }
& $BasePython -m venv $VenvPath
if ($LASTEXITCODE -ne 0) { throw 'venv creation failed' }
$python = Join-Path $VenvPath $(if ($IsWindows) { 'Scripts/python.exe' } else { 'bin/python' })
$lock = Join-Path $VenvPath 'requirements.development.lock'
& $python (Join-Path $PSScriptRoot 'python_environment.py') lock --output $lock
if ($LASTEXITCODE -ne 0) { throw 'Platform lock generation failed' }
& $python -m pip install --disable-pip-version-check --no-deps -r $lock
if ($LASTEXITCODE -ne 0) { throw 'Locked install failed; partial environment retained for diagnosis' }
& $python -m pip check
if ($LASTEXITCODE -ne 0) { throw 'Installed dependency graph is incomplete' }
& $python (Join-Path $PSScriptRoot 'python_environment.py') check
if ($LASTEXITCODE -ne 0) { throw 'Installed environment does not match locks' }
Write-Output "Python environment ready: $python"
