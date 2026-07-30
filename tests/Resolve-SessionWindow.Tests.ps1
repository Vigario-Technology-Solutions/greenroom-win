# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  The window-record validation, which is the part of this module where being wrong is
  worst: a stale record that passes validation makes attach act on somebody else's
  window, and Windows reuses handles after a window closes.

  Every branch is exercised against a real file in a temp state root, with only
  Get-GreenroomStateRoot and the window enumeration mocked. Two of these cases are
  regressions -- the empty file and the pid mismatch both produced wrong behaviour
  before they were fixed.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force

    $script:StateRoot = Join-Path ([IO.Path]::GetTempPath()) "greenroom-tests-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path (Join-Path $StateRoot 'probe') -Force | Out-Null
    $script:RecordPath = Join-Path $script:StateRoot 'probe\session.json'

    # Defined here, not in the Describe body: a Describe body runs during Pester's
    # DISCOVERY phase, so anything declared there is gone by the time an It executes.
    # BeforeAll runs in the run phase and its scope is what It blocks inherit.
    function WriteRecord {
        param($Object)
        $Object | ConvertTo-Json | Set-Content $script:RecordPath
    }

    # Resolve-SessionWindow is private, so it is reached through InModuleScope -- which
    # is the point of having a module boundary and still being able to test behind it.
    function Invoke-Resolve {
        InModuleScope Greenroom {
            Resolve-SessionWindow -HostPid 2001 -ClaudePid 1001 -Name 'probe'
        }
    }
}

AfterAll {
    if (Test-Path $script:StateRoot) { Remove-Item $script:StateRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
}

Describe 'Resolve-SessionWindow' {

    BeforeEach {
        Mock -ModuleName Greenroom Get-GreenroomStateRoot { $script:StateRoot }
        # A live window matching the handle the valid record names.
        Mock -ModuleName Greenroom Get-CascadiaWindow {
            @([PSCustomObject]@{ Handle = [IntPtr]::new(4242); Title = 'probe' })
        }
    }

    AfterEach {
        if (Test-Path $script:RecordPath) { Remove-Item $script:RecordPath -Force }
    }

    It 'returns the handle when the record matches the live session' {
        WriteRecord @{ handle = 4242; claudePid = 1001; terminalPid = 2001 }
        Invoke-Resolve | Should -Be ([IntPtr]::new(4242))
    }

    It 'returns nothing when no record exists' {
        Invoke-Resolve | Should -BeNullOrEmpty
    }

    It 'returns nothing when the record is for a different claude pid' {
        # A record left by an earlier session of the same instance.
        WriteRecord @{ handle = 4242; claudePid = 999; terminalPid = 2001 }
        Invoke-Resolve | Should -BeNullOrEmpty
    }

    It 'returns nothing when the record is for a different terminal pid' {
        WriteRecord @{ handle = 4242; claudePid = 1001; terminalPid = 999 }
        Invoke-Resolve | Should -BeNullOrEmpty
    }

    It 'returns nothing when the recorded handle is not a live window' {
        # Handle reuse: the number is plausible, the window is gone.
        WriteRecord @{ handle = 9999; claudePid = 1001; terminalPid = 2001 }
        Invoke-Resolve | Should -BeNullOrEmpty
    }

    It 'returns nothing when the record is malformed' {
        '{ not json' | Set-Content $script:RecordPath
        Invoke-Resolve | Should -BeNullOrEmpty
    }

    It 'returns nothing when the record is empty' {
        # Regression: an empty file parses to $null WITHOUT throwing, so it used to fall
        # through and report a pid mismatch against blank values.
        '' | Set-Content $script:RecordPath
        Invoke-Resolve | Should -BeNullOrEmpty
    }

    It 'never guesses from the window title' {
        # There is deliberately no title fallback. A single live window whose title
        # matches the instance must still not resolve without a valid record.
        Mock -ModuleName Greenroom Get-CascadiaWindow {
            @([PSCustomObject]@{ Handle = [IntPtr]::new(4242); Title = '* probe' })
        }
        Invoke-Resolve | Should -BeNullOrEmpty
    }

    It 'explains the reason on the Verbose stream rather than the host' {
        WriteRecord @{ handle = 4242; claudePid = 999; terminalPid = 2001 }
        $v = InModuleScope Greenroom {
            Resolve-SessionWindow -HostPid 2001 -ClaudePid 1001 -Name 'probe' -Verbose 4>&1 |
                Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }
        }
        $v.Count | Should -BeGreaterThan 0
        ($v.Message -join ' ') | Should -Match 'claude pid 999'
    }
}
