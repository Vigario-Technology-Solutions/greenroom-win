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
    [ValidateSet('attach', 'detach', 'status', 'toggle', 'list', 'restart')]
    [string]$Action = 'status',

    [Parameter(Position = 1)]
    [string]$Instance,

    # Do not auto-escalate when the target instance runs elevated. Without this,
    # attach/detach on an elevated instance re-launch this script through UAC so the
    # window actually moves. Scripted callers that must not block on a prompt pass
    # this and get a refusal (exit 4) instead.
    [switch]$NoElevate
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

function Get-InstanceConfig {
    param([string]$Name)
    $cfg = Join-Path $env:USERPROFILE ".claude\greenroom\$Name\config.json"
    if (-not (Test-Path $cfg)) { return $null }
    try { return Get-Content $cfg -Raw | ConvertFrom-Json } catch { return $null }
}

function Get-InstanceWorkingDirLeaf {
    param([string]$Name)
    $c = Get-InstanceConfig -Name $Name
    if (-not $c -or -not $c.workingDirectory) { return $null }
    try { return Split-Path $c.workingDirectory -Leaf } catch { return $null }
}

function Test-InstanceElevated {
    param([string]$Name)
    $c = Get-InstanceConfig -Name $Name
    # Absent key means an instance installed before -Elevated existed, which by
    # definition was not elevated.
    return [bool]($c -and $c.elevated)
}

function Test-SelfElevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-AnyInstanceElevated {
    $root = Join-Path $env:USERPROFILE '.claude\greenroom'
    if (-not (Test-Path $root)) { return $false }
    foreach ($d in (Get-ChildItem $root -Directory -ErrorAction SilentlyContinue)) {
        if (Test-InstanceElevated -Name $d.Name) { return $true }
    }
    return $false
}

# "Nothing found" and "running, but unreadable from this shell" are indistinguishable
# from an unelevated prompt, because CommandLine reads as NULL across integrity
# levels. Reporting the first when it is the second is the wrong-diagnosis trap, so
# when an elevated instance is installed and discovery came back empty, say which
# of the two this might be rather than asserting the session is down.
function Show-ElevatedVisibilityHint {
    if (Test-SelfElevated) { return }
    $root = Join-Path $env:USERPROFILE '.claude\greenroom'
    if (-not (Test-Path $root)) { return }
    $elev = @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
              Where-Object { Test-InstanceElevated -Name $_.Name })
    if ($elev.Count -eq 0) { return }
    Write-Host ''
    Write-Host "note: these instances are installed ELEVATED: $($elev.Name -join ', ')" -ForegroundColor DarkYellow
    Write-Host '  This shell is not elevated, and an elevated session is unreadable from here' -ForegroundColor DarkYellow
    Write-Host '  -- which looks identical to nothing running. Re-run elevated before' -ForegroundColor DarkYellow
    Write-Host '  concluding it is down, and before starting a second one on top of it.' -ForegroundColor DarkYellow
}

# An unelevated shell cannot show, hide or foreground a window owned by an elevated
# process. MEASURED on the reference host 2026-07-29 rather than taken from the
# documentation: ShowWindow(SW_HIDE) against an elevated window returned false with
# GetLastWin32Error 5 (ERROR_ACCESS_DENIED) and the window did not move. No
# exception, no prompt. Acting anyway would print "attached" and do nothing.
#
# Refusing would be safe but useless -- the operator still wants the window. So
# re-launch THIS script elevated and let the elevated copy do the work. A UAC
# prompt is entirely acceptable here, because this is an interactive command the
# user just typed. That is the opposite of the logon path, where a UAC dialog
# behind a hidden window would be an invisible hang -- which is why the session
# gets its token from the task trigger instead.
#
# -NoElevate opts out and restores the refusal, for scripted callers that must not
# block on a prompt.
function Invoke-ElevatedSelf {
    param([string]$Name)

    Write-Host "'$Name' runs elevated; this shell does not. Re-launching elevated..." -ForegroundColor Cyan
    $argList = @('-NoProfile', '-File', $PSCommandPath, $Action)
    if ($Name) { $argList += $Name }
    try {
        $p = Start-Process pwsh -Verb RunAs -ArgumentList $argList -PassThru -Wait -ErrorAction Stop
        exit $p.ExitCode
    } catch {
        # The usual cause is the UAC prompt being dismissed, which is a decision,
        # not a fault -- report it plainly rather than as a stack trace.
        Write-Host "elevation declined or failed -- '$Name' was not changed." -ForegroundColor Yellow
        Write-Host "  to do it by hand:  Start-Process pwsh -Verb RunAs -ArgumentList '-NoExit','-Command','greenroom $Action $Name'"
        exit 4
    }
}

function Assert-CanActOnInstance {
    param([string]$Name)
    if (-not (Test-InstanceElevated -Name $Name)) { return }
    if (Test-SelfElevated) { return }

    if ($NoElevate) {
        Write-Host "'$Name' runs ELEVATED, and this shell does not." -ForegroundColor Yellow
        Write-Host '  UIPI blocks ShowWindow/SetForegroundWindow from a lower integrity level, so' -ForegroundColor Yellow
        Write-Host '  attach and detach would report success and do nothing at all.' -ForegroundColor Yellow
        Write-Host '  -NoElevate was passed, so this is not being escalated automatically.' -ForegroundColor Yellow
        exit 4
    }
    Invoke-ElevatedSelf -Name $Name
}

function Get-AllSessions {
    # Anchor on claude.exe itself. Excluding the current process matters: a shell
    # running this script has "--remote-control" in its own command line.
    $all = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.ProcessId -ne $PID })

    foreach ($p in ($all | Where-Object { $_.CommandLine -match '--remote-control' })) {
        $name = '(unnamed)'
        if ($p.CommandLine -match '--remote-control\s+"?([^"\s-][^"\s]*)') { $name = $Matches[1] }
        [PSCustomObject]@{ Instance = $name; Claude = $p; Pid = $p.ProcessId; Opaque = $false }
    }

    # MEASURED on the reference host: Win32_Process.CommandLine comes back NULL for
    # any process this shell lacks query rights on -- confirmed against ctfmon.exe,
    # TabTip.exe and Bitwarden.exe, all of which enumerate but expose no command
    # line. A higher-integrity claude.exe falls in exactly that class, so an elevated
    # session is VISIBLE as a process but UNIDENTIFIABLE, and the filter above drops
    # it silently -- reporting "no session running" for one that is running.
    #
    # This is a property of WHERE THIS SCRIPT IS RUNNING, not of the session. From an
    # elevated shell nothing is opaque and every instance resolves by name as usual.
    #
    # Gated on an elevated instance actually being configured, because an unreadable
    # claude.exe is not evidence of greenroom by itself. A host with Claude Desktop
    # runs a dozen unrelated claude.exe (13 on the reference host), and claiming one
    # of those is "probably an elevated session" would be a confident wrong answer of
    # exactly the kind the opaque branch exists to avoid.
    if (Test-AnyInstanceElevated) {
        foreach ($p in ($all | Where-Object { -not $_.CommandLine })) {
            [PSCustomObject]@{ Instance = '(unreadable)'; Claude = $p; Pid = $p.ProcessId; Opaque = $true }
        }
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

    # PRIMARY. The handle the watchdog recorded when it created the window, which
    # is the only identification that does not depend on the hosted application.
    # Titles are owned and rewritten by Claude Code, and a session stopped at a
    # trust dialog or a login prompt never applies --name at all -- unresolvable
    # precisely when attaching matters most. See greenroom-watchdog.ps1.
    #
    # Validated, never trusted: handles are reused after a window closes, so a
    # stale record could name someone else's window. The recorded handle must
    # still be a live CASCADIA window under THIS host process, and the session it
    # was captured for must still be the running one. Any mismatch falls through
    # to the title paths rather than acting on a maybe.
    $sf = Join-Path $env:USERPROFILE ".claude\greenroom\$Name\session.json"
    if (Test-Path $sf) {
        try {
            $rec = Get-Content $sf -Raw | ConvertFrom-Json
            $match = @($wins | Where-Object { [int64]$_.Handle -eq [int64]$rec.handle })
            if ($match.Count -eq 1 -and [int]$rec.terminalPid -eq [int]$HostPid) {
                $live = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$rec.claudePid)" -ErrorAction SilentlyContinue
                if ($live -and $live.Name -eq 'claude.exe') { return $match[0].Handle }
            }
        } catch { }   # unreadable or malformed record is simply not usable
    }

    # SECONDARY. greenroom-launch.ps1 starts the session with `--name <instance>`,
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
    $byName = @($wins | Where-Object { $_.Title -match ([regex]::Escape($Name) + '$') })
    if ($byName.Count -eq 1) { return $byName[0].Handle }

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
        if ($byName.Count -eq 0) {
            Write-Host "  no window whose title ends with the session name '$Name'" -ForegroundColor Yellow
            Write-Host '  if this instance predates --name, restarting it will pick the title up.' -ForegroundColor Yellow
        } else {
            # More than one window bearing this instance's name means at least one is
            # a corpse: Windows Terminal keeps a window alive when the process hosting
            # its tab is killed rather than exiting, frozen at its last title. The
            # watchdog clears these before relaunching, so seeing them here means one
            # was created after the last relaunch.
            Write-Host "  $($byName.Count) windows end with the session name '$Name' -- at least one is stale." -ForegroundColor Yellow
            Write-Host '  Windows Terminal keeps a window alive when the process hosting its tab is' -ForegroundColor Yellow
            Write-Host '  killed instead of exiting. Restarting the instance clears them.' -ForegroundColor Yellow
        }
        Write-Host '  refusing to guess -- acting on the wrong window would hide or reveal the wrong session.' -ForegroundColor Yellow
        Write-Host "  to restart it and pick the title up:  greenroom restart $Name" -ForegroundColor Yellow
    }
    return $null
}

# Restart an instance's session.
#
# This exists because the procedure it replaces did not work. The advice was to
# stop the watchdog by process and then Start-ScheduledTask -- but stopping the
# watchdog leaves the session running, and the new watchdog then ADOPTS it. The
# result is the old session with a new supervisor, which is precisely not a
# restart. Measured on the reference host 2026-07-29: an instance reinstalled with
# -Elevated kept running at Medium integrity through exactly that sequence.
#
# Order matters. The watchdog goes first: kill the session first and the watchdog
# immediately restarts it, so the subsequent task start is a no-op against a
# session that never went away.
#
# Everything is driven from the instance NAME, the task and config.json -- never
# from session discovery. Discovery reads CommandLine, which is NULL across
# integrity levels, so a discovery-driven restart would be unusable from an
# unelevated shell against an elevated instance. Test-InstanceElevated reads
# config.json and works regardless.
function Restart-Instance {
    param([Parameter(Mandatory)][string]$Name)

    $task = "greenroom-$Name"
    if (-not (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue)) {
        Write-Host "no scheduled task '$task' -- is '$Name' installed?" -ForegroundColor Yellow
        exit 1
    }

    # Re-verify identity immediately before each kill. A pid recorded moments ago
    # can already belong to something else; on 2026-07-29 a launcher exited between
    # enumeration and termination and only this check prevented killing whatever
    # inherited its pid.
    function Stop-Verified {
        param([string]$ProcName, [string]$Pattern, [string]$Label)
        $n = 0
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='$ProcName'" -ErrorAction SilentlyContinue |
                         Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $Pattern })) {
            $live = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ProcessId)" -ErrorAction SilentlyContinue
            if (-not $live) { continue }
            if ($live.CommandLine -notmatch $Pattern) {
                Write-Host "  skipped pid $($p.ProcessId) -- no longer matches $Label" -ForegroundColor DarkYellow
                continue
            }
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host "  stopped $Label (pid $($p.ProcessId))"
            $n++
        }
        return $n
    }

    $esc = [regex]::Escape($Name)

    # Refuse to restart the instance this shell is running inside. Stopping the
    # session would kill an ancestor of this process, so the script dies partway
    # through and Start-ScheduledTask never runs -- leaving the instance DOWN. The
    # most natural way to invoke this is from inside the session, which is exactly
    # the case that would brick it.
    $ancestor = $PID
    for ($hop = 0; $hop -lt 8 -and $ancestor; $hop++) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ancestor" -ErrorAction SilentlyContinue
        if (-not $p) { break }
        if ($p.Name -eq 'claude.exe' -and $p.CommandLine -match "--remote-control\s+$esc\b") {
            Write-Host "'$Name' is the session this shell is running inside." -ForegroundColor Yellow
            Write-Host '  Restarting it from here would kill this process partway through, before the' -ForegroundColor Yellow
            Write-Host '  task is started again -- leaving the instance down rather than restarted.' -ForegroundColor Yellow
            Write-Host ''
            Write-Host '  Run it from a shell outside the session:' -ForegroundColor Yellow
            Write-Host "    greenroom restart $Name"
            exit 6
        }
        $ancestor = $p.ParentProcessId
    }

    Write-Host "restarting '$Name'..."

    # Watchdog first, or it resurrects the session before the task ever runs.
    $w = Stop-Verified -ProcName 'pwsh.exe'   -Pattern "greenroom-watchdog.*-Instance\s+`"?$esc\b" -Label 'watchdog'
    $c = Stop-Verified -ProcName 'claude.exe' -Pattern "--remote-control\s+$esc\b"                  -Label 'session'
    $l = Stop-Verified -ProcName 'pwsh.exe'   -Pattern "greenroom-launch.*-Instance\s+`"?$esc\b"    -Label 'launcher'
    if (($w + $c + $l) -eq 0) { Write-Host '  nothing was running' -ForegroundColor DarkGray }

    Start-Sleep -Seconds 2
    Start-ScheduledTask -TaskName $task

    # Confirm by observation. The task returning success only means the watchdog
    # was launched, not that a session came up behind it.
    $deadline = (Get-Date).AddSeconds(45)
    $found = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 750
        $found = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.CommandLine -match "--remote-control\s+$esc\b" } | Select-Object -First 1
        if ($found) { break }
    }

    if ($found) {
        Write-Host "  session up, claude pid $($found.ProcessId)" -ForegroundColor Green
        exit 0
    }

    # Unelevated against an elevated instance cannot read CommandLine, so absence
    # here is not evidence of failure -- say so rather than reporting a false one.
    if ((Test-InstanceElevated -Name $Name) -and -not (Test-SelfElevated)) {
        Write-Host '  cannot confirm from an unelevated shell: an elevated session is unreadable here.' -ForegroundColor Yellow
        Write-Host "  re-check with:  greenroom list   (elevated)" -ForegroundColor Yellow
        exit 0
    }
    Write-Host '  session did NOT come up within 45s.' -ForegroundColor Yellow
    Write-Host "  check: Get-Content `"$env:USERPROFILE\.claude\greenroom\$Name\watchdog.log`" -Tail 20"
    exit 1
}

if ($Action -eq 'restart') {
    if (-not $Instance) {
        $known = @(Get-ChildItem (Join-Path $env:USERPROFILE '.claude\greenroom') -Directory -ErrorAction SilentlyContinue)
        if ($known.Count -eq 1) { $Instance = $known[0].Name }
        else {
            Write-Host 'restart needs an instance name. Installed:' -ForegroundColor Yellow
            $known | ForEach-Object { Write-Host "  $($_.Name)" }
            exit 1
        }
    }
    Assert-CanActOnInstance -Name $Instance
    Restart-Instance -Name $Instance
}

$sessions = @(Get-AllSessions)

if ($Action -eq 'list') {
    if (-not $sessions) {
        Write-Host 'no greenroom sessions running.' -ForegroundColor Yellow
        Show-ElevatedVisibilityHint
        exit 1
    }
    $sessions | ForEach-Object {
        $th = if ($_.Opaque) { $null } else { Get-TerminalHost $_.Claude }
        $vis = $null; $hnd = $null
        if ($th) {
            $hnd = Resolve-SessionWindow -HostPid $th.ProcessId -Name $_.Instance -Quiet
            if ($hnd) { $vis = [Greenroom.Win1]::IsWindowVisible($hnd) }
        }
        [PSCustomObject]@{
            Instance    = $_.Instance
            ClaudePid   = $_.Pid
            TerminalPid = if ($th) { $th.ProcessId } else { $null }
            Window      = if ($hnd) { $hnd } elseif ($_.Opaque) { 'n/a' } else { 'unresolved' }
            Visible     = $vis
            Elevated    = if ($_.Opaque) { 'probably' } else { Test-InstanceElevated -Name $_.Instance }
        }
    } | Format-Table -AutoSize

    # Both notes below are about the SHELL, not the sessions. Run elevated and they
    # both go away -- every instance resolves by name and nothing reads as unknown.
    if (-not (Test-SelfElevated)) {
        $opaque = @($sessions | Where-Object Opaque)
        if ($opaque.Count -gt 0) {
            Write-Host "note: $($opaque.Count) claude.exe process(es) expose no command line to THIS shell," -ForegroundColor DarkYellow
            Write-Host '  which is how a higher-integrity process looks from an unelevated one. They' -ForegroundColor DarkYellow
            Write-Host '  cannot be named from here, and some may not be greenroom at all.' -ForegroundColor DarkYellow
        }
        $needElev = @($sessions | Where-Object { -not $_.Opaque -and (Test-InstanceElevated -Name $_.Instance) })
        if ($needElev.Count -gt 0) {
            Write-Host "note: $($needElev.Count) instance(s) above run elevated; attach/detach will prompt for UAC." -ForegroundColor DarkYellow
        }
        if ($opaque.Count -gt 0 -or $needElev.Count -gt 0) {
            Write-Host '  Re-run this from an elevated shell for a complete, named listing.' -ForegroundColor DarkYellow
        }
    }

    exit 0
}

if (-not $sessions) {
    Write-Host 'no greenroom session running.' -ForegroundColor Yellow
    Show-ElevatedVisibilityHint
    if ($Instance) { Write-Host "start it with:  Start-ScheduledTask -TaskName greenroom-$Instance" }
    else { Write-Host 'start one with: Start-ScheduledTask -TaskName greenroom-<instance>' }
    exit 1
}

if ($Instance) {
    $sel = @($sessions | Where-Object { $_.Instance -eq $Instance })
    if (-not $sel) {
        # An elevated session cannot be NAMED from an unelevated shell -- reading
        # its command line across the integrity boundary returns NULL -- so it
        # lands in $sessions as Opaque and never matches by name. Left alone, this
        # reports "no session named X" for an instance that is running perfectly
        # well, and the elevation handling below is unreachable for exactly the
        # instances that need it.
        #
        # config.json is readable at any integrity level, so the instance's
        # elevated flag is still trustworthy here. If it says elevated and there
        # is something opaque running, re-run elevated -- where the name resolves
        # normally and the session is found. Escalation exits; under -NoElevate it
        # explains instead.
        if (-not (Test-SelfElevated) -and
            @($sessions | Where-Object Opaque).Count -gt 0 -and
            (Test-InstanceElevated -Name $Instance)) {
            Assert-CanActOnInstance -Name $Instance
        }
        Write-Host "no greenroom session named '$Instance'. Running:" -ForegroundColor Yellow
        $sessions | ForEach-Object { Write-Host "  $($_.Instance)  (pid $($_.Pid))" }
        Show-ElevatedVisibilityHint
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

Assert-CanActOnInstance -Name $s.Instance

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

# Act, then CONFIRM by observation. ShowWindow's return value cannot be used for
# this, and neither can GetLastError -- measured on the reference host 2026-07-29,
# both directions returned false:
#
#   unelevated -> elevated window : returned false, error 5, window did NOT move
#   elevated   -> normal  window : returned false, error 1461, window DID move
#
# The return value is documented as the window's PREVIOUS visibility, not success,
# so it is false for any window that was hidden -- which is every attach. The only
# trustworthy signal is whether IsWindowVisible actually changed.
#
# Everything about a hidden session is invisible by construction, so reporting
# "attached" without checking is how a no-op gets mistaken for success.
function Set-WindowVisible {
    param([IntPtr]$Handle, [bool]$Show, [string]$Name, [int]$ClaudePid)

    $before = [Greenroom.Win1]::IsWindowVisible($Handle)
    [Greenroom.Win1]::ShowWindow($Handle, $(if ($Show) { $SW_RESTORE } else { $SW_HIDE })) | Out-Null
    if ($Show) { [Greenroom.Win1]::SetForegroundWindow($Handle) | Out-Null }
    Start-Sleep -Milliseconds 250
    $after = [Greenroom.Win1]::IsWindowVisible($Handle)

    if ($after -eq $Show) {
        if ($Show) { Write-Host "attached '$Name' -- window shown (claude pid $ClaudePid)" -ForegroundColor Green }
        else       { Write-Host "detached '$Name' -- window hidden, session still running (claude pid $ClaudePid)" -ForegroundColor Green }
        return $true
    }

    Write-Host "FAILED to $(if ($Show) {'show'} else {'hide'}) '$Name' -- the window did not change." -ForegroundColor Red
    Write-Host "  visible before=$before after=$after (wanted $Show)" -ForegroundColor Red
    Write-Host '  The session is unaffected; only the window operation failed.' -ForegroundColor Red
    if (-not (Test-SelfElevated)) {
        Write-Host '  Most likely cause: the window belongs to a higher-integrity process and' -ForegroundColor Red
        Write-Host '  UIPI refused the call. Re-run from an elevated shell.' -ForegroundColor Red
    }
    return $false
}

switch ($Action) {
    'attach' {
        if (-not (Set-WindowVisible -Handle $hwnd -Show $true -Name $s.Instance -ClaudePid $s.Pid)) { exit 5 }
    }
    'detach' {
        if (-not (Set-WindowVisible -Handle $hwnd -Show $false -Name $s.Instance -ClaudePid $s.Pid)) { exit 5 }
    }
    'toggle' {
        if (-not (Set-WindowVisible -Handle $hwnd -Show (-not $visible) -Name $s.Instance -ClaudePid $s.Pid)) { exit 5 }
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
