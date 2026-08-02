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
    Log "FATAL: no config at $cfgPath -- run Install-GreenroomInstance -Name $Instance"
    Start-Sleep -Seconds 10
    exit 1
}
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json

# The working directory MUST NOT be the home directory. Per the Remote Control
# docs the startup trust dialog never persists trust for a home directory, so RC
# never connects and the trust prompt repeats forever. Claude Code also keys
# project state on the literal cwd string, which is why this is set explicitly
# rather than inherited from the task or the shell.
# Failing to reach it must be FATAL, not something to shrug off.
#
# $ErrorActionPreference is 'Continue' for this whole script, so before this both
# the New-Item and the Set-Location could fail, print to a stream nobody reads,
# and let execution carry on. claude then launched in whatever directory the
# process inherited -- which is the task's working directory, $env:USERPROFILE.
# The home directory. The one place Remote Control provably will not connect
# from, and the exact condition the comment above warns about.
#
# Reproduced with an unreachable path:
#     New-Item:     Cannot find drive. A drive with the name 'Z' does not exist.
#     Set-Location: Cannot find drive. A drive with the name 'Z' does not exist.
#     cwd after   : C:\Users\tyler
#
# That is reachable for real: a working directory on a network share is not
# guaranteed to be mapped when the logon task fires. The session would come up,
# look alive to the watchdog, and never connect -- silently, in a hidden window.
#
# Exiting non-zero instead means the watchdog logs that the session did not come
# up and eventually trips its crash-loop backoff. Noisy in the log beats wrong on
# disk.
$rcDir = $cfg.workingDirectory
if (-not (Test-Path -LiteralPath $rcDir)) {
    try {
        New-Item -ItemType Directory -Path $rcDir -Force -ErrorAction Stop | Out-Null
        Log "created working directory $rcDir"
    } catch {
        Log "FATAL: working directory '$rcDir' does not exist and cannot be created: $_"
        Log '       if it lives on a network share, the drive was probably not mapped yet.'
        exit 1
    }
}
try { Set-Location -LiteralPath $rcDir -ErrorAction Stop }
catch {
    Log "FATAL: cannot enter working directory '$rcDir': $_"
    exit 1
}

# Belt as well as braces: confirm we actually landed there rather than trusting
# that Set-Location reported success. Running in the wrong directory is the
# failure this whole block exists to prevent.
$landed = (Get-Location).Path
if ($landed.TrimEnd([char]92) -ne $rcDir.TrimEnd([char]92)) {
    Log "FATAL: expected cwd '$rcDir' but landed in '$landed'"
    exit 1
}
Log "cwd = $landed"

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

# --name sets the session's display name, and Claude Code renders the window title
# as "<glyph> <name>". That is what makes a window identifiable at all.
#
# Windows Terminal hosts several windows in ONE process, so greenroom.ps1 can only
# tell them apart by title. Without --name the title is Claude Code's own: it
# starts as "Claude Code" and becomes the CONVERSATION title once the conversation
# has one, changing as the conversation changes. Neither is tied to the instance,
# which is why matching on the working-directory leaf finds nothing against a live
# session.
#
# Measured on the reference host: --name drives the title, and it holds even when
# resuming a conversation that already carries its own auto-generated title.
$claudeArgs += @('--name', $Instance)

# ON THE LAUNCH LINE, and it has to be, because this instance resumes with -c below.
#
# A resumed session keeps the model it was saved with, deliberately, so that another
# session's choice cannot move it. That makes an always-on instance STICKY: whatever it
# was last running is what it keeps, across restarts and reboots, indefinitely -- and a
# settings-file default will not dislodge it. --model at launch does, and nothing else
# reachable from here does.
#
# It sets the model the session STARTS with, not a guarantee for its lifetime: a session
# can still be moved afterwards, and the CLI itself can fall back to a different model
# when it flags a message. greenroom cannot read the live model, so it does not claim to.
if ($cfg.model) {
    $claudeArgs += @('--model', $cfg.model)
    Log "model: $($cfg.model)"
}

# Directory grants are PER INSTANCE and default to none. An instance launches with
# access to its working directory and nothing else unless the install granted more.
if ($cfg.additionalDirectories -and @($cfg.additionalDirectories).Count -gt 0) {
    $claudeArgs += '--add-dir'
    $claudeArgs += @($cfg.additionalDirectories)
}

# Continue the previous conversation rather than minting a new session id on every
# restart. Without this, each watchdog restart begins a fresh conversation, and every
# one of them shows up as a separate entry in the Claude Desktop session list. On the
# reference host nine accumulated in a single day; eight were ~1 KB stubs holding
# nothing but a session header.
#
# GUARDED ON PURPOSE. Measured, all three on the same host and build (2.1.218):
#
#   --session-id <uuid>, pinned per instance
#       Create-only. The second launch exits 1 with "Session ID ... is already in
#       use". A pinned id would work exactly once and then fail on every restart
#       thereafter -- inside a hidden window, so the watchdog would crash-loop with
#       nothing on screen. Dead end, do not revisit.
#
#   -c with NO prior transcript
#       Exits 1 under --remote-control. This is the trap: `claude -p ... -c` in an
#       empty directory succeeds, so a headless test proves nothing about the path
#       this launcher actually takes. The interactive/RC path needs something to
#       continue and fails without it.
#
#   -c WITH a prior transcript
#       Session comes up, the existing transcript is appended to, no fork.
#
# So the flag is only safe when there is something to continue, hence the guard.
#
# The slug is derived from Get-Location AFTER Set-Location rather than from
# $cfg.workingDirectory: Claude Code keys the project store on the LITERAL cwd
# string, with every non-alphanumeric character replaced by a dash. Deriving it from
# the resolved location is what keeps the two in agreement.
$slug  = ((Get-Location).Path -replace '[^A-Za-z0-9]', '-')
$store = Join-Path $env:USERPROFILE ".claude\projects\$slug"
$prior = @(Get-ChildItem -LiteralPath $store -Filter *.jsonl -ErrorAction SilentlyContinue)
if ($prior.Count -gt 0) {
    $claudeArgs += '-c'
    Log "continuing previous conversation (-c); $($prior.Count) transcript(s) in $slug"
} else {
    Log "no prior transcript in $slug -- starting fresh (-c would exit 1 here)"
}

Log "exec: $($cfg.claudeExe) $($claudeArgs -join ' ')"
& $cfg.claudeExe @claudeArgs
Log "claude exited with $LASTEXITCODE"
