# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Attach to / detach from a hidden greenroom session.

.DESCRIPTION
  Each logon task (greenroom-<instance>) starts a Windows Terminal window that is
  born hidden (SW_HIDE via STARTUPINFO) hosting
  `claude --remote-control <instance>`. The window exists the whole time -- it is
  simply not shown. This script finds it and toggles visibility, so `attach`
  brings up the LIVE session with its full scrollback, not a resumed copy.

  Session discovery walks UP from claude.exe to the hosting WindowsTerminal.exe,
  rather than down from a launcher. Two earlier approaches failed here:
    - matching pwsh by command line also matched shells that merely MENTIONED
      "--remote-control" (including diagnostics), picking the wrong process;
    - searching only the launcher's own descendants missed the window entirely,
      because Windows Terminal is parented to the console-handoff broker, not us.

  WINDOW RESOLUTION ON A MULTI-INSTANCE HOST: Windows Terminal hosts multiple
  windows in a SINGLE process by default, so two instances typically share one
  WindowsTerminal.exe PID. Taking the first CASCADIA window of that PID is then a
  coin flip on every attach -- the normal 2x case, not an edge case. Claude Code
  sets the window title to the working directory's leaf name, so that is used to
  disambiguate. If it still cannot be resolved uniquely, this fails loudly rather
  than acting on the wrong window.

.EXAMPLE
  greenroom list
  greenroom attach desktop-admin
  greenroom detach desktop-admin
  greenroom status
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('attach', 'detach', 'status', 'toggle', 'list')]
    [string]$Action = 'status',

    [Parameter(Position = 1)]
    [string]$Instance
)

$ErrorActionPreference = 'Stop'

# The type name carries a revision suffix on purpose. A long-lived shell that ran
# an older greenroom.ps1 already has the previous type loaded, and Add-Type cannot
# redefine a type in a live session -- so a fixed name plus a "load once" guard
# silently binds to the stale definition and fails on any member added since.
# Bump the suffix whenever the member list below changes.
if (-not ('Greenroom.Win1' -as [type])) {
    Add-Type -Namespace Greenroom -Name Win1 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
'@
}

$SW_HIDE = 0; $SW_RESTORE = 9

function Get-InstanceWorkingDirLeaf {
    param([string]$Name)
    $cfg = Join-Path $env:USERPROFILE ".claude\greenroom\$Name\config.json"
    if (-not (Test-Path $cfg)) { return $null }
    try { return Split-Path ((Get-Content $cfg -Raw | ConvertFrom-Json).workingDirectory) -Leaf }
    catch { return $null }
}

function Get-AllSessions {
    # Anchor on claude.exe itself. Excluding the current process matters: a shell
    # running this script has "--remote-control" in its own command line.
    $procs = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '--remote-control' }

    foreach ($p in $procs) {
        $name = '(unnamed)'
        if ($p.CommandLine -match '--remote-control\s+"?([^"\s-][^"\s]*)') { $name = $Matches[1] }
        [PSCustomObject]@{ Instance = $name; Claude = $p; Pid = $p.ProcessId }
    }
}

function Get-TerminalHost {
    param($ClaudeProc)
    # WindowsTerminal.exe -> OpenConsole.exe -> pwsh.exe -> claude.exe
    $cur = $ClaudeProc
    for ($i = 0; $i -lt 6 -and $cur; $i++) {
        $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($cur.ParentProcessId)" -ErrorAction SilentlyContinue
        if (-not $parent) { return $null }
        if ($parent.Name -eq 'WindowsTerminal.exe') { return $parent }
        $cur = $parent
    }
    return $null
}

function Get-CascadiaWindows {
    param([int]$HostPid)
    # The delegate executes in its own scope -- it can see neither this function's
    # locals nor its parameters. Both inputs and accumulator must be script-scoped.
    $script:grHits = @()
    $script:grPid  = $HostPid
    $cb = [Greenroom.Win1+EnumWindowsProc] {
        param($h, $l)
        $wpid = 0
        [Greenroom.Win1]::GetWindowThreadProcessId($h, [ref]$wpid) | Out-Null
        if ([int]$wpid -eq $script:grPid) {
            $sb = New-Object System.Text.StringBuilder 256
            [Greenroom.Win1]::GetClassName($h, $sb, 256) | Out-Null
            if ($sb.ToString() -match 'CASCADIA_HOSTING') {
                $tb = New-Object System.Text.StringBuilder 512
                [Greenroom.Win1]::GetWindowText($h, $tb, 512) | Out-Null
                $script:grHits += [PSCustomObject]@{ Handle = $h; Title = $tb.ToString() }
            }
        }
        return $true
    }
    [Greenroom.Win1]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    $script:grHits
}

function Resolve-SessionWindow {
    param([int]$HostPid, [string]$Name, [switch]$Quiet)

    $wins = @(Get-CascadiaWindows -HostPid $HostPid)
    if ($wins.Count -eq 0) { return $null }

    # PRIMARY. greenroom-launch.ps1 starts the session with `--name <instance>`,
    # and Claude Code renders the window title as "<glyph> <name>". That title is
    # set by Claude Code itself, so nothing has to out-fight it, and it holds even
    # after the conversation acquires its own auto-generated name.
    #
    # Anchored at the END, deliberately, for two separate reasons:
    #   - the leading glyph is an animated spinner and changes while the session
    #     works (observed as both U+2733 idle and U+2802 busy), so the front of
    #     the string is not stable to match on;
    #   - an unanchored substring would let 'admin' match 'admin-2', leaving the
    #     shorter instance permanently unresolvable. Same collision the watchdog's
    #     command-line pattern already guards against.
    $m = @($wins | Where-Object { $_.Title -match ([regex]::Escape($Name) + '$') })
    if ($m.Count -eq 1) { return $m[0].Handle }

    # Only one window under this host process, so there is nothing to confuse it
    # with. This also covers sessions started before --name was passed.
    if ($wins.Count -eq 1) { return $wins[0].Handle }

    # LEGACY FALLBACK. A session started by an older launcher carries Claude Code's
    # own title instead. Note that title is NOT the working-directory leaf -- it is
    # the conversation title, which changes as the conversation does -- so this
    # match frequently finds nothing. Restart the instance to move it onto --name.
    $leaf = Get-InstanceWorkingDirLeaf -Name $Name
    if ($leaf) {
        $m = @($wins | Where-Object { $_.Title -like "*$leaf*" })
        if ($m.Count -eq 1) { return $m[0].Handle }
    }

    if (-not $Quiet) {
        Write-Host "AMBIGUOUS: WindowsTerminal pid $HostPid owns $($wins.Count) console windows:" -ForegroundColor Yellow
        $wins | ForEach-Object { Write-Host "    handle=$($_.Handle)  title='$($_.Title)'" }
        Write-Host "  no window whose title ends with the session name '$Name'" -ForegroundColor Yellow
        Write-Host '  refusing to guess -- acting on the wrong window would hide or reveal the wrong session.' -ForegroundColor Yellow
        Write-Host "  if this instance predates --name, restart it to pick the title up:" -ForegroundColor Yellow
        Write-Host "      Start-ScheduledTask -TaskName greenroom-$Name" -ForegroundColor Yellow
    }
    return $null
}

$sessions = @(Get-AllSessions)

if ($Action -eq 'list') {
    if (-not $sessions) { Write-Host 'no greenroom sessions running.' -ForegroundColor Yellow; exit 1 }
    $sessions | ForEach-Object {
        $th = Get-TerminalHost $_.Claude
        $vis = $null; $hnd = $null
        if ($th) {
            $hnd = Resolve-SessionWindow -HostPid $th.ProcessId -Name $_.Instance -Quiet
            if ($hnd) { $vis = [Greenroom.Win1]::IsWindowVisible($hnd) }
        }
        [PSCustomObject]@{
            Instance    = $_.Instance
            ClaudePid   = $_.Pid
            TerminalPid = if ($th) { $th.ProcessId } else { $null }
            Window      = if ($hnd) { $hnd } else { 'unresolved' }
            Visible     = $vis
        }
    } | Format-Table -AutoSize
    exit 0
}

if (-not $sessions) {
    Write-Host 'no greenroom session running.' -ForegroundColor Yellow
    if ($Instance) { Write-Host "start it with:  Start-ScheduledTask -TaskName greenroom-$Instance" }
    else { Write-Host 'start one with: Start-ScheduledTask -TaskName greenroom-<instance>' }
    exit 1
}

if ($Instance) {
    $sel = @($sessions | Where-Object { $_.Instance -eq $Instance })
    if (-not $sel) {
        Write-Host "no greenroom session named '$Instance'. Running:" -ForegroundColor Yellow
        $sessions | ForEach-Object { Write-Host "  $($_.Instance)  (pid $($_.Pid))" }
        exit 1
    }
    $s = $sel[0]
}
elseif ($sessions.Count -eq 1) {
    $s = $sessions[0]
}
else {
    Write-Host 'several greenroom sessions are running -- name one:' -ForegroundColor Yellow
    $sessions | ForEach-Object { Write-Host "  $($_.Instance)  (pid $($_.Pid))" }
    exit 1
}

$th = Get-TerminalHost $s.Claude
if (-not $th) {
    Write-Host "session '$($s.Instance)' running (claude pid $($s.Pid)) but no WindowsTerminal host found in its ancestry." -ForegroundColor Yellow
    Write-Host "it may have launched under conhost; check ~/.claude/greenroom/$($s.Instance)/launch.log"
    exit 2
}

$hwnd = Resolve-SessionWindow -HostPid $th.ProcessId -Name $s.Instance
if (-not $hwnd -or $hwnd -eq [IntPtr]::Zero) {
    Write-Host "could not resolve a unique window for '$($s.Instance)' (WindowsTerminal pid $($th.ProcessId))." -ForegroundColor Yellow
    exit 3
}

$visible = [Greenroom.Win1]::IsWindowVisible($hwnd)

switch ($Action) {
    'attach' {
        [Greenroom.Win1]::ShowWindow($hwnd, $SW_RESTORE) | Out-Null
        [Greenroom.Win1]::SetForegroundWindow($hwnd) | Out-Null
        Write-Host "attached '$($s.Instance)' -- window shown (claude pid $($s.Pid))" -ForegroundColor Green
    }
    'detach' {
        [Greenroom.Win1]::ShowWindow($hwnd, $SW_HIDE) | Out-Null
        Write-Host "detached '$($s.Instance)' -- window hidden, session still running (claude pid $($s.Pid))" -ForegroundColor Green
    }
    'toggle' {
        if ($visible) {
            [Greenroom.Win1]::ShowWindow($hwnd, $SW_HIDE) | Out-Null
            Write-Host "detached '$($s.Instance)'" -ForegroundColor Green
        } else {
            [Greenroom.Win1]::ShowWindow($hwnd, $SW_RESTORE) | Out-Null
            [Greenroom.Win1]::SetForegroundWindow($hwnd) | Out-Null
            Write-Host "attached '$($s.Instance)'" -ForegroundColor Green
        }
    }
    'status' {
        [PSCustomObject]@{
            Instance     = $s.Instance
            ClaudePid    = $s.Pid
            TerminalPid  = $th.ProcessId
            WindowHandle = $hwnd
            Visible      = $visible
        } | Format-List
    }
}
