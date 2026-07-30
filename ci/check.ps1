# The gate, in one place.
#
# Invoked by `just check` and by .github/workflows/ci.yml, which runs the same
# `just check` -- so a green local run and a green pull request mean the same thing.
# Anything CI enforces that is not reachable from here would make the pull request the
# only place a failure can be found.
#
# Also runnable directly (`pwsh ./ci/check.ps1`), so a host with neither just nor a
# network can still verify the tree.

# Write-Host is correct HERE and nowhere else in this repository. This script is a
# console reporter for a human running a check: its output is the product, it is never
# consumed by another command, and colour is how a failing phase is picked out of a
# wall of passes. The module itself uses the proper streams, which is why that rule is
# not excluded globally -- suppressing it at this one file keeps it live everywhere it
# should be.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    [ValidateSet('manifest', 'parse', 'json', 'analyze', 'test')]
    [string]$Phase
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

$failed = @()
function Announce([string]$n) { Write-Host "== $n" -ForegroundColor Cyan }
function Passed([string]$n)   { Write-Host "   $n OK" -ForegroundColor Green }
function Failed([string]$n)   { Write-Host "   $n FAILED" -ForegroundColor Red; $script:failed += $n }

# The manifest is the module's contract: it declares the version, the exported surface
# and the format file. A manifest that does not load takes the whole module with it,
# and Test-ModuleManifest is the only thing that checks the declared exports actually
# resolve.
function Test-Manifest {
    Announce 'manifest'
    try {
        $m = Test-ModuleManifest ./Greenroom/Greenroom.psd1 -ErrorAction Stop
        Passed "manifest (v$($m.Version), $($m.ExportedFunctions.Count) exports)"
    }
    catch { Write-Host "   $($_.Exception.Message)" -ForegroundColor Red; Failed 'manifest' }
}

# Every PowerShell file must parse. The cheapest possible check, and it catches the
# failure that matters most in a repository of scripts: a syntax error commits cleanly
# and only surfaces when the watchdog next tries to launch a session, on a host nobody
# is watching.
#
# The .ps1xml is parsed as XML for the same reason: a malformed format file is a SILENT
# failure surface -- the module imports fine and the view simply does not exist. That
# has already happened here, because an XML comment may not contain two hyphens.
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
    foreach ($f in Get-ChildItem -Recurse -Include *.ps1xml -File) {
        try { [xml](Get-Content $f.FullName -Raw) | Out-Null }
        catch { $bad++; Write-Host "   $(Resolve-Path -Relative $f.FullName): $($_.Exception.Message)" -ForegroundColor Red }
    }
    if ($bad) { Failed "parse ($bad file(s))" } else { Passed 'parse' }
}

# Every JSON file must parse. The branch-protection payload lives in .github/rulesets
# and is applied FROM THE TREE, so a malformed one is a protection change that fails at
# apply time instead of at review time -- and protection that silently failed to apply
# is the worst kind, because nothing in a clone reveals it is gone.
#
# System.Text.Json rather than ConvertFrom-Json, which ACCEPTS A TRAILING COMMA. Nothing
# that consumes these files does: GitHub rejects the ruleset payload, and Node rejects
# ~/.claude.json, which is why Set-ProjectTrust already validates with this parser after
# writing. A gate whose parser is more permissive than every consumer can only certify
# files that then fail somewhere it cannot see.
#
# It also happens to be the right tool for the reason -AsHashtable was originally used:
# a settings-shaped file can carry keys differing only in case, which the object parser
# rejects outright. JsonDocument is a reader over the text rather than a map, so it takes
# them without complaint while staying strict about the syntax that actually matters.
function Test-JsonFile {
    Announce 'json'
    $bad = 0
    $files = Get-ChildItem -Recurse -Include *.json -File
    foreach ($f in $files) {
        try { [System.Text.Json.JsonDocument]::Parse((Get-Content $f.FullName -Raw)).Dispose() }
        catch {
            $bad++
            Write-Host "   $(Resolve-Path -Relative $f.FullName): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    if ($bad) { Failed "json ($bad file(s))" } else { Passed "json ($($files.Count) file(s))" }
}

# Static analysis with DEFAULT rules and no settings file. Where a rule genuinely does
# not apply it is suppressed at the function with the reason, so a real finding
# elsewhere still fails. A settings file that silences whatever happens to be red
# teaches nothing and cannot distinguish a deliberate exemption from an unexamined one.
# Refuses rather than installing. A check that reaches for the network to fix its own
# prerequisites is doing two jobs, and it does the second one invisibly: it mutates the
# machine of whoever ran it, and it silently upgrades the rule set the gate enforces, so
# a green tree can turn red with no commit in between. Provisioning belongs to whoever
# owns the machine -- CI does it in a named step, a person does it once.
function Assert-CheckModule {
    param([string]$Name, [version]$Minimum, [string]$Install)
    $have = Get-Module -ListAvailable $Name | Where-Object Version -ge $Minimum
    if ($have) { return }
    Write-Host "   $Name $Minimum or newer is not installed" -ForegroundColor Red
    Write-Host "     $Install"
    Failed $Name
}

function Test-Analyze {
    Announce 'analyze'
    Assert-CheckModule PSScriptAnalyzer '1.21.0' 'Install-Module PSScriptAnalyzer -Scope CurrentUser'
    if ($script:failed -contains 'PSScriptAnalyzer') { return }
    Import-Module PSScriptAnalyzer
    $r = @(Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error, Warning)
    if ($r.Count) {
        $r | Sort-Object ScriptName, Line | ForEach-Object {
            Write-Host "   $($_.Severity)  $($_.RuleName)" -ForegroundColor Red
            Write-Host "     $(Resolve-Path -Relative $_.ScriptPath):$($_.Line)  $($_.Message)"
        }
        Failed "analyze ($($r.Count) finding(s))"
    }
    else { Passed 'analyze' }
}

function Test-Pester {
    Announce 'test'
    Assert-CheckModule Pester '5.0.0' 'Install-Module Pester -Scope CurrentUser -SkipPublisherCheck -MinimumVersion 5.0.0'
    if ($script:failed -contains 'Pester') { return }
    Import-Module Pester -MinimumVersion 5.0.0
    $cfg = New-PesterConfiguration
    $cfg.Run.Path = './tests'
    $cfg.Run.PassThru = $true
    $cfg.Output.Verbosity = 'None'
    $res = Invoke-Pester -Configuration $cfg
    if ($res.FailedCount) {
        $res.Failed | ForEach-Object {
            Write-Host "   $($_.ExpandedPath)" -ForegroundColor Red
            Write-Host "     $($_.ErrorRecord.Exception.Message)"
        }
        Failed "test ($($res.FailedCount) of $($res.TotalCount) failed)"
    }
    else { Passed "test ($($res.PassedCount)/$($res.TotalCount))" }
}

switch ($Phase) {
    'manifest' { Test-Manifest }
    'parse'    { Test-Parse }
    'json'     { Test-JsonFile }
    'analyze'  { Test-Analyze }
    'test'     { Test-Pester }
    # Ordered so the cheapest failure surfaces first.
    default    { Test-Manifest; Test-Parse; Test-JsonFile; Test-Analyze; Test-Pester }
}

if ($failed.Count) {
    Write-Host ''
    Write-Host "check FAILED: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host 'check OK' -ForegroundColor Green
