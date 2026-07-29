# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Install and register one always-on greenroom instance.

.DESCRIPTION
  Starts a supervised Claude Code Remote Control session at logon, hidden,
  attachable on demand.

  This is the whole procedure: it resolves the correct claude.exe, asserts the
  flag it depends on, checks the host settings that fail silently, seeds trust,
  scopes directory access, registers the task, starts the session, and verifies
  what it can observe. Nothing is left as a manual step that can be automated.

  Idempotent. Re-running for the same instance re-copies the scripts, rewrites
  the config, and re-registers the scheduled task. It does NOT kill a session
  that is already running -- the new config takes effect at the next restart.

.EXAMPLE
  .\install.ps1 -Instance desktop-admin
  .\install.ps1 -Instance render-admin -WorkingDirectory D:\render-admin -AdditionalDirectories D:\models
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Instance,
    [string]$WorkingDirectory,
    [string]$ClaudeExe,
    [string]$InstallDir = (Join-Path $env:USERPROFILE '.local\bin\greenroom'),
    [string]$TriggerDelay = 'PT1M',
    # Directory grants for THIS instance only, passed as --add-dir at launch.
    # Default is none, on purpose: an instance boots with access to its working
    # directory and nothing else unless you grant more here.
    [string[]]$AdditionalDirectories = @(),
    [switch]$NoTrustSeed,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

function Say($m)  { Write-Host $m }
function Ok($m)   { Write-Host "  OK    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  WARN  $m" -ForegroundColor Yellow }

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ required (running $($PSVersionTable.PSVersion)). Install with: winget install Microsoft.PowerShell"
}

# No spaces: the name goes on a command line and is matched back out of it, and
# it becomes part of a scheduled-task name.
if ($Instance -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$') {
    throw "invalid instance name '$Instance'. Use 1-32 chars: letters, digits, dot, dash, underscore; must start alphanumeric."
}

$TaskName = "greenroom-$Instance"
$stateDir = Join-Path $env:USERPROFILE ".claude\greenroom\$Instance"

# Same trap as -AdditionalDirectories, and worse in consequence. A bare re-run of
# an already-installed instance used to fall back to ~/<instance>, silently
# RELOCATING it: a new working directory was created, trust was seeded for it, and
# the session restarted there -- abandoning the real working directory along with
# its project store, its memory and its transcripts. The only hint was an
# "OK working dir" line reporting a path nobody asked for. The docs call this
# installer idempotent and invite re-running it.
#
# Reproduced on the reference host: two instances configured at ~/src/desktop-admin
# and ~/src/anikenrobinson both jumped to ~/desktop-admin and ~/ar-video-prod on a
# bare re-run, each landing in a fresh, empty project store.
#
# So an omitted -WorkingDirectory now inherits the previous install's. Passing it
# stays authoritative, which is how an instance is deliberately relocated.
# -TriggerDelay gets the same treatment for the same reason: a bare re-run had
# been resetting a deliberately staggered PT3M back to the PT1M default, which
# quietly un-staggers a multi-instance host.
$prevCfg = $null
$prevCfgPath = Join-Path $stateDir 'config.json'
$prevCfgUnreadable = $false
if (Test-Path $prevCfgPath) {
    try { $prevCfg = Get-Content $prevCfgPath -Raw | ConvertFrom-Json }
    catch { $prevCfgUnreadable = $true }
}

# A config that EXISTS but cannot be parsed is not the same as no config at all,
# and swallowing the difference reopens this very bug through another door: with
# nothing to inherit, every omitted parameter falls back to its default and the
# instance silently relocates to ~/<instance>, abandoning its project store.
# Confirmed by corrupting a config and re-running: the working directory moved and
# the only output was a warning about grants.
#
# ClaudeExe is deliberately not in this list. Omitting it falls back to
# auto-detection, which is both safe and the normal case.
if ($prevCfgUnreadable) {
    $omitted = @('WorkingDirectory', 'TriggerDelay', 'AdditionalDirectories') |
               Where-Object { -not $PSBoundParameters.ContainsKey($_) } |
               ForEach-Object { "-$_" }
    if ($omitted.Count -gt 0) {
        throw @"
'$prevCfgPath' exists but cannot be parsed, so this instance's remembered settings are unreadable.

Refusing to continue. $($omitted -join ', ') were omitted, and with nothing to inherit they
would fall back to defaults -- relocating the instance to '$(Join-Path $env:USERPROFILE $Instance)'
and abandoning its project store, memory and transcripts.

Either repair or delete that file, or pass every value explicitly on this run.
"@
    }
}
if (-not $PSBoundParameters.ContainsKey('WorkingDirectory') -and $prevCfg -and $prevCfg.workingDirectory) {
    $WorkingDirectory = $prevCfg.workingDirectory
    Say "  ..    keeping working directory from the previous install"
    Say "        $WorkingDirectory"
}
if (-not $PSBoundParameters.ContainsKey('TriggerDelay')) {
    if ($prevCfg -and $prevCfg.triggerDelay) {
        $TriggerDelay = $prevCfg.triggerDelay
        Say "  ..    keeping trigger delay from the previous install ($TriggerDelay)"
    } else {
        # config.json only started recording triggerDelay in this change, so an
        # instance installed before it has nothing to inherit and would reset to
        # the default on its first bare re-run -- silently un-staggering a
        # multi-instance host. The registered task is the authoritative record of
        # the delay actually in force, so read it back from there instead.
        $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $taskDelay = if ($existingTask -and $existingTask.Triggers) { $existingTask.Triggers[0].Delay } else { $null }
        if ($taskDelay) {
            $TriggerDelay = $taskDelay
            Say "  ..    keeping trigger delay from the registered task ($TriggerDelay)"
        }
    }
}
# -ClaudeExe is the same class, but only when it was CHOSEN. config.json records
# the RESOLVED path, so inheriting it unconditionally would pin whatever
# auto-detection happened to pick and defeat the whole reason the WinGet Links
# shim is preferred -- that path is package-ID-keyed and survives upgrades, and
# freezing a resolved copy of it buys nothing while risking a stale pin if the CLI
# is ever installed elsewhere.
#
# So the explicit choice is what gets remembered, not the result. Someone who
# passed -ClaudeExe did so because auto-detection picks wrong on their host, which
# is exactly the case where silently reverting to it on a bare re-run does damage.
if (-not $PSBoundParameters.ContainsKey('ClaudeExe') -and $prevCfg -and $prevCfg.claudeExeExplicit -and $prevCfg.claudeExe) {
    $ClaudeExe = $prevCfg.claudeExe
    Say "  ..    keeping explicitly chosen claude.exe from the previous install"
    Say "        $ClaudeExe"
}

if (-not $WorkingDirectory) { $WorkingDirectory = Join-Path $env:USERPROFILE $Instance }

Say ''
Say "=== installing greenroom instance '$Instance' ==="

# ---------------------------------------------------------------- prerequisites

# Windows Terminal is a HARD requirement. conhost does no font fallback and no
# console-registerable font carries the glyphs the TUI draws, so under conhost
# the interface renders as boxes.
$wt = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'),
    (Get-Command wt.exe -ErrorAction SilentlyContinue | ForEach-Object Source)
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $wt) {
    throw "Windows Terminal (wt.exe) not found and is required. Install with: winget install Microsoft.WindowsTerminal"
}
Ok "windows terminal : $wt"

$pwsh = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'),
    (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
    (Get-Command pwsh.exe -ErrorAction SilentlyContinue | ForEach-Object Source)
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $pwsh) { throw "pwsh.exe not found. Install with: winget install Microsoft.PowerShell" }
Ok "pwsh             : $pwsh"

# Resolve the Claude Code CLI, NOT Claude Desktop.
#
# Candidate ORDER matters. WinGet's Links shim goes first because it is keyed on
# PACKAGE ID rather than version, so the path survives upgrades and what lands in
# config.json stays valid. Hardcoding ~\.local\bin ahead of PATH selects whatever
# standalone install happens to be there, however old.
$claudeCandidates = @()
if ($ClaudeExe) { $claudeCandidates += $ClaudeExe }
$claudeCandidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\claude.exe')
$claudeCandidates += (Get-Command claude.exe -All -ErrorAction SilentlyContinue | ForEach-Object Source)
$claudeCandidates += (Join-Path $env:USERPROFILE '.local\bin\claude.exe')

# Claude DESKTOP ships its own claude.exe plus a private bundled CLI; neither is a
# valid target. Desktop's location depends on install method -- Store puts it under
# Program Files\WindowsApps, the standalone installer under LOCALAPPDATA -- so
# exclude every known layout rather than assuming one.
$desktopPatterns = @(
    '*\Program Files\WindowsApps\*',            # Store install
    '*\AnthropicClaude\*',                      # standalone installer
    '*\AppData\Roaming\Claude\claude-code\*'    # Desktop's private bundled CLI
)

$seenPaths = @{}
$claude = $claudeCandidates | Where-Object {
    if (-not $_) { return $false }
    if (-not (Test-Path $_)) { return $false }
    foreach ($pat in $desktopPatterns) { if ($_ -like $pat) { return $false } }
    $k = $_.ToLower()
    if ($seenPaths.ContainsKey($k)) { return $false }
    $seenPaths[$k] = $true
    return $true
} | Select-Object -First 1

if (-not $claude) {
    throw "Claude Code CLI (claude.exe) not found. Pass -ClaudeExe <path>, or install Claude Code first."
}
# Deliberately NOT Resolve-Path'd into its target: the WinGet Links entry is a
# symlink whose target carries a version, and following it would bake a path that
# breaks on the next upgrade.
$claude = [System.IO.Path]::GetFullPath($claude)

$ver = (& $claude --version 2>&1 | Out-String).Trim()
if ($ver -notmatch 'Claude Code') {
    throw "'$claude' does not look like the Claude Code CLI (--version said: $ver). Pass -ClaudeExe explicitly."
}

# HARD PREREQUISITE. If --remote-control is missing, the session dies instantly
# inside a hidden window, the watchdog restarts it, the crash-loop guard trips,
# and nothing whatsoever surfaces. This is the worst failure mode greenroom has, so
# it is checked before a scheduled task is ever registered.
# Note the '[' anchor: older builds carry --remote-control-session-name-prefix
# without the flag itself, and a bare substring match would pass on those.
$help = (& $claude --help 2>&1 | Out-String)
if ($help -notmatch '--remote-control\s*\[') {
    throw @"
'$claude' ($ver) does not support --remote-control.
Verified absent in 2.1.92; present from 2.1.218 onward.
Note: --remote-control-session-name-prefix is a DIFFERENT flag and may be present
without the one greenroom needs.
Upgrade Claude Code, or pass -ClaudeExe pointing at a build that has it.
"@
}
Ok "claude code      : $claude  [$ver, --remote-control OK]"

$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
if (-not (Test-Path $wscript)) { throw "wscript.exe not found at $wscript" }

# The one host setting greenroom inspects, and only because getting it wrong breaks
# the supervised session invisibly. Git for Windows puts Git\cmd and
# Git\mingw64\bin on PATH but NOT Git\bin, and Git\bin is where bash.exe lives, so
# a stock Git install satisfies `git` and fails `bash`.
function Test-ShellResolution {
    $settings = Join-Path $env:USERPROFILE '.claude\settings.json'
    $shell = $null
    if (Test-Path $settings) {
        try { $shell = (Get-Content $settings -Raw | ConvertFrom-Json).defaultShell } catch { }
    }
    if ($shell -ne 'bash') {
        Ok "shell            : defaultShell=$(if ($shell) { $shell } else { '(unset)' }) -- no bash requirement"
        return
    }

    $inProc = Get-Command bash -ErrorAction SilentlyContinue

    # Build the PATH a NEW process would get, straight from the registry. This
    # process may hold a stale environment block, and that false negative is
    # otherwise indistinguishable from a real failure.
    $m = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name Path).Path
    $u = (Get-ItemProperty 'HKCU:\Environment' -Name Path -ErrorAction SilentlyContinue).Path
    $fresh = [Environment]::ExpandEnvironmentVariables(($m.TrimEnd(';') + ';' + $u))
    $freshHit = ($fresh -split ';') |
                Where-Object { $_ -and (Test-Path (Join-Path $_ 'bash.exe')) } |
                Select-Object -First 1

    if ($inProc -and $freshHit) { Ok "shell            : bash -> $($inProc.Source)"; return }

    if ($freshHit) {
        Warn "bash resolves in the registry PATH ($freshHit) but not in THIS process."
        Warn 'this shell holds a stale environment block. The task-launched session will be fine;'
        Warn 'restart the task of any session already running that cannot find bash.'
        return
    }

    Warn 'defaultShell is "bash" but bash.exe does not resolve on PATH.'
    Warn 'every Bash tool call will fail, silently, in a hidden window.'
    $gitCmd = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
    if ($gitCmd) {
        $gitBin = Join-Path (Split-Path (Split-Path $gitCmd)) 'bin'
        if (Test-Path (Join-Path $gitBin 'bash.exe')) {
            Warn 'fix: add this to your USER PATH, then open a NEW terminal to verify:'
            Write-Host "          $gitBin" -ForegroundColor Yellow
            Warn 'do NOT add Git\usr\bin -- it also has bash, but it shadows Windows'
            Warn 'echo / expand / find / link / sort / tee / timeout and breaks scripts.'
        } else {
            Warn "git found at $gitCmd but no bash.exe under $gitBin -- non-standard install."
        }
    } else {
        Warn 'git.exe not found either. Install Git for Windows, or remove defaultShell.'
    }
}
Test-ShellResolution

# A marketplace whose source directory is missing throws a plugin load error at
# every session start -- invisible in a hidden window, same as every other failure
# here. Checked rather than left as a manual step.
function Test-PluginMarketplaces {
    $settings = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (-not (Test-Path $settings)) { return }
    try { $s = Get-Content $settings -Raw | ConvertFrom-Json } catch { Warn 'could not parse ~/.claude/settings.json'; return }
    if (-not $s.extraKnownMarketplaces) { Ok 'marketplaces     : none declared'; return }

    $bad = @()
    foreach ($p in $s.extraKnownMarketplaces.PSObject.Properties) {
        $path = $p.Value.source.path
        if ($p.Value.source.source -eq 'directory' -and $path -and -not (Test-Path $path)) {
            $bad += [PSCustomObject]@{ Name = $p.Name; Path = $path }
        }
    }
    if (-not $bad) { Ok 'marketplaces     : all directory sources present'; return }

    foreach ($b in $bad) {
        Warn "marketplace '$($b.Name)' points at a path that does not exist:"
        Write-Host "          $($b.Path)" -ForegroundColor Yellow
        Warn "remove extraKnownMarketplaces.$($b.Name) from ~/.claude/settings.json,"
        Warn 'plus any enabledPlugins entry that references it:'
        if ($s.enabledPlugins) {
            @($s.enabledPlugins.PSObject.Properties.Name | Where-Object { $_ -like "*@$($b.Name)" }) |
                ForEach-Object { Write-Host "          enabledPlugins: $_" -ForegroundColor Yellow }
        }
    }
}
Test-PluginMarketplaces

# ---------------------------------------------------------------------- layout

foreach ($d in $InstallDir, $stateDir, $WorkingDirectory) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
Ok "working dir      : $WorkingDirectory"
Ok "state dir        : $stateDir"

$src = Join-Path $PSScriptRoot 'bin'
if (-not (Test-Path $src)) { throw "repository incomplete: no bin\ directory next to install.ps1" }

# The watchdog, its launcher and the vbs entry point are invoked by the scheduled
# task and by each other, never by you, so they live in the install directory.
Copy-Item (Join-Path $src 'greenroom-watchdog.vbs') -Destination $InstallDir -Force
Copy-Item (Join-Path $src 'greenroom-watchdog.ps1') -Destination $InstallDir -Force
Copy-Item (Join-Path $src 'greenroom-launch.ps1')   -Destination $InstallDir -Force
Ok "internals        : $InstallDir"

# The operator command goes one level UP, into the directory that is on PATH.
#
# One command, one shim per shell -- the shape npm's cmd-shim and Scoop both use.
# PowerShell resolves a bare .ps1 from PATH natively as an ExternalScript, with
# full parameter and ValidateSet completion, and prefers it over a same-named .cmd.
# .PS1 is not in PATHEXT, so cmd.exe and the Run box cannot run it and need the
# .cmd, which is a four-line forwarder carrying no logic. The result is that the
# extra shell hop is paid only where it is unavoidable.
$shimDir     = Split-Path $InstallDir -Parent
$commandPath = Join-Path $shimDir 'greenroom.ps1'
$shimPath    = Join-Path $shimDir 'greenroom.cmd'

Copy-Item (Join-Path $src 'greenroom.ps1') -Destination $commandPath -Force
Ok "command          : $commandPath"

@"
@echo off
REM Generated by greenroom install.ps1 -- edits will be overwritten.
REM cmd.exe and the Run box cannot execute a .ps1 (.PS1 is not in PATHEXT).
REM PowerShell never reaches this file: it prefers the .ps1 beside it.
setlocal
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$commandPath" %*
exit /b %ERRORLEVEL%
"@ | Set-Content -Path $shimPath -Encoding ASCII
Ok "cmd shim         : $shimPath"

$onPath = ($env:PATH -split ';' | ForEach-Object { $_.TrimEnd('\').ToLower() }) -contains $shimDir.TrimEnd('\').ToLower()
if ($onPath) {
    Ok "                   'greenroom' resolves natively in pwsh, via the shim in cmd"
} else {
    Warn "$shimDir is not on PATH -- 'greenroom' will not resolve as a bare command."
    Warn 'add it to your user PATH, or invoke by full path.'
}

# NOT PASSING -AdditionalDirectories is different from passing it empty.
#
# This installer is documented as idempotent and safe to re-run at any time, so
# following that advice must not destroy configuration. It did: a bare re-run
# rebuilt $grants as empty and wrote that through to config.json, to the project
# settings file, AND to the launch line, silently revoking access the instance had
# been granted. Reproduced on the reference host -- one bare re-run took
# 'C:\Users\tyler' out of all three places and the running session lost home
# access with nothing but "grants : none" in the output to say so.
#
# Omitting the parameter therefore inherits whatever the previous install
# recorded. Passing it explicitly stays authoritative, so -AdditionalDirectories @()
# remains the way to actually clear grants.
if (-not $PSBoundParameters.ContainsKey('AdditionalDirectories') -and $prevCfg) {
    try {
        $prevGrants = @($prevCfg.additionalDirectories) |
                      Where-Object { $_ }
        if ($prevGrants.Count -gt 0) {
            $AdditionalDirectories = $prevGrants
            Say "  ..    inheriting $($prevGrants.Count) grant(s) from the previous install"
            Say "        pass -AdditionalDirectories @() to clear them instead"
        }
    } catch { Warn "could not read previous grants from $prevCfgPath -- continuing with none" }
}

$grants = @()
foreach ($d in $AdditionalDirectories) {
    if (-not (Test-Path $d)) { throw "-AdditionalDirectories: '$d' does not exist. Refusing to grant a path that isn't there." }
    $grants += (Resolve-Path $d).Path
}

[PSCustomObject]@{
    instance              = $Instance
    claudeExe             = $claude
    # Passing -ClaudeExe '' is how an explicit choice is revoked, mirroring
    # -AdditionalDirectories @() for grants: the parameter was supplied, but it
    # names nothing, so auto-detection resumes and nothing gets pinned.
    claudeExeExplicit     = ($PSBoundParameters.ContainsKey('ClaudeExe') -and [bool]$ClaudeExe)
    workingDirectory      = $WorkingDirectory
    triggerDelay          = $TriggerDelay
    additionalDirectories = $grants
    wt                    = $wt
    pwsh                  = $pwsh
    installedUtc          = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json | Set-Content -Path (Join-Path $stateDir 'config.json') -Encoding UTF8
Ok "config           : $(Join-Path $stateDir 'config.json')"

if ($grants.Count -eq 0) {
    Ok "grants           : none -- working directory only"
} else {
    Ok "grants           : $($grants.Count) extra director$(if ($grants.Count -eq 1) { 'y' } else { 'ies' }) (--add-dir)"
    $grants | ForEach-Object { Write-Host "                     $_" }
}

# A host-wide grant defeats per-instance scoping, so say so rather than let it
# silently widen every instance on the machine.
$userSettings = Join-Path $env:USERPROFILE '.claude\settings.json'
if (Test-Path $userSettings) {
    try {
        $us = Get-Content $userSettings -Raw | ConvertFrom-Json
        # Filter falsy entries: @($null).Count is 1 in PowerShell, so an absent key
        # would otherwise report a host-wide grant of nothing.
        $hostWide = @($us.permissions.additionalDirectories | Where-Object { $_ })
        if ($hostWide.Count -gt 0) {
            Warn '~/.claude/settings.json grants these to EVERY instance on this host:'
            $hostWide | ForEach-Object { Write-Host "          $_" -ForegroundColor Yellow }
            Warn 'move them into a per-instance -AdditionalDirectories grant instead.'
        }
    } catch { Warn "could not parse $userSettings to check for host-wide grants" }
}

# Mirror the grant into the instance's PROJECT settings so a session you start by
# hand in that directory gets the same scope as the supervised one, and the scope
# is self-documenting rather than something to remember. Merged, never clobbered.
function Set-ProjectGrants {
    param([string]$Dir, [string[]]$Grants)

    $pd = Join-Path $Dir '.claude'
    $pf = Join-Path $pd 'settings.json'
    if (-not (Test-Path $pd)) { New-Item -ItemType Directory -Path $pd -Force | Out-Null }

    $obj = $null
    if (Test-Path $pf) {
        try { $obj = Get-Content $pf -Raw | ConvertFrom-Json }
        catch { Warn "$pf exists but is not valid JSON -- leaving it untouched"; return }
    }
    if (-not $obj) { $obj = [PSCustomObject]@{} }

    if (-not $obj.PSObject.Properties['permissions']) {
        $obj | Add-Member -NotePropertyName permissions -NotePropertyValue ([PSCustomObject]@{})
    }
    if ($obj.permissions.PSObject.Properties['additionalDirectories']) {
        $obj.permissions.additionalDirectories = @($Grants)
    } else {
        $obj.permissions | Add-Member -NotePropertyName additionalDirectories -NotePropertyValue @($Grants)
    }

    $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $pf -Encoding UTF8
    Ok "project settings : $pf"
}
Set-ProjectGrants -Dir $WorkingDirectory -Grants $grants

# ------------------------------------------------------------------ trust seed

# Remote Control will not connect from an untrusted directory, and the startup
# trust dialog is modal -- in a hidden window that means the session hangs
# forever with no way to see why. Seeding trust before first launch avoids it.
#
# Claude Code keys project state on the LITERAL cwd string, so 'C:\x' and 'C:/x'
# are separate entries with independent trust. Both forms are seeded; that
# mismatch is what made an earlier setup re-prompt on every start.
#
# This is the only file outside greenroom's own directories that install.ps1 writes.
function Set-ProjectTrust {
    param([string]$Dir)

    $file = Join-Path $env:USERPROFILE '.claude.json'
    if (-not (Test-Path $file)) {
        Warn 'no ~/.claude.json yet -- run `claude` once, then re-run this installer'
        return
    }

    $backup = Join-Path $stateDir ('claude.json.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item $file $backup -Force

    $raw = Get-Content $file -Raw
    $m = [regex]::Match($raw, '"projects"\s*:\s*\{')
    if (-not $m.Success) { Warn 'no "projects" block in ~/.claude.json -- skipping trust seed'; return }
    $insertAt = $m.Index + $m.Length

    $targets = @($Dir.Replace('/', '\'), $Dir.Replace('\', '/'))
    $seeded = $false
    foreach ($t in ($targets | Select-Object -Unique)) {
        $jsonKey = $t.Replace('\', '\\')
        if ($raw -match [regex]::Escape('"' + $jsonKey + '"')) { continue }
        $entry = @"

    "$jsonKey": {
      "allowedTools": [],
      "mcpContextUris": [],
      "mcpServers": {},
      "enabledMcpjsonServers": [],
      "disabledMcpjsonServers": [],
      "hasTrustDialogAccepted": true,
      "projectOnboardingSeenCount": 0,
      "hasClaudeMdExternalIncludesApproved": false,
      "hasClaudeMdExternalIncludesWarningShown": false,
      "exampleFiles": []
    },
"@
        $raw = $raw.Substring(0, $insertAt) + $entry + $raw.Substring($insertAt)
        $seeded = $true
    }

    if (-not $seeded) { Ok 'trust            : already present for both path forms'; return }

    try { $null = $raw | ConvertFrom-Json -AsHashtable }
    catch { Warn "refusing to write ~/.claude.json, result was invalid JSON: $_"; return }

    Set-Content -Path $file -Value $raw -Encoding UTF8 -NoNewline
    Ok "trust            : seeded (backup at $backup)"
}

function Test-TrustSurvived {
    param([string]$Dir)
    $file = Join-Path $env:USERPROFILE '.claude.json'
    if (-not (Test-Path $file)) { return $false }
    try { $j = Get-Content $file -Raw | ConvertFrom-Json -AsHashtable } catch { return $false }
    if (-not $j.projects) { return $false }
    foreach ($f in (@($Dir.Replace('/', '\'), $Dir.Replace('\', '/')) | Select-Object -Unique)) {
        if (-not $j.projects.ContainsKey($f)) { return $false }
        if (-not $j.projects[$f]['hasTrustDialogAccepted']) { return $false }
    }
    return $true
}

if ($NoTrustSeed) { Warn 'trust seed skipped (-NoTrustSeed)' }
else { Set-ProjectTrust -Dir $WorkingDirectory }

# ------------------------------------------------------------------------ task

$vbs    = Join-Path $InstallDir 'greenroom-watchdog.vbs'
$argStr = '"{0}" "{1}"' -f $vbs, $Instance

$action = New-ScheduledTaskAction -Execute $wscript -Argument $argStr -WorkingDirectory $env:USERPROFILE

$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
# Delay lets credential managers / VPN / sync clients come up first; the session
# needs network and, if you use an SSH agent, an unlocked vault.
$trigger.Delay = $TriggerDelay

# Interactive = runs in the logged-on desktop session, which is required: the
# session hosts a real Windows Terminal window that you attach to on demand.
# Limited = no elevation.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -DontStopOnIdleEnd `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero)   # 0 = no limit; the default kills it after 3 days
$settings.Hidden = $false

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Say "  ..    removed pre-existing task '$TaskName'"
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description "Always-on greenroom session '$Instance' in $WorkingDirectory. Started hidden at logon; attach with greenroom.ps1." | Out-Null
Ok "task             : $TaskName (delay $TriggerDelay)"

# ----------------------------------------------------------------- start/verify

if ($NoStart) {
    Say ''
    Say "installed. start it with:  Start-ScheduledTask -TaskName $TaskName"
    return
}

Say ''
Say 'starting and waiting up to 60s for the session to come up...'
Start-ScheduledTask -TaskName $TaskName

$pattern  = '--remote-control\s+"?' + [regex]::Escape($Instance) + '("|\s|$)'
$deadline = (Get-Date).AddSeconds(60)
$found    = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 750
    $found = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -match $pattern } | Select-Object -First 1
    if ($found) { break }
}

# Verify the trust seed SURVIVED rather than assuming it did. On any host with
# Claude Desktop there are always other claude.exe processes, and any of them can
# rewrite ~/.claude.json between install and launch. The consequence is a modal
# trust dialog in a window nobody can see, which reads as "it hangs for no reason".
if (-not $NoTrustSeed) {
    if (Test-TrustSurvived -Dir $WorkingDirectory) {
        Ok 'trust            : verified present after launch (both path forms)'
    } else {
        Warn 'trust seed did NOT survive -- something rewrote ~/.claude.json. Re-seeding.'
        Set-ProjectTrust -Dir $WorkingDirectory
        if (Test-TrustSurvived -Dir $WorkingDirectory) {
            Warn 'trust re-seeded. Restarting the session so it picks the seed up.'

            # Stop-ScheduledTask is a NO-OP against this architecture. The task
            # runs wscript.exe, which spawns the watchdog detached and returns, so
            # the task reaches Ready almost immediately and there is nothing left
            # for Stop to stop. Start-ScheduledTask on its own therefore ADDS a
            # second watchdog rather than replacing one -- and two watchdogs see
            # the same session die on the same 1s poll and both relaunch it,
            # producing two Windows Terminal windows for one instance. That is the
            # ambiguity greenroom.ps1 refuses to guess at, so attach breaks
            # permanently. The supervisor has to be stopped by process.
            #
            # The $_.ProcessId -ne $PID clause is load-bearing: this shell's own
            # command line contains the search string and will match itself.
            Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.ProcessId -ne $PID -and
                    $_.CommandLine -match 'greenroom-watchdog\.ps1' -and
                    $_.CommandLine -match ('-Instance\s+"?' + [regex]::Escape($Instance) + '("|\s|$)')
                } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 2

            # The session itself must go too: trust is read at startup, so a
            # session already sitting on the dialog will not pick up the reseed.
            Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match $pattern } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 3

            Start-ScheduledTask -TaskName $TaskName

            # Re-resolve the PID. The one captured before the restart is dead, and
            # reporting it as "session up" would be a claim this script has not
            # checked -- the exact failure the rest of this file exists to avoid.
            $rsDeadline = (Get-Date).AddSeconds(45)
            $found = $null
            while ((Get-Date) -lt $rsDeadline) {
                Start-Sleep -Milliseconds 750
                $found = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
                         Where-Object { $_.CommandLine -match $pattern } | Select-Object -First 1
                if ($found) { break }
            }
            if (-not $found) { Warn 'session did not come back within 45s after the re-seed restart.' }
        } else {
            Warn 'RE-SEED FAILED. Expect a modal trust dialog inside the hidden window.'
            Warn 'attach and accept it manually, or close other claude.exe processes and re-run.'
        }
    }
}

Say ''
if ($found) {
    Ok "session up, claude pid $($found.ProcessId)"
    Say ''
    Say 'VERIFY THE PART I CANNOT SEE:'
    Say '  1. No terminal window should have appeared. If one did, say so -- do not assume it is fine.'
    Say "  2. greenroom attach $Instance"
    Say "     -> the session appears. Confirm '/rc active' is in the footer."
    Say "  3. greenroom detach $Instance"
    Say ''
    Say "If the footer does NOT say '/rc active', run /login inside the session."
    Say 'Remote Control needs a full claude.ai login; setup-token credentials are rejected.'
} else {
    Warn 'session did NOT come up within 60s.'
    Say  "  check: Get-Content `"$stateDir\watchdog.log`" -Tail 20"
    Say  "         Get-Content `"$stateDir\launch.log`"   -Tail 20"
}

Say ''
Say 'logs:'
Say "  $stateDir\watchdog.log"
Say "  $stateDir\launch.log"
