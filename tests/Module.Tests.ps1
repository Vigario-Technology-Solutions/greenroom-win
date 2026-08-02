# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Structural tests: the manifest is valid, the public surface is exactly the Public
  folder, and nothing private leaks.

  Worth testing rather than assuming, because both halves have already broken here:
  Export-ModuleMember was called with an array on [IO.Path]::GetFileNameWithoutExtension,
  which takes a single string, and silently exported one function out of four.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
    $script:Manifest   = Join-Path $ModuleRoot 'Greenroom\Greenroom.psd1'
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module $Manifest -Force
}

AfterAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
}

Describe 'Greenroom manifest' {

    It 'is a valid module manifest' {
        { Test-ModuleManifest -Path $Manifest -ErrorAction Stop } | Should -Not -Throw
    }

    It 'declares a version' {
        (Test-ModuleManifest -Path $Manifest).Version | Should -Not -BeNullOrEmpty
    }

    It 'declares a Windows PowerShell 5.1 floor and both editions' {
        # 5.1 is the floor: it ships in-box on every Windows host, and the module runs on
        # both editions. The one edition-divergent piece -- parsing ~/.claude.json, which
        # can hold keys differing only in drive-letter case -- is handled by helpers that
        # pick JavaScriptSerializer on 5.1 and System.Text.Json / -AsHashtable on 7.
        $m = Test-ModuleManifest -Path $Manifest
        $m.PowerShellVersion    | Should -Be ([version]'5.1')
        $m.CompatiblePSEditions | Should -Contain 'Desktop'
        $m.CompatiblePSEditions | Should -Contain 'Core'
    }

    It 'does not export functions with a wildcard' {
        # A wildcard defeats command discovery: PowerShell then has to import the whole
        # module to find out what it offers.
        $raw = Get-Content $Manifest -Raw
        $raw | Should -Not -Match "FunctionsToExport\s*=\s*'\*'"
        $raw | Should -Not -Match "FunctionsToExport\s*=\s*@\(\s*'\*'\s*\)"
    }
}

Describe 'Public surface' {

    It 'exports exactly one function per file in Public/' {
        $expected = Get-ChildItem (Join-Path $ModuleRoot 'Greenroom\Public') -Filter '*.ps1' |
                    ForEach-Object { $_.BaseName } | Sort-Object
        $actual = (Get-Command -Module Greenroom).Name | Sort-Object
        $actual | Should -Be $expected
    }

    It 'exports every function named in the manifest' {
        $declared = (Test-ModuleManifest -Path $Manifest).ExportedFunctions.Keys | Sort-Object
        (Get-Command -Module Greenroom).Name | Sort-Object | Should -Be $declared
    }

    It 'uses an approved verb for every exported function' {
        $approved = (Get-Verb).Verb
        foreach ($cmd in Get-Command -Module Greenroom) {
            $cmd.Name.Split('-')[0] | Should -BeIn $approved -Because "$($cmd.Name) must use an approved verb"
        }
    }

    It 'names every exported function with the Greenroom noun prefix' {
        foreach ($cmd in Get-Command -Module Greenroom) {
            $cmd.Name | Should -Match '^\w+-Greenroom' -Because 'a shared noun prefix is what keeps the module discoverable'
        }
    }

    It 'does not leak private helpers into the session' {
        foreach ($fn in 'Get-SessionProcess', 'Resolve-SessionWindow', 'Resolve-GreenroomTarget',
                        'Set-WindowVisible', 'Stop-VerifiedProcess', 'Test-SelfElevated',
                        'Get-CascadiaWindow', 'Assert-CanActOnInstance', 'Invoke-ElevatedSelf') {
            Get-Command $fn -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because "$fn is private"
        }
    }
}

Describe 'State-changing commands' {

    BeforeAll {
        # Derived, not hardcoded: a command added later is covered automatically instead
        # of being silently omitted from a list nobody remembered to update. Everything
        # that is not a Get- changes state in this module.
        $script:StateChanging = (Get-Command -Module Greenroom | Where-Object { $_.Name -notlike 'Get-*' }).Name
    }

    It 'has at least one state-changing command to check' {
        # Guards the derivation itself: a filter that matched nothing would make every
        # test below pass vacuously.
        $script:StateChanging.Count | Should -BeGreaterThan 0
    }

    It 'supports ShouldProcess so -WhatIf and -Confirm work' {
        foreach ($name in $script:StateChanging) {
            (Get-Command $name).Parameters.Keys | Should -Contain 'WhatIf' -Because "$name changes state"
            (Get-Command $name).Parameters.Keys | Should -Contain 'Confirm'
        }
    }

    It 'accepts pipeline input on Name, including Greenroom.Instance objects' {
        foreach ($name in $script:StateChanging) {
            $p = (Get-Command $name).Parameters['Name']
            $attr = $p.Attributes | Where-Object { $_ -is [Parameter] }
            ($attr.ValueFromPipeline -contains $true) | Should -BeTrue -Because "$name should accept a name from the pipeline"
            # Get-GreenroomInstance emits .Instance, so the alias is what makes
            # `Get-GreenroomInstance | Show-GreenroomSession` bind.
            $p.Aliases | Should -Contain 'Instance'
        }
    }
}

Describe 'Format view' {

    It 'ships a format file that loads' {
        # A malformed .ps1xml is a silent-failure surface: the module imports fine and
        # the view simply does not exist. This one has already failed once, because an
        # XML comment may not contain two consecutive hyphens.
        $fmt = Join-Path $ModuleRoot 'Greenroom\Greenroom.format.ps1xml'
        Test-Path $fmt | Should -BeTrue
        { [xml](Get-Content $fmt -Raw) } | Should -Not -Throw
    }

    It 'defines a view for the type Get-GreenroomInstance emits' {
        $fmt = [xml](Get-Content (Join-Path $ModuleRoot 'Greenroom\Greenroom.format.ps1xml') -Raw)
        $fmt.Configuration.ViewDefinitions.View.ViewSelectedBy.TypeName | Should -Contain 'Greenroom.Instance'
    }
}
