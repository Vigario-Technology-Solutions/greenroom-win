# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Show or hide a window, and CONFIRM IT BY OBSERVATION.

  ShowWindow's return value cannot be used for this, and neither can GetLastError.
  Measured on the reference host 2026-07-29, both directions returned false:

    unelevated -> elevated window : returned false, error 5,    window did NOT move
    elevated   -> normal  window  : returned false, error 1461, window DID move

  The return value is documented as the window's PREVIOUS visibility, not success, so
  it is false for every attach -- because every attach starts from hidden. The only
  trustworthy signal is whether IsWindowVisible actually changed.

  Everything about a hidden session is invisible by construction, so reporting
  "attached" without checking is exactly how a no-op gets mistaken for success.

  Returns $true on confirmed change, $false otherwise. Diagnosis of a failure is the
  caller's to report, because only the caller knows whether it is mid-pipeline.
#>
function Set-WindowVisible {
    # No ShouldProcess here. The gate belongs to the public command, which calls
    # ShouldProcess after resolving and before reaching this -- a second gate would
    # either be dead code or prompt twice for one action. This function is private and
    # unreachable from outside the module, so there is no caller it could protect.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [Parameter(Mandatory)][bool]$Show
    )

    $before = [Greenroom.Win1]::IsWindowVisible($Handle)
    [Greenroom.Win1]::ShowWindow($Handle, $(if ($Show) { $script:SW_RESTORE } else { $script:SW_HIDE })) | Out-Null
    if ($Show) { [Greenroom.Win1]::SetForegroundWindow($Handle) | Out-Null }

    # The window manager is asynchronous; IsWindowVisible immediately after the call
    # can still report the old state.
    Start-Sleep -Milliseconds 250
    $after = [Greenroom.Win1]::IsWindowVisible($Handle)

    Write-Verbose "window $Handle visible before=$before after=$after (wanted $Show)"
    return ($after -eq $Show)
}

<#
  Why a window operation most likely failed, as a sentence.

  Split out so Show- and Hide- report identically without duplicating the reasoning,
  and so the guess about UIPI is made in one place.
#>
function Get-WindowFailureReason {
    param([Parameter(Mandatory)][string]$Name)

    $msg = "the window for '$Name' did not change state. The session is unaffected; only the window operation failed."
    if (-not (Test-SelfElevated)) {
        $msg += " Most likely cause: the window belongs to a higher-integrity process and UIPI refused the call, which it does silently. Re-run from an elevated shell."
    }
    return $msg
}
