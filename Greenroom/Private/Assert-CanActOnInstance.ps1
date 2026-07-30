# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Re-run a command elevated, in a new process, and return its exit code.

  An unelevated shell cannot show, hide or foreground a window owned by an elevated
  process. MEASURED rather than taken from documentation: ShowWindow(SW_HIDE) against
  an elevated window returned false with GetLastWin32Error 5 (ERROR_ACCESS_DENIED) and
  the window did not move. No exception, no prompt. Acting anyway prints success and
  does nothing.

  Refusing would be safe but useless -- the operator still wants the window. So
  re-launch elevated and let the elevated copy do the work. A UAC prompt is acceptable
  here because this is an interactive command someone just typed. That is the opposite
  of the logon path, where a UAC dialog behind a hidden window would be an invisible
  hang, which is why the session takes its token from the task trigger instead.

  The module is imported BY PATH, not by name. Resolving by name would depend on
  PSModulePath being identical in the elevated context, and an explicit path removes
  that dependency entirely.
#>
function Invoke-ElevatedSelf {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Name
    )

    Write-Warning "'$Name' runs elevated and this shell does not. Re-launching elevated..."

    $manifest = Join-Path $script:GreenroomModuleRoot 'Greenroom.psd1'
    # Single-quoted inside the -Command string so nothing in a path or an instance name
    # is re-interpreted by the elevated shell. Instance names are validated on install
    # to letters, digits, dot, dash and underscore, so they cannot contain a quote.
    $inner = "Import-Module '$manifest' -Force; $Command -Name '$Name' -NoElevate; exit `$LASTEXITCODE"

    try {
        $p = Start-Process pwsh -Verb RunAs -PassThru -Wait -ErrorAction Stop `
                 -ArgumentList '-NoLogo', '-NoProfile', '-Command', $inner
        return $p.ExitCode
    }
    catch {
        # The usual cause is the UAC prompt being dismissed, which is a decision rather
        # than a fault, so it is reported as one.
        throw "elevation declined or failed -- '$Name' was not changed. To do it by hand: Start-Process pwsh -Verb RunAs -ArgumentList '-NoExit','-Command',`"$inner`""
    }
}

<#
  Decide whether this shell may act on an instance's window, and escalate if not.

  Returns $true when the caller should proceed itself, $false when the work has
  already been done by an elevated copy.
#>
function Assert-CanActOnInstance {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [switch]$NoElevate
    )

    # config.json is readable at any integrity level, so its flag is trustworthy even
    # where the process command line is not.
    if (-not (Test-InstanceElevated -Name $Name)) { return $true }
    if (Test-SelfElevated) { return $true }

    # UNDER -WhatIf, DO NOT ESCALATE.
    #
    # Escalation runs the command again in a new elevated process, and -WhatIf was not
    # forwarded to it -- so a dry run against an elevated instance would raise a UAC
    # prompt and then PERFORM THE REAL ACTION in the other process. A -WhatIf that acts
    # is worse than no -WhatIf at all.
    #
    # Forwarding -WhatIf would technically fix that, but escalating for a dry run is
    # pointless anyway: it prompts for administrator rights in order to do nothing, and
    # prints its "What if" into a window the operator may never see. Returning true here
    # lets the caller's own ShouldProcess report the intent locally and change nothing.
    #
    # $WhatIfPreference is inherited by called functions, verified rather than assumed.
    if ($WhatIfPreference) {
        Write-Verbose "'$Name' runs elevated; skipping escalation because -WhatIf changes nothing anyway"
        return $true
    }

    if ($NoElevate) {
        Write-Error -Category PermissionDenied -Message (
            "'$Name' runs ELEVATED and this shell does not. UIPI blocks ShowWindow and " +
            'SetForegroundWindow from a lower integrity level, so the operation would report ' +
            'success and do nothing at all. -NoElevate was passed, so this is not being ' +
            'escalated automatically.')
        return $false
    }

    $code = Invoke-ElevatedSelf -Command $Command -Name $Name
    if ($code -ne 0) {
        Write-Error "the elevated '$Command' for '$Name' exited with code $code."
    }
    return $false
}
