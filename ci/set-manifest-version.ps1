# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Write the version AND that version's release notes into the manifest, as a cog
  pre-bump hook.

  WHY THE NOTES LIVE IN THE MANIFEST. PrivateData.PSData.ReleaseNotes is what the
  PowerShell Gallery renders on a version's page, and it is the only thing a person
  browsing the gallery can read to decide whether to upgrade. A module that ships it empty
  -- or points at a changelog somewhere else -- is the package equivalent of an app store
  entry that says "bug fixes and improvements", and that is a failure of tooling rather
  than a fact about the release. Every version this repository publishes carries its own
  changes.

  A published version is PERMANENT: the gallery allows unlisting, not deleting. So the
  notes have to be right on the way out, not fixable afterwards.

  ORDER. cog runs pre-bump hooks BEFORE it writes the changelog, commits or tags, so the
  new tag does not exist yet and `git describe` still names the PREVIOUS release. That is
  exactly the range we want: previous tag..HEAD.

  Both values go in ONE Update-ModuleManifest call, which is PowerShell's own writer for
  the manifest -- nothing here hand-edits a psd1.

  Verified before adopting it: multi-line notes containing apostrophes, asterisks, parens
  and `#` round-trip through Update-ModuleManifest intact and leave the manifest valid.
  The only difference is line endings, which it normalises to CRLF.

  FAILS RATHER THAN SHIPPING EMPTY NOTES. A hook that throws aborts the bump before the
  commit and tag exist, which is the safe side of the point of no return.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$ManifestPath = './Greenroom/Greenroom.psd1'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command cog -ErrorAction SilentlyContinue)) {
    throw 'cog is not on PATH, so release notes cannot be generated. Refusing to bump.'
}

# No tag yet means a first release: take the whole history rather than an empty range.
$previous = git describe --tags --abbrev=0 2>$null
$range    = if ($LASTEXITCODE -eq 0 -and $previous) { "$previous..HEAD" } else { $null }

$raw = if ($range) { & cog changelog $range --template default } else { & cog changelog --template default }
if ($LASTEXITCODE -ne 0) { throw "cog changelog failed for range '$range'. Refusing to bump." }

# Drop cog's own heading -- it reads "## Unreleased (abc..def)", which is both wrong on a
# published version and redundant beside the version the gallery already shows.
#
# Then drop the version-bump commit. It is the release's own bookkeeping ("- (**version**)
# v0.2.0"), it is never what a reader wants to know, and dropping it is what makes the
# emptiness check below mean something.
$lines = @($raw) -split "`r?`n"
if ($lines.Count -and $lines[0] -match '^##\s') { $lines = $lines[1..($lines.Count - 1)] }
$lines = $lines | Where-Object { $_ -notmatch '^\-\s+\(\*\*version\*\*\)' }

# MEASURED, and the reason this check is not a formality: for a degenerate range -- HEAD
# already at the previous tag -- cog does not emit nothing. It emits the PREVIOUS release's
# section, chore commit and all, so a naive "is it empty" test passes and the manifest ends
# up describing a release that already shipped. Require an actual entry instead.
$entries = @($lines | Where-Object { $_ -match '^\-\s+\S' })
if ($entries.Count -eq 0) {
    throw ("no release notes could be generated for '$range' -- nothing but bookkeeping since " +
           "$previous. Refusing to bump: a version published with empty or stale notes cannot be " +
           'fixed afterwards, because the gallery allows unlisting but not deleting.')
}

# Drop any section heading left with no entries under it after that filtering.
$kept = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^####\s') {
        $next = @($lines[($i + 1)..($lines.Count - 1)] | Where-Object { $_ -match '^\S' } | Select-Object -First 1)
        if (-not $next -or $next[0] -notmatch '^\-\s') { continue }
    }
    $kept += $lines[$i]
}
$notes = ($kept -join "`n").Trim()

$notes = $notes + "`n`nFull changelog: https://github.com/Vigario-Technology-Solutions/greenroom-win/releases/tag/v$Version"

Update-ModuleManifest -Path $ManifestPath -ModuleVersion $Version -ReleaseNotes $notes

# Write-Output rather than Write-Host: this is a hook run as `pwsh -File`, nothing consumes
# its pipeline, and the one Write-Host exemption in this repository is deliberately scoped
# to ci/check.ps1, which needs colour for a console reporter. This just needs a log line.
Write-Output "manifest: $Version, $((($notes -split "`n") | Measure-Object).Count) lines of release notes"
