# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Restart an instance's session, supervisor and launcher.

.DESCRIPTION
  This exists because the procedure it replaces did not restart anything. The advice
  was to stop the watchdog by process and then run Start-ScheduledTask -- but stopping
  the watchdog leaves the session running, and the new watchdog then ADOPTS it. The
  result is the old session with a new supervisor, which is precisely not a restart.
  Measured on the reference host: an instance reinstalled with -Elevated kept running
  at Medium integrity through exactly that sequence.

  Order matters. The watchdog goes first, because killing the session first makes the
  watchdog immediately restart it, and the subsequent task start is then a no-op
  against a session that never went away.

  Everything is driven from the instance NAME, its scheduled task and config.json,
  never from session discovery. Discovery reads CommandLine, which is NULL across
  integrity levels, so a discovery-driven restart would be unusable from an unelevated
  shell against an elevated instance.

  REFUSES to restart the instance the calling shell is running inside. That would kill
  an ancestor of this process before the task is started again, leaving the instance
  down rather than restarted -- and calling it from inside the session is the most
  natural way to reach for it.

.PARAMETER Name
  The instance to restart. If omitted and exactly one instance is installed, that one
  is used. Accepts pipeline input, including Greenroom.Instance objects.

.PARAMETER NoElevate
  Do not escalate when the instance runs elevated. Fails instead.

.PARAMETER TimeoutSeconds
  How long to wait for the replacement session to appear. Default 45.

.OUTPUTS
  Greenroom.Instance for the restarted session, or nothing if it could not be confirmed.

.EXAMPLE
  Restart-GreenroomSession laptop-admin

.EXAMPLE
  Restart-GreenroomSession laptop-admin -WhatIf
  Shows what would be stopped without touching anything.

.EXAMPLE
  Get-GreenroomInstance | Where-Object { $null -eq $_.Window } | Restart-GreenroomSession
  Restart every instance whose window cannot be resolved, which is how an instance
  gets a window record if it started before records existed.
#>
function Restart-GreenroomSession {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Greenroom.Instance')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Instance')]
        [string]$Name,

        [switch]$NoElevate,

        [ValidateRange(5, 300)]
        [int]$TimeoutSeconds = 45
    )

    process {
        if (-not $Name) {
            $known = @(Get-ChildItem (Get-GreenroomStateRoot) -Directory -ErrorAction SilentlyContinue)
            if ($known.Count -eq 1) { $Name = $known[0].Name }
            else {
                Write-Error -Category InvalidArgument -Message (
                    "an instance name is required. Installed: $($known.Name -join ', ')")
                return
            }
        }

        $task = "greenroom-$Name"
        if (-not (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue)) {
            Write-Error -Category ObjectNotFound -Message "no scheduled task '$task' -- is '$Name' installed?"
            return
        }

        if (Test-SelfIsInstance -Name $Name) {
            Write-Error -Category InvalidOperation -Message (
                "'$Name' is the session this shell is running inside. Restarting it from here would kill " +
                'this process partway through, before the task is started again, leaving the instance down ' +
                "rather than restarted. Run it from a shell outside the session.")
            return
        }

        if (-not (Assert-CanActOnInstance -Name $Name -Command 'Restart-GreenroomSession' -NoElevate:$NoElevate)) {
            return
        }

        if (-not $PSCmdlet.ShouldProcess($Name, 'Restart-GreenroomSession')) { return }

        $esc = [regex]::Escape($Name)

        $stopped =
            (Stop-VerifiedProcess -ProcessName 'pwsh.exe'   -Pattern "greenroom-watchdog.*-Instance\s+`"?$esc\b" -Label 'watchdog') +
            (Stop-VerifiedProcess -ProcessName 'claude.exe' -Pattern "--remote-control\s+$esc\b"                 -Label 'session')  +
            (Stop-VerifiedProcess -ProcessName 'pwsh.exe'   -Pattern "greenroom-launch.*-Instance\s+`"?$esc\b"   -Label 'launcher')

        if ($stopped -eq 0) { Write-Verbose "nothing was running for '$Name'" }

        Start-Sleep -Seconds 2
        Start-ScheduledTask -TaskName $task

        # Confirm by observation. The task returning success only means the watchdog was
        # launched, not that a session came up behind it.
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 750
            $up = @(Get-GreenroomInstance -Name $Name -WarningAction SilentlyContinue)
            if ($up.Count -eq 1 -and -not $up[0].Opaque) { return $up[0] }
        }

        # An unelevated shell cannot read an elevated session's command line, so absence
        # here is not evidence of failure. Saying so beats reporting a false one.
        if ((Test-InstanceElevated -Name $Name) -and -not (Test-SelfElevated)) {
            Write-Warning ("cannot confirm '$Name' from an unelevated shell: an elevated session is " +
                           'unreadable here. Re-check with Get-GreenroomInstance from an elevated shell.')
            return
        }

        Write-Error -Category OperationTimeout -Message (
            "'$Name' did not come up within $TimeoutSeconds s. Check: Get-Content " +
            "`"$(Join-Path (Get-GreenroomStateRoot) "$Name\watchdog.log")`" -Tail 20")
    }
}
