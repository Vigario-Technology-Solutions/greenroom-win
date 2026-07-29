# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Supervisor for one greenroom instance.

  Requirement: the session is not allowed to be down. If the Windows Terminal
  window is closed accidentally instead of detached, the session must come back
  within a second or two, without any window ever appearing.

  Design:
    - This watchdog is itself launched hidden by greenroom-watchdog.vbs (wscript
      is GUI-subsystem, and Run(cmd,0,False) passes SW_HIDE at process creation).
    - It launches the session as a Windows Terminal window that is ALSO born
      hidden, via Start-Process -WindowStyle Hidden. WT honours it, and the
      hidden window can still be revealed later by greenroom.ps1.
    - It watches the claude.exe PID directly. Get-Process -Id is cheap enough to
      poll once a second; the expensive CIM query only runs on a restart.

  Windows Terminal is required rather than conhost: conhost does no font
  fallback, and no console-registerable font contains the glyphs the TUI draws.

  MULTI-INSTANCE: every process lookup is filtered on '--remote-control <name>'
  so several instances can be supervised on one host without stealing each
  other's sessions. A watchdog that matched bare '--remote-control' would adopt
  whichever session it saw first and then fight the other watchdog over it.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Instance)

$ErrorActionPreference = 'Continue'

$stateDir = Join-Path $env:USERPROFILE ".claude\greenroom\$Instance"
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$log = Join-Path $stateDir 'watchdog.log'

function Log($m) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')  $m" | Add-Content -Path $log -Encoding UTF8
    # keep the log from growing without bound across months of uptime
    $item = Get-Item $log -ErrorAction SilentlyContinue
    if ($item -and $item.Length -gt 512KB) {
        $tail = Get-Content $log -Tail 500
        Set-Content -Path $log -Value $tail -Encoding UTF8
    }
}

$cfgPath = Join-Path $stateDir 'config.json'
if (-not (Test-Path $cfgPath)) {
    Log "FATAL: no config at $cfgPath -- run install.ps1 for this instance"
    exit 1
}
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json

$wt      = $cfg.wt
$pwsh    = $cfg.pwsh
$inner   = Join-Path $PSScriptRoot 'greenroom-launch.ps1'
$POLL_MS = 1000

# Anchored so 'admin' cannot match an instance called 'admin-2'.
$cmdPattern = '--remote-control\s+"?' + [regex]::Escape($Instance) + '("|\s|$)'

Log "=== watchdog start, pid $PID, instance '$Instance' ==="
Log "     cwd=$($cfg.workingDirectory)  claude=$($cfg.claudeExe)"

function Get-RcClaudePid {
    $p = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
         Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $cmdPattern } |
         Select-Object -First 1
    if ($p) { $p.ProcessId } else { $null }
}

function Start-RcSession {
    # -w new forces its own window instead of a tab in an existing terminal.
    $args_ = @('-w', 'new', $pwsh, '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
               '-File', $inner, '-Instance', $Instance)
    Start-Process -FilePath $wt -ArgumentList $args_ -WindowStyle Hidden
    Log 'launched WT session (hidden)'
}

$sessionPid   = $null
$restarts     = @()   # timestamps, for backoff
$backoffUntil = [datetime]::MinValue

while ($true) {
    try {
        $alive = $false
        if ($sessionPid) {
            $alive = [bool](Get-Process -Id $sessionPid -ErrorAction SilentlyContinue)
        }

        if (-not $alive) {
            # confirm via command line before declaring it dead -- it may have been
            # restarted by something else, or our recorded pid may be stale.
            $found = Get-RcClaudePid
            if ($found) {
                if ($found -ne $sessionPid) { Log "adopted existing session, claude pid $found" }
                $sessionPid = $found
            }
            elseif ((Get-Date) -lt $backoffUntil) {
                # in backoff, do nothing this tick
            }
            else {
                if ($sessionPid) { Log "session pid $sessionPid is gone -- restarting" }
                else { Log 'no session running -- starting' }

                Start-RcSession

                # wait for it to come up and record the new pid
                $deadline = (Get-Date).AddSeconds(45)
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Milliseconds 500
                    $found = Get-RcClaudePid
                    if ($found) { $sessionPid = $found; Log "session up, claude pid $found"; break }
                }
                if (-not $found) { Log 'session did NOT come up within 45s'; $sessionPid = $null }

                # crash-loop guard: >5 restarts in 5 minutes -> back off 2 minutes
                $now = Get-Date
                $restarts = @($restarts | Where-Object { $_ -gt $now.AddMinutes(-5) })
                $restarts += $now
                if ($restarts.Count -gt 5) {
                    $backoffUntil = $now.AddMinutes(2)
                    Log "crash loop detected ($($restarts.Count) restarts in 5 min) -- backing off until $backoffUntil"
                    $restarts = @()
                }
            }
        }
    } catch {
        Log "watchdog error: $_"
    }

    Start-Sleep -Milliseconds $POLL_MS
}
