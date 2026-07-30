# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Show-, Hide- and Restart-GreenroomSession: the decision logic, with every effect
  mocked. No windows move and no processes are killed.

  The properties worth pinning down are the ones that were bugs in the script this
  replaces: that -WhatIf really performs nothing, that an unresolvable window refuses
  instead of acting, and that restarting the session you are running inside is refused
  rather than bricking the instance.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force
}

AfterAll { Remove-Module Greenroom -Force -ErrorAction SilentlyContinue }

Describe 'Show-GreenroomSession / Hide-GreenroomSession' {

    BeforeEach {
        Mock -ModuleName Greenroom Resolve-GreenroomTarget {
            [PSCustomObject]@{
                PSTypeName = 'Greenroom.Instance'
                Instance   = 'probe'; ClaudePid = 1001; TerminalPid = 2001
                Window     = [IntPtr]::new(4242); Visible = $false
                Elevated   = $false; Opaque = $false
            }
        }
        Mock -ModuleName Greenroom Assert-CanActOnInstance { $true }
        Mock -ModuleName Greenroom Set-WindowVisible { $true }
        Mock -ModuleName Greenroom Get-WindowFailureReason { 'mocked failure reason' }
    }

    It 'shows the window with Show = true' {
        Show-GreenroomSession -Name probe
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 1 -Exactly `
            -ParameterFilter { $Show -eq $true }
    }

    It 'hides the window with Show = false' {
        Hide-GreenroomSession -Name probe
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 1 -Exactly `
            -ParameterFilter { $Show -eq $false }
    }

    It 'is silent on success' {
        # An operator watches the window appear; a pipeline of ten should not print ten
        # confirmations.
        Show-GreenroomSession -Name probe | Should -BeNullOrEmpty
    }

    It 'performs nothing under -WhatIf' {
        Show-GreenroomSession -Name probe -WhatIf
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 0
    }

    It 'validates before -WhatIf, so it cannot claim it would act on a dead instance' {
        Mock -ModuleName Greenroom Resolve-GreenroomTarget { $null }
        Show-GreenroomSession -Name nope -WhatIf
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 0
        Should -Invoke -ModuleName Greenroom Assert-CanActOnInstance -Times 0
    }

    It 'requires a resolved window' {
        Show-GreenroomSession -Name probe
        Should -Invoke -ModuleName Greenroom Resolve-GreenroomTarget -Times 1 -Exactly `
            -ParameterFilter { $RequireWindow -eq $true }
    }

    It 'does not act when escalation says the work was handled elsewhere' {
        # Assert-CanActOnInstance returning false means an elevated copy already did it,
        # or the caller was refused. Either way this process must not also act.
        Mock -ModuleName Greenroom Assert-CanActOnInstance { $false }
        Show-GreenroomSession -Name probe
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 0
    }

    It 'errors when the window did not change state' {
        # ShowWindow cannot report failure; only observation can. A silent no-op is the
        # failure mode this check exists for.
        Mock -ModuleName Greenroom Set-WindowVisible { $false }
        { Show-GreenroomSession -Name probe -ErrorAction Stop } | Should -Throw
    }

    It 'accepts a Greenroom.Instance from the pipeline via the Instance alias' {
        [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = 'probe' } | Show-GreenroomSession
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 1 -Exactly
    }

    It 'processes every item piped in' {
        'a', 'b', 'c' | Show-GreenroomSession
        Should -Invoke -ModuleName Greenroom Set-WindowVisible -Times 3 -Exactly
    }
}

Describe 'Assert-CanActOnInstance' {

    BeforeEach {
        Mock -ModuleName Greenroom Test-InstanceElevated { $true }
        Mock -ModuleName Greenroom Test-SelfElevated { $false }
        Mock -ModuleName Greenroom Invoke-ElevatedSelf { 0 }
    }

    It 'escalates for a real run against an elevated instance' {
        $r = InModuleScope Greenroom { Assert-CanActOnInstance -Name probe -Command 'Show-GreenroomSession' }
        $r | Should -BeFalse -Because 'the elevated copy did the work, so the caller must not also act'
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 1 -Exactly
    }

    It 'does NOT escalate under -WhatIf' {
        # Escalation runs the command again in a NEW process, and -WhatIf is not
        # forwarded to it -- so a dry run would raise a UAC prompt and then PERFORM THE
        # REAL ACTION over there. A -WhatIf that acts is worse than no -WhatIf at all.
        # Setting $WhatIfPreference is exactly what PowerShell does for -WhatIf.
        $r = InModuleScope Greenroom {
            $WhatIfPreference = $true
            Assert-CanActOnInstance -Name probe -Command 'Show-GreenroomSession'
        }
        $r | Should -BeTrue -Because 'the caller proceeds locally, where its own ShouldProcess reports and changes nothing'
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 0
    }

    It 'refuses instead of escalating under -NoElevate' {
        $r = InModuleScope Greenroom {
            Assert-CanActOnInstance -Name probe -Command 'Show-GreenroomSession' -NoElevate -ErrorAction SilentlyContinue
        }
        $r | Should -BeFalse
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 0
    }

    It 'does not escalate at all when the instance is not elevated' {
        Mock -ModuleName Greenroom Test-InstanceElevated { $false }
        $r = InModuleScope Greenroom { Assert-CanActOnInstance -Name probe -Command 'Show-GreenroomSession' }
        $r | Should -BeTrue
        Should -Invoke -ModuleName Greenroom Invoke-ElevatedSelf -Times 0
    }
}

Describe 'Restart-GreenroomSession' {

    BeforeEach {
        Mock -ModuleName Greenroom Get-ScheduledTask { [PSCustomObject]@{ TaskName = 'greenroom-probe' } }
        Mock -ModuleName Greenroom Test-SelfIsInstance { $false }
        Mock -ModuleName Greenroom Assert-CanActOnInstance { $true }
        Mock -ModuleName Greenroom Stop-VerifiedProcess { 1 }
        Mock -ModuleName Greenroom Start-ScheduledTask { }
        Mock -ModuleName Greenroom Start-Sleep { }
        Mock -ModuleName Greenroom Get-GreenroomInstance {
            [PSCustomObject]@{ PSTypeName = 'Greenroom.Instance'; Instance = 'probe'; ClaudePid = 1234; Opaque = $false }
        }
    }

    It 'stops the watchdog, the session and the launcher' {
        Restart-GreenroomSession -Name probe | Out-Null
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 3 -Exactly
    }

    It 'stops the watchdog FIRST, or it resurrects the session before the task runs' {
        Restart-GreenroomSession -Name probe | Out-Null
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 1 -Exactly `
            -ParameterFilter { $Label -eq 'watchdog' }
    }

    It 'starts the task again' {
        Restart-GreenroomSession -Name probe | Out-Null
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 1 -Exactly
    }

    It 'returns the restarted instance' {
        (Restart-GreenroomSession -Name probe).Instance | Should -Be 'probe'
    }

    It 'REFUSES to restart the session the shell is running inside' {
        # Killing an ancestor mid-run leaves the instance DOWN rather than restarted,
        # and calling it from inside the session is the most natural way to reach for it.
        Mock -ModuleName Greenroom Test-SelfIsInstance { $true }
        { Restart-GreenroomSession -Name probe -ErrorAction Stop } | Should -Throw
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 0
    }

    It 'refuses when the instance has no scheduled task' {
        Mock -ModuleName Greenroom Get-ScheduledTask { $null }
        { Restart-GreenroomSession -Name nope -ErrorAction Stop } | Should -Throw
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
    }

    It 'kills nothing under -WhatIf' {
        Restart-GreenroomSession -Name probe -WhatIf
        Should -Invoke -ModuleName Greenroom Stop-VerifiedProcess -Times 0
        Should -Invoke -ModuleName Greenroom Start-ScheduledTask -Times 0
    }

    It 'checks the self-restart guard before doing anything destructive' {
        Restart-GreenroomSession -Name probe | Out-Null
        Should -Invoke -ModuleName Greenroom Test-SelfIsInstance -Times 1 -Exactly
    }
}
