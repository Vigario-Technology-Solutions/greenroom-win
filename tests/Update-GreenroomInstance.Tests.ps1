# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Update-GreenroomInstance moves instances onto the loaded module version.

  Everything it does is delegated -- Install- rewrites the task and config, Restart- brings
  the session back -- so what is worth testing is the DECIDING: which instances it picks,
  which it leaves alone, and that it never acts under -WhatIf.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force
    $script:Loaded = InModuleScope Greenroom { $script:GreenroomModuleVersion }
}

AfterAll { Remove-Module Greenroom -Force -ErrorAction SilentlyContinue }

Describe 'Update-GreenroomInstance' {

    BeforeEach {
        Mock -ModuleName Greenroom Get-ScheduledTask {
            @(
                [PSCustomObject]@{ TaskName = 'greenroom-alpha' }
                [PSCustomObject]@{ TaskName = 'greenroom-beta' }
            )
        }
        Mock -ModuleName Greenroom Install-GreenroomInstance { }
        Mock -ModuleName Greenroom Restart-GreenroomSession { }
        # alpha is behind, beta is current.
        Mock -ModuleName Greenroom Get-InstanceAssetVersion {
            if ($Name -eq 'alpha') { [version]'0.0.1' } else { $script:GreenroomModuleVersion }
        }
    }

    It 'updates only the instance that is behind' {
        Update-GreenroomInstance
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly `
            -ParameterFilter { $Name -eq 'alpha' }
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 0 `
            -ParameterFilter { $Name -eq 'beta' }
    }

    It 're-registers without starting, then restarts' {
        # -NoStart matters: Install- would otherwise launch a session that Restart- then
        # kills, and the launch is the expensive half.
        Update-GreenroomInstance
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly `
            -ParameterFilter { $NoStart }
        Should -Invoke -ModuleName Greenroom Restart-GreenroomSession -Times 1 -Exactly `
            -ParameterFilter { $Name -eq 'alpha' }
    }

    It 'touches nothing under -WhatIf' {
        Update-GreenroomInstance -WhatIf
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 0
        Should -Invoke -ModuleName Greenroom Restart-GreenroomSession -Times 0
    }

    It 're-registers everything under -Force' {
        Update-GreenroomInstance -Force
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 2 -Exactly
    }

    It 'honours -Name' {
        Update-GreenroomInstance -Name 'bet*' -Force
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly `
            -ParameterFilter { $Name -eq 'beta' }
    }

    It 'does not restart under -NoRestart' {
        Update-GreenroomInstance -NoRestart
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly
        Should -Invoke -ModuleName Greenroom Restart-GreenroomSession -Times 0
    }

    It 'leaves an unversioned path alone -- there is nothing to move' {
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { $null }
        Update-GreenroomInstance
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 0
    }

    It 'warns rather than silently doing nothing when no instance matches' {
        Update-GreenroomInstance -Name 'nope' -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match 'no registered instance matches'
    }

    It 'warns when the host has no instances at all' {
        Mock -ModuleName Greenroom Get-ScheduledTask { @() }
        Update-GreenroomInstance -WarningVariable w -WarningAction SilentlyContinue
        "$w" | Should -Match 'no greenroom instances'
    }

    It 'carries on to the next instance when one fails to re-register' {
        # A declined elevation on one instance must not strand the rest of the host.
        Mock -ModuleName Greenroom Get-InstanceAssetVersion { [version]'0.0.1' }
        Mock -ModuleName Greenroom Install-GreenroomInstance {
            if ($Name -eq 'alpha') { throw 'elevation declined' }
        }
        Update-GreenroomInstance -ErrorAction SilentlyContinue -ErrorVariable e
        Should -Invoke -ModuleName Greenroom Install-GreenroomInstance -Times 1 -Exactly `
            -ParameterFilter { $Name -eq 'beta' }
        "$e" | Should -Match 'alpha'
    }

    It 'does not restart an instance whose re-registration failed' {
        Mock -ModuleName Greenroom Install-GreenroomInstance { throw 'nope' }
        Update-GreenroomInstance -ErrorAction SilentlyContinue
        Should -Invoke -ModuleName Greenroom Restart-GreenroomSession -Times 0
    }
}
