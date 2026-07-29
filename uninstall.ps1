# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Remove one greenroom instance.

.DESCRIPTION
  Unregisters the scheduled task and, by default, stops the running session and
  its watchdog. The working directory is never touched -- it holds your work.
  Shared scripts in the install dir are left alone unless -RemoveScripts and no
  other instance remains.

.EXAMPLE
  .\uninstall.ps1 -Instance desktop-admin
  .\uninstall.ps1 -Instance desktop-admin -KeepState
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Instance,
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.local\bin\greenroom'),
    [switch]$KeepState,
    [switch]$RemoveScripts
)

$ErrorActionPreference = 'Stop'
function Ok($m)   { Write-Host "  OK    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  WARN  $m" -ForegroundColor Yellow }

$TaskName = "greenroom-$Instance"
$stateDir = Join-Path $env:USERPROFILE ".claude\greenroom\$Instance"

Write-Host ''
Write-Host "=== removing greenroom instance '$Instance' ==="

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask  -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Ok "task removed: $TaskName"
} else {
    Warn "no scheduled task named $TaskName"
}

# Stop the watchdog for THIS instance only. It is a pwsh process whose command
# line carries both the watchdog script and this instance name.
$wd = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -match 'greenroom-watchdog\.ps1' -and
            $_.CommandLine -match ('-Instance\s+"?' + [regex]::Escape($Instance) + '("|\s|$)')
        })
foreach ($p in $wd) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Ok "watchdog stopped (pid $($p.ProcessId))"
}
if (-not $wd) { Warn 'no watchdog process found for this instance' }

# Stop the session itself. Filter by the instance token -- NEVER by process name.
# Several distinct claude.exe binaries exist on a machine with Claude Desktop
# installed, and 'Stop-Process -Name claude' would take out unrelated sessions.
$sess = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
          Where-Object { $_.CommandLine -match ('--remote-control\s+"?' + [regex]::Escape($Instance) + '("|\s|$)') })
foreach ($p in $sess) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    Ok "session stopped (claude pid $($p.ProcessId))"
}
if (-not $sess) { Warn 'no running session found for this instance' }

if ($KeepState) {
    Warn "state kept: $stateDir"
} elseif (Test-Path $stateDir) {
    Remove-Item $stateDir -Recurse -Force
    Ok "state removed: $stateDir"
}

if ($RemoveScripts) {
    $others = @(Get-ScheduledTask -TaskName 'greenroom-*' -ErrorAction SilentlyContinue)
    if ($others.Count -gt 0) {
        Warn "not removing scripts -- $($others.Count) other instance(s) still registered: $($others.TaskName -join ', ')"
    } elseif (Test-Path $InstallDir) {
        Remove-Item $InstallDir -Recurse -Force
        Ok "internals removed: $InstallDir"
        $shimDir = Split-Path $InstallDir -Parent
        foreach ($f in 'greenroom.ps1', 'greenroom.cmd') {
            $p = Join-Path $shimDir $f
            if (Test-Path $p) { Remove-Item $p -Force; Ok "removed: $p" }
        }
    }
}

Write-Host ''
Write-Host 'Working directory left in place. Trust entries in ~/.claude.json left in place.'
