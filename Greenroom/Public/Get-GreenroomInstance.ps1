# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
.SYNOPSIS
  Get the greenroom sessions running on this host.

.DESCRIPTION
  Emits one object per running session. This is the module replacement for
  `greenroom list` and `greenroom status`, which were separate verbs only because a
  script had to choose its own output shape -- `list` piped through
  Format-Table -AutoSize and `status` printed a block of text.

  The difference is not cosmetic. `greenroom list` wrote FORMATTED TEXT to the host,
  so anything downstream received formatting records rather than data:

      PS> greenroom status laptop-admin | ForEach-Object { "  $_" }
        Microsoft.PowerShell.Commands.Internal.Format.FormatStartData
        Microsoft.PowerShell.Commands.Internal.Format.GroupStartData
        ...

  That is measured output from this repository's own tooling. Emitting objects and
  leaving presentation to Greenroom.format.ps1xml makes the table a VIEW of the data
  rather than the only thing produced, so filtering works:

      Get-GreenroomInstance | Where-Object Elevated
      Get-GreenroomInstance | Where-Object { -not $_.Visible } | Show-GreenroomSession

.PARAMETER Name
  Only return instances with this name. Wildcards are supported.

.EXAMPLE
  Get-GreenroomInstance

.EXAMPLE
  Get-GreenroomInstance -Name laptop-admin | Select-Object -ExpandProperty Window

.EXAMPLE
  Get-GreenroomInstance | Where-Object { $_.Window -eq $null }
  Instances whose window could not be resolved. Add -Verbose for the reason each.

.OUTPUTS
  Greenroom.Instance
#>
function Get-GreenroomInstance {
    [CmdletBinding()]
    [OutputType('Greenroom.Instance')]
    param(
        [Parameter(Position = 0)]
        [SupportsWildcards()]
        [string]$Name
    )

    $sessions = @(Get-SessionProcess)

    if ($Name) {
        $sessions = @($sessions | Where-Object { $_.Instance -like $Name })
    }

    # Advisory notes go to the Warning stream, not the host. Write-Host cannot be
    # captured, redirected or suppressed, so a caller assembling a report has no way
    # to opt out of it -- which is why PSAvoidUsingWriteHost is a rule rather than a
    # style opinion. Both notes below are about the SHELL, not the sessions: run
    # elevated and they stop applying.
    if (-not (Test-SelfElevated)) {
        $opaque = @($sessions | Where-Object Opaque)
        if ($opaque.Count -gt 0) {
            Write-Warning "$($opaque.Count) claude.exe process(es) expose no command line to this shell, which is how a higher-integrity process looks from an unelevated one. They cannot be named from here, and some may not be greenroom at all. Re-run elevated for a complete listing."
        }
    }

    foreach ($s in $sessions) {
        $th  = if ($s.Opaque) { $null } else { Get-TerminalHost $s.Claude }
        $hnd = $null
        $vis = $null

        if ($th) {
            # -Verbose flows through, so `Get-GreenroomInstance -Verbose` explains every
            # unresolved window without this function knowing how to phrase it.
            $hnd = Resolve-SessionWindow -HostPid $th.ProcessId -ClaudePid $s.Pid -Name $s.Instance
            if ($hnd) { $vis = [Greenroom.Win1]::IsWindowVisible($hnd) }
        }

        # $null rather than the strings 'unresolved' and 'n/a' the script used. A column
        # that is sometimes a handle and sometimes prose cannot be compared or filtered;
        # $null can, and the format view renders it as an empty cell either way.
        [PSCustomObject]@{
            PSTypeName  = 'Greenroom.Instance'
            Instance    = $s.Instance
            ClaudePid   = $s.Pid
            TerminalPid = if ($th) { [int]$th.ProcessId } else { $null }
            Window      = $hnd
            Visible     = $vis
            Elevated    = if ($s.Opaque) { $null } else { Test-InstanceElevated -Name $s.Instance }
            Opaque      = $s.Opaque
        }
    }
}
