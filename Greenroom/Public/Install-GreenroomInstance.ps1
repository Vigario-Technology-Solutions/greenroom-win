# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Provision a greenroom instance: config, trust, scheduled task, and start it.

.DESCRIPTION
  Replaces install.ps1.

  It provisions an INSTANCE. It does not install the software -- that already happened,
  or you could not be calling this. The script it replaces did both: it copied its own
  scripts into a bin directory and generated a cmd shim, which is what a package
  manager is for. That is roughly 130 lines that no longer exist, along with
  -InstallDir and the PATH warning that went with them.

  Idempotent, and that is load-bearing rather than a nicety: omitting a parameter
  INHERITS what the previous install recorded rather than falling back to a default.
  Every one of those rules is a bug that happened -- see Resolve-InstallParameter.
  Passing a parameter is authoritative; clearing is explicit
  (-AdditionalDirectories @(), -ClaudeExe '').

  Order is deliberate. Everything that can refuse does so BEFORE anything is written:
  the name is validated, elevation is checked against the current token, prerequisites
  are resolved and the CLI is proved to support --remote-control. Failing at
  Register-ScheduledTask instead would leave an instance half-built.

.PARAMETER Name
  1-32 characters, letters/digits/dot/dash/underscore, starting alphanumeric. No
  spaces: it goes on a command line, is matched back out of one, and becomes part of a
  scheduled-task name.

.PARAMETER WorkingDirectory
  Where the session runs. Omitted, it inherits from the previous install; on a first
  install it defaults to ~/<name>. Never a home directory -- Remote Control will not
  connect from one.

.PARAMETER AdditionalDirectories
  Directory grants for THIS instance, passed as --add-dir. Default none: an instance
  boots with its working directory and nothing else.

.PARAMETER Elevated
  Run the session with a full admin token (task RunLevel Highest). Off by default
  because it CHANGES HOW THE INSTANCE IS OPERATED: an elevated session cannot be shown
  or hidden from an unelevated shell, since UIPI blocks the window calls silently.
  Requires an elevated caller. -Elevated:$false revokes.

.PARAMETER TriggerDelay
  ISO-8601 logon delay, default PT1M. Stagger it across instances on one host.

.PARAMETER NoTrustSeed
  Skip seeding Claude Code's trust. Expect a modal dialog in a hidden window.

.PARAMETER NoStart
  Register everything but do not start the session.

.OUTPUTS
  Greenroom.Instance for the started session, or Greenroom.InstallResult with -NoStart.

.EXAMPLE
  Install-GreenroomInstance -Name desktop-admin

.EXAMPLE
  Install-GreenroomInstance -Name render-admin -WorkingDirectory D:\render-admin -TriggerDelay PT2M

.EXAMPLE
  Install-GreenroomInstance -Name desktop-admin -Elevated:$false
  Revokes elevation. Takes effect when the instance next restarts.
#>
function Install-GreenroomInstance {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Greenroom.Instance')]
    param(
        # ValueFromPipeline as well as ByPropertyName, so a bare name works and not only
        # a Greenroom.Instance. Piping into an install is safe precisely because a bare
        # re-run inherits: `Get-GreenroomInstance | Install-GreenroomInstance` re-registers
        # every instance without changing any of their settings.
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Instance')]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$')]
        [string]$Name,

        [string]$WorkingDirectory,
        [string]$ClaudeExe,
        [string]$TriggerDelay,
        [string[]]$AdditionalDirectories,
        [switch]$Elevated,
        [switch]$NoTrustSeed,
        [switch]$NoStart,

        [ValidateRange(10, 300)]
        [int]$TimeoutSeconds = 60
    )

    process {
        # Resolved from what the previous install recorded, before anything is touched.
        $s = Resolve-InstallParameter -Name $Name -Bound $PSBoundParameters `
                 -WorkingDirectory $WorkingDirectory -ClaudeExe $ClaudeExe `
                 -TriggerDelay $TriggerDelay -AdditionalDirectories $AdditionalDirectories `
                 -Elevated $Elevated.IsPresent

        # MEASURED: registering RunLevel Highest from a non-elevated shell fails with
        # 'Access is denied'. Checked here rather than at registration, which is the last
        # step -- failing there leaves files written, trust seeded and no task to run any
        # of it.
        if ($s.Elevated -and -not (Test-SelfElevated)) {
            throw ("-Elevated requires an elevated caller. Registering a scheduled task with RunLevel " +
                   'Highest fails with Access Denied otherwise, verified on the reference host. ' +
                   'Nothing has been changed.')
        }

        $pre = Resolve-GreenroomPrerequisite -ClaudeExe $s.ClaudeExe
        Test-GreenroomHostSetting

        if (-not $PSCmdlet.ShouldProcess($Name, 'Install-GreenroomInstance')) { return }

        foreach ($d in @($s.StateDir, $s.WorkingDirectory)) {
            if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        }

        [PSCustomObject]@{
            instance              = $s.Instance
            claudeExe             = $pre.ClaudeExe
            # True when chosen on this run OR inherited from a previous choice. It
            # records a flag ABOUT the value, so it has to be carried forward too.
            claudeExeExplicit     = $s.ClaudeExeExplicit
            workingDirectory      = $s.WorkingDirectory
            triggerDelay          = $s.TriggerDelay
            additionalDirectories = $s.AdditionalDirectories
            # Read to decide whether this shell can act on the window AT ALL, so it is
            # recorded rather than re-derived from the task: it has to be known BEFORE
            # something tries and silently fails.
            elevated              = $s.Elevated
            wt                    = $pre.WindowsTerminal
            pwsh                  = $pre.Pwsh
            installedUtc          = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json | Set-Content -Path (Join-Path $s.StateDir 'config.json') -Encoding UTF8

        Set-ProjectGrant -Directory $s.WorkingDirectory -Grants $s.AdditionalDirectories

        if ($NoTrustSeed) { Write-Warning 'trust seed skipped -- expect a modal dialog inside the hidden window' }
        else { Set-ProjectTrust -Directory $s.WorkingDirectory -BackupDir $s.StateDir | Out-Null }

        Register-GreenroomTask -Name $s.Instance -WorkingDirectory $s.WorkingDirectory `
            -TriggerDelay $s.TriggerDelay -WScriptPath $pre.WScript -Elevated $s.Elevated

        if ($s.Elevated) {
            Write-Warning ("'$($s.Instance)' runs ELEVATED. Showing and hiding it now need an elevated shell too: " +
                           'UIPI blocks the window calls from a lower integrity level. Nothing on screen marks ' +
                           "the session as elevated -- Get-GreenroomInstance is how you tell. Revoke with " +
                           "Install-GreenroomInstance -Name $($s.Instance) -Elevated:`$false")
        }

        if ($NoStart) {
            return [PSCustomObject]@{
                PSTypeName       = 'Greenroom.InstallResult'
                Instance         = $s.Instance
                WorkingDirectory = $s.WorkingDirectory
                TaskName         = $s.TaskName
                Elevated         = $s.Elevated
                Started          = $false
            }
        }

        Start-ScheduledTask -TaskName $s.TaskName
        $up = Wait-GreenroomSession -Name $s.Instance -TimeoutSeconds $TimeoutSeconds

        # Verify the seed SURVIVED rather than assuming it did. Any other claude.exe on
        # the host can rewrite ~/.claude.json between the seed and the launch, and the
        # consequence is a modal dialog in a window nobody can see.
        if (-not $NoTrustSeed -and -not (Test-TrustSurvived -Directory $s.WorkingDirectory)) {
            Write-Warning 'trust seed did NOT survive -- something rewrote ~/.claude.json. Re-seeding.'
            Set-ProjectTrust -Directory $s.WorkingDirectory -BackupDir $s.StateDir | Out-Null

            if (Test-TrustSurvived -Directory $s.WorkingDirectory) {
                Write-Warning 'trust re-seeded; restarting the session so it picks the seed up.'
                # Trust is read at startup, so a session already sitting on the dialog
                # will not pick up the re-seed. Restart-GreenroomSession stops the
                # supervisor BY PROCESS first, which is the only thing that works here --
                # Stop-ScheduledTask is a no-op against this architecture.
                $up = Restart-GreenroomSession -Name $s.Instance -TimeoutSeconds $TimeoutSeconds
            }
            else {
                Write-Warning ('RE-SEED FAILED. Expect a modal trust dialog inside the hidden window: show ' +
                               'the session and accept it by hand, or close other claude.exe and install again.')
            }
        }

        if (-not $up) {
            Write-Error -Category OperationTimeout -Message (
                "'$($s.Instance)' did not come up within $TimeoutSeconds s. Check: Get-Content " +
                "`"$(Join-Path $s.StateDir 'watchdog.log')`" -Tail 20")
            return
        }

        return $up
    }
}

