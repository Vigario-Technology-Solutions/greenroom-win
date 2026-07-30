# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Resolve a name to exactly one actionable session, or write the reason and return
  $null.

  Read-only by design, and separate from the acting functions on purpose: validation
  has to happen BEFORE ShouldProcess, or -WhatIf would cheerfully report that it would
  show a window for an instance that is not running.

  Resolves through the public Get-GreenroomInstance rather than re-implementing
  discovery, so it cannot disagree with what a listing reports and gets the
  opaque-process handling for free.
#>
function Resolve-GreenroomTarget {
    [CmdletBinding()]
    [OutputType('Greenroom.Instance')]
    param(
        [AllowEmptyString()][string]$Name,

        # Window resolution only matters to callers that are about to touch a window.
        [switch]$RequireWindow
    )

    $found = if ($Name) { @(Get-GreenroomInstance -Name $Name) } else { @(Get-GreenroomInstance) }

    if ($found.Count -eq 0) {
        $msg = if ($Name) { "no greenroom session named '$Name' is running." }
               else { 'no greenroom session is running.' }
        Write-Error -Category ObjectNotFound -Message $msg
        return $null
    }

    if ($found.Count -gt 1) {
        Write-Error -Category InvalidArgument -Message (
            "several sessions match: $($found.Instance -join ', '). Name one, or pipe a single instance in.")
        return $null
    }

    $target = $found[0]

    if ($target.Opaque) {
        Write-Error -Category PermissionDenied -Message (
            "'$($target.Instance)' cannot be identified from this shell -- its command line reads as NULL " +
            'across the integrity boundary, which is how an elevated process looks from an unelevated one. ' +
            'Re-run from an elevated shell.')
        return $null
    }

    if ($RequireWindow -and $null -eq $target.Window) {
        Write-Error -Category ObjectNotFound -Message (
            "no usable window record for '$($target.Instance)', so its window cannot be resolved. " +
            "Re-run with -Verbose for the specific reason, then: Restart-GreenroomSession -Name $($target.Instance)")
        return $null
    }

    return $target
}
