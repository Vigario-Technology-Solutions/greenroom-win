# PSScriptAnalyzer settings for greenroom-win.
#
# Severity is Error and Warning. Information is not included: it is dominated by
# formatting opinions that would be a large diff for no behaviour change, and a
# check nobody can keep green stops being read.
#
# Every exclusion below was measured against this codebase and is listed with the
# reason it does not apply here. The rule is that an exclusion names its cause --
# a settings file that silences whatever happens to be red teaches nothing, and
# the next person cannot tell a deliberate exemption from an unexamined one.

@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # 71 hits, all correct usage. These scripts are an interactive CLI whose
        # output IS the product: install.ps1 narrates a checklist to a human, and
        # greenroom.ps1 reports what it found and refused. Write-Output would put
        # that prose on the success stream, where it would be captured by any
        # caller doing `$x = greenroom list` and would corrupt the return value.
        # Write-Host is the correct cmdlet for a terminal UI, which is why this
        # rule ships as a warning rather than an error.
        'PSAvoidUsingWriteHost',

        # 6 hits, all on private functions inside a script -- Start-RcSession,
        # Restart-Instance, Stop-Verified, Set-WindowVisible, Set-ProjectGrants,
        # Set-ProjectTrust. SupportsShouldProcess exists so that an exported
        # cmdlet honours -WhatIf and -Confirm from a caller. None of these are
        # exported or callable from outside their own script; the user-facing
        # surface is a verb argument (`greenroom detach <name>`), which does its
        # own confirming. Adding the plumbing would be ceremony that no caller
        # can reach.
        'PSUseShouldProcessForStateChangingFunctions',

        # 3 hits: Get-AllSessions, Test-PluginMarketplaces, Set-ProjectGrants.
        # Each genuinely operates on a collection, so the plural is the accurate
        # name. Renaming Get-AllSessions to Get-AllSession would make it read as
        # though it returns one.
        'PSUseSingularNouns',

        # 4 hits, all structural false positives.
        #   3x  the `$l` in `param($h, $l)` inside an EnumWindowsProc callback.
        #       The Win32 signature is BOOL CALLBACK(HWND, LPARAM), so the
        #       delegate requires both parameters. We pass IntPtr.Zero as lParam
        #       and correctly ignore it -- and it cannot be dropped, because then
        #       the scriptblock no longer matches the delegate.
        #   1x  greenroom.ps1's -NoElevate, which is read at line 160 inside
        #       Assert-CanActOnInstance. The analyzer does not trace a script
        #       parameter used as a script-scope variable inside a function.
        # Kept as an exclusion rather than per-site suppression because
        # SuppressMessageAttribute cannot be attached to a bare scriptblock.
        'PSReviewUnusedParameter'
    )
}
