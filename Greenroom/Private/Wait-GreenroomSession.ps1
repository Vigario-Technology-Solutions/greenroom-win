# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Wait for an instance's session to appear, and return it.

  Confirms by observation: Start-ScheduledTask succeeding only means the watchdog was
  launched, not that a session came up behind it.
#>
function Wait-GreenroomSession {
    [CmdletBinding()]
    [OutputType('Greenroom.Instance')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 750
        $found = @(Get-GreenroomInstance -Name $Name -WarningAction SilentlyContinue)
        if ($found.Count -eq 1 -and -not $found[0].Opaque) { return $found[0] }
    }
    return $null
}
