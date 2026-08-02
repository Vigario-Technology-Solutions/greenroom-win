# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Resolve and verify everything an instance needs before anything is registered.

  All of these fail SILENTLY inside a hidden window if they are wrong, which is why
  they are checked here rather than discovered later as "it just doesn't work".

  Returns the resolved paths; throws on anything fatal.
#>
function Resolve-GreenroomPrerequisite {
    [CmdletBinding()]
    param([string]$ClaudeExe)

    # Windows Terminal is a HARD requirement. conhost does no font fallback and no
    # console-registerable font carries the glyphs the TUI draws, so under conhost the
    # interface renders as boxes.
    $wt = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'),
        (Get-Command wt.exe -ErrorAction SilentlyContinue | ForEach-Object Source)
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $wt) { throw 'Windows Terminal (wt.exe) not found and is required. winget install Microsoft.WindowsTerminal' }

    # The shell that runs the watchdog and the session. pwsh 7 is PREFERRED -- WinGet's
    # version-independent alias first, then the real install path, then anything on PATH.
    # Windows PowerShell 5.1 ships in-box on every Windows host and is the last resort, so a
    # machine with no pwsh 7 still installs. greenroom's code runs on both editions, and this
    # is the same ladder the watchdog .vbs walks at logon.
    $shell = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'),
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Get-Command pwsh.exe -ErrorAction SilentlyContinue | ForEach-Object Source),
        (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $shell) { throw 'no PowerShell found: neither pwsh.exe nor Windows PowerShell 5.1 (powershell.exe).' }

    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    if (-not (Test-Path $wscript)) { throw "wscript.exe not found at $wscript" }

    # Candidate ORDER matters. WinGet's Links shim goes first because it is keyed on
    # PACKAGE ID rather than version, so the path survives upgrades and what lands in
    # config.json stays valid.
    $candidates = @()
    if ($ClaudeExe) { $candidates += $ClaudeExe }
    $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\claude.exe')
    $candidates += (Get-Command claude.exe -All -ErrorAction SilentlyContinue | ForEach-Object Source)
    $candidates += (Join-Path $env:USERPROFILE '.local\bin\claude.exe')

    # Claude DESKTOP ships its own claude.exe plus a private bundled CLI; neither is a
    # valid target, and its location depends on install method.
    $desktopPatterns = @(
        '*\Program Files\WindowsApps\*',
        '*\AnthropicClaude\*',
        '*\AppData\Roaming\Claude\claude-code\*'
    )

    $seen = @{}
    $claude = $candidates | Where-Object {
        if (-not $_) { return $false }
        if (-not (Test-Path $_)) { return $false }
        foreach ($pat in $desktopPatterns) { if ($_ -like $pat) { return $false } }
        $k = $_.ToLower()
        if ($seen.ContainsKey($k)) { return $false }
        $seen[$k] = $true
        return $true
    } | Select-Object -First 1

    if (-not $claude) { throw 'Claude Code CLI (claude.exe) not found. Pass -ClaudeExe, or install Claude Code first.' }

    # Deliberately NOT resolved through the symlink: the WinGet Links entry points at a
    # versioned target, and following it bakes a path that breaks on the next upgrade.
    $claude = [System.IO.Path]::GetFullPath($claude)

    $ver = (& $claude --version 2>&1 | Out-String).Trim()
    if ($ver -notmatch 'Claude Code') {
        throw "'$claude' does not look like the Claude Code CLI (--version said: $ver). Pass -ClaudeExe explicitly."
    }

    # THE WORST FAILURE GREENROOM HAS. Without --remote-control the session dies
    # instantly inside a hidden window, the watchdog restarts it, the crash-loop guard
    # trips, and nothing surfaces anywhere.
    #
    # The '[' anchor matters: older builds carry --remote-control-session-name-prefix
    # without the flag itself, and a bare substring match passes on those.
    $help = (& $claude --help 2>&1 | Out-String)
    if ($help -notmatch '--remote-control\s*\[') {
        throw ("'$claude' ($ver) does not support --remote-control. Verified absent in 2.1.92, present " +
               'from 2.1.218. Note --remote-control-session-name-prefix is a DIFFERENT flag that may be ' +
               'present without this one. Upgrade Claude Code, or pass -ClaudeExe at a build that has it.')
    }

    [PSCustomObject]@{
        WindowsTerminal = $wt
        Shell           = $shell
        WScript         = $wscript
        ClaudeExe       = $claude
        ClaudeVersion   = $ver
    }
}

<#
  Warn about host settings that break a supervised session invisibly.

  Advisory only -- none of these are fatal, and none are greenroom's to fix. They go to
  the Warning stream so a caller can suppress or capture them.
#>
function Test-GreenroomHostSetting {
    [CmdletBinding()]
    param()

    $settings = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (-not (Test-Path $settings)) { return }

    $s = $null
    try { $s = Get-Content $settings -Raw | ConvertFrom-Json }
    catch { Write-Warning "could not parse $settings"; return }

    # Git for Windows puts Git\cmd and Git\mingw64\bin on PATH but NOT Git\bin, which
    # is where bash.exe lives -- so a stock install satisfies `git` and fails `bash`,
    # and every Bash tool call then fails silently in a hidden window.
    if ($s.defaultShell -eq 'bash') {
        $inProc = Get-Command bash -ErrorAction SilentlyContinue

        # Build the PATH a NEW process would get, from the registry. This process may
        # hold a stale environment block, and that false negative is otherwise
        # indistinguishable from a real failure.
        $machine = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name Path).Path
        $user    = (Get-ItemProperty 'HKCU:\Environment' -Name Path -ErrorAction SilentlyContinue).Path
        $fresh   = [Environment]::ExpandEnvironmentVariables(($machine.TrimEnd(';') + ';' + $user))
        $freshHit = ($fresh -split ';') |
                    Where-Object { $_ -and (Test-Path (Join-Path $_ 'bash.exe')) } | Select-Object -First 1

        if ($inProc -and $freshHit) {
            Write-Verbose "shell: bash -> $($inProc.Source)"
        }
        elseif ($freshHit) {
            Write-Warning ("bash resolves in the registry PATH ($freshHit) but not in THIS process, which " +
                           'holds a stale environment block. A task-launched session will be fine.')
        }
        else {
            $msg = 'defaultShell is "bash" but bash.exe does not resolve on PATH. Every Bash tool call will fail silently in a hidden window.'
            $git = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
            if ($git) {
                $gitBin = Join-Path (Split-Path (Split-Path $git)) 'bin'
                if (Test-Path (Join-Path $gitBin 'bash.exe')) {
                    $msg += " Add '$gitBin' to your USER PATH. Do NOT add Git\usr\bin -- it also has bash but shadows Windows echo/find/sort/tee and breaks scripts."
                }
            }
            Write-Warning $msg
        }
    }

    # A marketplace whose source directory is missing throws a plugin load error at
    # every session start -- invisible, same as everything else here.
    if ($s.extraKnownMarketplaces) {
        foreach ($p in $s.extraKnownMarketplaces.PSObject.Properties) {
            $path = $p.Value.source.path
            if ($p.Value.source.source -eq 'directory' -and $path -and -not (Test-Path $path)) {
                $m = "marketplace '$($p.Name)' points at a path that does not exist: $path. Remove extraKnownMarketplaces.$($p.Name) from $settings"
                if ($s.enabledPlugins) {
                    $refs = @($s.enabledPlugins.PSObject.Properties.Name | Where-Object { $_ -like "*@$($p.Name)" })
                    if ($refs) { $m += ", plus enabledPlugins: $($refs -join ', ')" }
                }
                Write-Warning $m
            }
        }
    }

    # A host-wide grant defeats per-instance scoping. Filter falsy entries: @($null)
    # has Count 1, so an absent key would otherwise report a grant of nothing.
    $hostWide = @($s.permissions.additionalDirectories | Where-Object { $_ })
    if ($hostWide.Count -gt 0) {
        Write-Warning ("$settings grants these to EVERY instance on this host: $($hostWide -join ', '). " +
                       'Move them into a per-instance -AdditionalDirectories grant instead.')
    }
}
