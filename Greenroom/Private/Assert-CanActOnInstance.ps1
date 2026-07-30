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

    # Single-quoted inside the -Command string so nothing is re-interpreted by the
    # elevated shell, with embedded quotes doubled -- which is how PowerShell escapes a
    # quote inside a single-quoted string.
    #
    # The instance name cannot contain one (ValidatePattern allows only letters, digits,
    # dot, dash and underscore) but THE MODULE PATH CAN: a home directory belonging to
    # someone called O'Brien is enough to break the command otherwise.
    $manifest = (Join-Path $script:GreenroomModuleRoot 'Greenroom.psd1').Replace("'", "''")
    $safeName = $Name.Replace("'", "''")

    # -Confirm:$false, deliberately. The caller has ALREADY passed its own ShouldProcess
    # gate before escalating, so the decision is made; a fresh process would otherwise
    # start with default preferences and either prompt a second time or, worse, not
    # prompt at all because -Confirm was never forwarded.
    #
    # ErrorActionPreference=Stop and an explicit exit, NOT $LASTEXITCODE. That variable
    # is only set by NATIVE commands, so a PowerShell function that fails with a
    # non-terminating Write-Error leaves it untouched -- and in a fresh process it is
    # $null, which exits 0. MEASURED: an inner command whose function wrote a
    # non-terminating error exited 0, so every recoverable failure over there was
    # reported here as success, and the caller then skipped acting locally on the
    # strength of work that never happened.
    #
    # The error TEXT is still lost, because the elevated window closes as it exits.
    # The exit code is what crosses the boundary, so it has to be right.
    $inner = "`$ErrorActionPreference='Stop'; " +
             "try { Import-Module '$manifest' -Force; " +
             "$Command -Name '$safeName' -NoElevate -Confirm:`$false; exit 0 } " +
             'catch { exit 1 }'

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

    # A BACKSTOP, not the primary guard. Every public command gates on ShouldProcess
    # BEFORE calling this, so under -WhatIf escalation is already unreachable. This
    # stays because the cost of the ordering silently regressing is a dry run that
    # raises a UAC prompt and then performs the real action in the other process --
    # which is exactly what happened before that ordering was fixed.
    #
    # $WhatIfPreference is inherited by called functions, verified rather than assumed.
    if ($WhatIfPreference) {
        Write-Verbose "'$Name' runs elevated; not escalating because -WhatIf changes nothing anyway"
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
