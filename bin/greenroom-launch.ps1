# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Inner launcher for one instance. Runs inside the hidden Windows Terminal
  window the watchdog created.

  It deliberately does NOT hide anything itself. The WT window is already born
  hidden via STARTUPINFO. Hiding the pseudo-console from in here was the mistake
  that made three earlier attempts look like they worked while a Windows Terminal
  window sat visible on screen.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Instance)

$ErrorActionPreference = 'Continue'

$stateDir = Join-Path $env:USERPROFILE ".claude\greenroom\$Instance"
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$log = Join-Path $stateDir 'launch.log'

function Log($m) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')  $m" | Add-Content -Path $log -Encoding UTF8
}

Log "--- launcher start, pid $PID, instance '$Instance' ---"

$cfgPath = Join-Path $stateDir 'config.json'
if (-not (Test-Path $cfgPath)) {
    Log "FATAL: no config at $cfgPath -- run install.ps1 for this instance"
    Start-Sleep -Seconds 10
    exit 1
}
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json

# The working directory MUST NOT be the home directory. Per the Remote Control
# docs the startup trust dialog never persists trust for a home directory, so RC
# never connects and the trust prompt repeats forever. Claude Code also keys
# project state on the literal cwd string, which is why this is set explicitly
# rather than inherited from the task or the shell.
$rcDir = $cfg.workingDirectory
if (-not (Test-Path $rcDir)) { New-Item -ItemType Directory -Path $rcDir -Force | Out-Null }
Set-Location -LiteralPath $rcDir
Log "cwd = $((Get-Location).Path)"

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    $OutputEncoding           = New-Object System.Text.UTF8Encoding $false
} catch { Log "encoding set failed: $_" }
Log "codepage = $([Console]::OutputEncoding.CodePage)"

# The instance name is passed to --remote-control on purpose. It does double duty:
# it labels the session in the Remote Control UI, and it puts a unique token in
# this process's command line so the watchdog and greenroom.ps1 can tell several
# instances on one host apart.
$claudeArgs = @('--remote-control', $Instance)

# Directory grants are PER INSTANCE and default to none. An instance launches with
# access to its working directory and nothing else unless the install granted more.
if ($cfg.additionalDirectories -and @($cfg.additionalDirectories).Count -gt 0) {
    $claudeArgs += '--add-dir'
    $claudeArgs += @($cfg.additionalDirectories)
}

Log "exec: $($cfg.claudeExe) $($claudeArgs -join ' ')"
& $cfg.claudeExe @claudeArgs
Log "claude exited with $LASTEXITCODE"
