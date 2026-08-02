# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Trust seeding writes ~/.claude.json, which belongs to Claude Code rather than to
  greenroom. Getting it wrong does not degrade greenroom -- it breaks the other
  application, so these tests are about not damaging somebody else's file.

  The empty-projects case is a regression. Inserting after the `{` of `"projects": {}`
  produced a trailing comma, and the guard did not catch it because ConvertFrom-Json
  ACCEPTS trailing commas while Node -- the parser that actually reads the file --
  rejects them. The result would have been a valid-looking write that Claude Code could
  not open.
#>

BeforeAll {
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Greenroom\Greenroom.psd1') -Force

    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) "greenroom-trust-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null

    # Node's strictness is the bar, so assert against a parser that shares it -- and one
    # that EXISTS on the running edition. System.Text.Json is .NET Core only; on Windows
    # PowerShell 5.1 its absence would fail these tests for the wrong reason, so 5.1 uses
    # JavaScriptSerializer, which rejects trailing commas just as strictly. (ConvertFrom-Json
    # is not usable either way -- it ACCEPTS the trailing comma Node rejects.)
    function BeStrictlyValidJson {
        param([string]$Text)
        try {
            if ($PSVersionTable.PSEdition -eq 'Desktop') {
                Add-Type -AssemblyName System.Web.Extensions
                $null = (New-Object System.Web.Script.Serialization.JavaScriptSerializer).DeserializeObject($Text)
            }
            else {
                [System.Text.Json.JsonDocument]::Parse($Text).Dispose()
            }
            return $true
        }
        catch { return $false }
    }

    function Seed {
        param([string]$Existing, [string]$Directory = 'C:\probe-wd')
        $home2 = Join-Path $script:Sandbox ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $home2 -Force | Out-Null
        Set-Content (Join-Path $home2 '.claude.json') -Value $Existing -NoNewline
        $backup = Join-Path $home2 'backup'
        InModuleScope Greenroom -Parameters @{ h = $home2; d = $Directory; b = $backup } {
            param($h, $d, $b)
            $env:USERPROFILE = $h
            Set-ProjectTrust -Directory $d -BackupDir $b | Out-Null
        }
        Get-Content (Join-Path $home2 '.claude.json') -Raw
    }

    function Survived {
        param([string]$Existing, [string]$Directory = 'C:\probe-wd')
        $home2 = Join-Path $script:Sandbox ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $home2 -Force | Out-Null
        Set-Content (Join-Path $home2 '.claude.json') -Value $Existing -NoNewline
        InModuleScope Greenroom -Parameters @{ h = $home2; d = $Directory } {
            param($h, $d)
            $env:USERPROFILE = $h
            Test-TrustSurvived -Directory $d 3>$null   # 3>$null: swallow the parse Warning, assert the return
        }
    }
}

AfterAll {
    if (Test-Path $script:Sandbox) { Remove-Item $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Module Greenroom -Force -ErrorAction SilentlyContinue
}

Describe 'Set-ProjectTrust' {

    BeforeEach { $script:RealProfile = $env:USERPROFILE }
    AfterEach  { $env:USERPROFILE = $script:RealProfile }

    It 'produces strictly valid JSON when projects is EMPTY' {
        # The regression. A trailing comma here is invisible to ConvertFrom-Json and
        # fatal to Node.
        $out = Seed -Existing '{ "projects": {} }'
        BeStrictlyValidJson $out | Should -BeTrue -Because 'Node rejects trailing commas'
        $out | Should -Not -Match ',\s*\}'
    }

    It 'produces strictly valid JSON when projects already has entries' {
        $out = Seed -Existing '{ "projects": { "C:\\other": { "hasTrustDialogAccepted": true } } }'
        BeStrictlyValidJson $out | Should -BeTrue
    }

    It 'seeds BOTH path forms, because trust is keyed on the literal string' {
        # 'C:\x' and 'C:/x' are separate entries with independent trust; seeding one and
        # starting with the other re-prompts forever.
        $out = Seed -Existing '{ "projects": {} }'
        $out | Should -Match 'C:\\\\probe-wd'
        $out | Should -Match 'C:/probe-wd'
    }

    It 'marks trust accepted' {
        $out = Seed -Existing '{ "projects": {} }'
        ($out | ConvertFrom-Json).projects.'C:\probe-wd'.hasTrustDialogAccepted | Should -BeTrue
    }

    It 'preserves keys it did not put there' {
        $out = Seed -Existing '{ "numStartups": 42, "projects": {} }'
        ($out | ConvertFrom-Json).numStartups | Should -Be 42
    }

    It 'is idempotent -- seeding twice does not duplicate or corrupt' {
        $first  = Seed -Existing '{ "projects": {} }'
        # Feeding the result back in is what a re-run does.
        $second = Seed -Existing $first
        BeStrictlyValidJson $second | Should -BeTrue
        ([regex]::Matches($second, 'hasTrustDialogAccepted')).Count | Should -Be 2
    }

    It 'refuses rather than writing when there is no projects block' {
        $out = Seed -Existing '{ "somethingElse": 1 }'
        $out | Should -Be '{ "somethingElse": 1 }'
    }
}

Describe 'Test-TrustSurvived' {

    BeforeEach { $script:RealProfile = $env:USERPROFILE }
    AfterEach  { $env:USERPROFILE = $script:RealProfile }

    It 'is true when both path forms are trusted' {
        Survived -Existing '{ "projects": { "C:\\probe-wd": { "hasTrustDialogAccepted": true }, "C:/probe-wd": { "hasTrustDialogAccepted": true } } }' |
            Should -BeTrue
    }

    It 'is false when the directory is absent' {
        Survived -Existing '{ "projects": { "C:\\other": { "hasTrustDialogAccepted": true } } }' | Should -BeFalse
    }

    It 'never throws -- returns false on malformed JSON' {
        # A boolean predicate that Install calls without a catch: throwing would abort the
        # install rather than let it re-seed.
        Survived -Existing '{ "projects": { oops' | Should -BeFalse
    }

    It 'returns false on a non-object project entry rather than throwing' {
        Survived -Existing '{ "projects": { "C:\\probe-wd": "nope", "C:/probe-wd": "nope" } }' | Should -BeFalse
    }
}
