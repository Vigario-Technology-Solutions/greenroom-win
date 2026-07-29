# The gate, in one place.
#
# Invoked by `just check` and by .github/workflows/check.yml, which runs the same
# `just check`. Also runnable directly -- `pwsh ./ci/check.ps1` -- so a host with
# neither just nor a network can still verify the tree.
#
# Written as a single script rather than as `just` recipe bodies because just's
# shebang recipes need `cygpath` on Windows, and this repository's whole audience
# is Windows.

[CmdletBinding()]
param(
    # Run one phase instead of all of them.
    [ValidateSet('parse', 'analyze', 'json')]
    [string]$Phase
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

$failed = @()

function Announce([string]$name) { Write-Host "== $name" -ForegroundColor Cyan }
function Passed([string]$name)   { Write-Host "   $name OK" -ForegroundColor Green }
function Failed([string]$name)   { Write-Host "   $name FAILED" -ForegroundColor Red; $script:failed += $name }

# Every PowerShell file must parse. The cheapest possible check, and it catches
# the failure that matters most in a repository of scripts: a syntax error commits
# cleanly and only surfaces when the watchdog next tries to launch a session, on a
# host nobody is watching.
function Test-Parse {
    Announce 'parse'
    $bad = 0
    foreach ($f in Get-ChildItem -Recurse -Include *.ps1, *.psd1 -File) {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors) | Out-Null
        if ($errors) {
            $bad++
            Write-Host "   $(Resolve-Path -Relative $f.FullName)" -ForegroundColor Red
            $errors | ForEach-Object { Write-Host "     line $($_.Extent.StartLineNumber): $($_.Message)" }
        }
    }
    if ($bad) { Failed "parse ($bad file(s))" } else { Passed 'parse' }
}

# Static analysis. Rules that do not apply to an interactive CLI are excluded in
# PSScriptAnalyzerSettings.psd1, each with the reason it was excluded.
function Test-Analyze {
    Announce 'analyze'
    if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        Write-Host '   installing PSScriptAnalyzer' -ForegroundColor DarkGray
        Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module PSScriptAnalyzer
    $r = @(Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1)
    if ($r.Count) {
        $r | Sort-Object ScriptName, Line | ForEach-Object {
            Write-Host "   $($_.Severity)  $($_.RuleName)" -ForegroundColor Red
            Write-Host "     $(Resolve-Path -Relative $_.ScriptPath):$($_.Line)  $($_.Message)"
        }
        Failed "analyze ($($r.Count) finding(s))"
    }
    else { Passed 'analyze' }
}

# Every JSON file must parse. The branch-protection payload lives in
# .github/rulesets/ and is applied from the tree, so a malformed one is a
# protection change that fails at apply time instead of at review time.
#
# -AsHashtable because ~/.claude.json-shaped files can carry keys differing only
# in case, which the object parser rejects outright; the question here is whether
# the JSON is well formed, not whether it maps to an object.
function Test-JsonFiles {
    Announce 'json'
    $bad = 0
    $files = Get-ChildItem -Recurse -Include *.json -File |
             Where-Object { $_.FullName -notmatch '[\\/]node_modules[\\/]' -and $_.Name -ne 'package-lock.json' }
    foreach ($f in $files) {
        try { Get-Content $f.FullName -Raw | ConvertFrom-Json -AsHashtable | Out-Null }
        catch {
            $bad++
            Write-Host "   $(Resolve-Path -Relative $f.FullName): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    if ($bad) { Failed "json ($bad file(s))" } else { Passed "json ($($files.Count) file(s))" }
}

switch ($Phase) {
    'parse'   { Test-Parse }
    'analyze' { Test-Analyze }
    'json'    { Test-JsonFiles }
    default   { Test-Parse; Test-Analyze; Test-JsonFiles }
}

if ($failed.Count) {
    Write-Host ''
    Write-Host "check FAILED: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host 'check OK' -ForegroundColor Green
