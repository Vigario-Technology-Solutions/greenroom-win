# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

# The two JSON stacks meet here, and nowhere else in the module. They are mutually
# exclusive across editions: JavaScriptSerializer is absent from .NET Core (pwsh 7), and
# -AsHashtable / System.Text.Json are absent from .NET Framework (Windows PowerShell 5.1).
# ~/.claude.json can carry keys differing only in drive-letter case, so the plain object
# parser (ConvertFrom-Json without -AsHashtable) is unusable on both. Every edition
# divergence in the module lives in these two helpers.

<#
  Is $Raw well-formed JSON, judged as strictly as the parser that actually reads the file?
  Both editions reject a trailing comma, which Node -- and so Claude Code -- reject.
#>
function Test-ClaudeJsonValid {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Raw)
    try {
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            Add-Type -AssemblyName System.Web.Extensions
            $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $js.MaxJsonLength = [int]::MaxValue
            $null = $js.DeserializeObject($Raw)
        }
        else {
            [System.Text.Json.JsonDocument]::Parse($Raw).Dispose()
        }
        $true
    }
    catch { $false }
}

<#
  Parse ~/.claude.json's "projects" object into an indexable map, or $null if absent.
  Case-sensitive, and the two slash forms read as distinct keys -- verified on both
  editions. Throws on malformed JSON, which the caller must not confuse with "trust absent".
#>
function Read-ClaudeProjectMap {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Raw)
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Add-Type -AssemblyName System.Web.Extensions
        $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $js.MaxJsonLength = [int]::MaxValue
        $o = $js.DeserializeObject($Raw)
        if ($o -and $o.ContainsKey('projects')) { return $o['projects'] }
        return $null
    }
    return ($Raw | ConvertFrom-Json -AsHashtable).projects
}

<#
  Seed Claude Code's trust for a working directory, so the session does not stop at a
  modal trust dialog inside a window nobody can see.

  Claude Code keys project state on the LITERAL cwd string, so 'C:\x' and 'C:/x' are
  separate entries with independent trust. Both forms are seeded; that mismatch is what
  made an earlier setup re-prompt on every start.

  TEXT SURGERY, NOT ROUND-TRIPPING, and deliberately. ~/.claude.json belongs to another
  application: it can contain keys differing only in drive-letter case, which the object
  parser rejects outright, and re-serialising it would reorder and reshape a file
  greenroom does not own. The insert is validated as JSON before anything is written,
  and the original is backed up first.

  This is the only file outside greenroom's own directories that installing writes.
#>
function Set-ProjectTrust {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BackupDir
    )

    $file = Join-Path $env:USERPROFILE '.claude.json'
    if (-not (Test-Path $file)) {
        Write-Warning 'no ~/.claude.json yet -- run `claude` once, then install again'
        return $false
    }

    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    $backup = Join-Path $BackupDir ('claude.json.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item $file $backup -Force

    $raw = Get-Content $file -Raw
    $m = [regex]::Match($raw, '"projects"\s*:\s*\{')
    if (-not $m.Success) {
        Write-Warning 'no "projects" block in ~/.claude.json -- skipping trust seed'
        return $false
    }
    $insertAt = $m.Index + $m.Length

    $targets = @($Directory.Replace('/', '\'), $Directory.Replace('\', '/')) | Select-Object -Unique
    $seeded = $false
    foreach ($t in $targets) {
        $jsonKey = $t.Replace('\', '\\')
        if ($raw -match [regex]::Escape('"' + $jsonKey + '"')) { continue }

        # An EMPTY projects object takes no trailing comma. Inserting one after the `{`
        # of `"projects": {}` produces `{ "x": {...},}`, which Node -- the parser that
        # actually reads this file -- rejects outright, taking Claude Code with it.
        #
        # Recomputed each pass, because after the first entry the object is no longer
        # empty and the second one does need its comma.
        $isEmpty = $raw.Substring($insertAt) -match '^\s*\}'
        $comma = if ($isEmpty) { '' } else { ',' }

        $entry = @"

    "$jsonKey": {
      "allowedTools": [],
      "mcpContextUris": [],
      "mcpServers": {},
      "enabledMcpjsonServers": [],
      "disabledMcpjsonServers": [],
      "hasTrustDialogAccepted": true,
      "projectOnboardingSeenCount": 0,
      "hasClaudeMdExternalIncludesApproved": false,
      "hasClaudeMdExternalIncludesWarningShown": false,
      "exampleFiles": []
    }$comma
"@
        $raw = $raw.Substring(0, $insertAt) + $entry + $raw.Substring($insertAt)
        $seeded = $true
    }

    if (-not $seeded) {
        Write-Verbose 'trust already present for both path forms'
        return $true
    }

    # VALIDATE WITH THE SAME STRICTNESS AS THE PARSER THAT READS THIS FILE. Node -- and so
    # Claude Code -- reject a trailing comma, which a bad insert could produce; Test-ClaudeJsonValid
    # rejects it too, on both editions. (Plain ConvertFrom-Json is not a safe guard: on pwsh 7
    # it ACCEPTS the trailing comma Node rejects, and on 5.1 it dies on the drive-letter-case
    # keys this file can carry. The edition-aware helper is strict and case-tolerant on both.)
    if (-not (Test-ClaudeJsonValid $raw)) {
        Write-Warning 'refusing to write ~/.claude.json -- the seeded result was not valid JSON'
        return $false
    }

    Set-Content -Path $file -Value $raw -Encoding UTF8 -NoNewline
    Write-Verbose "trust seeded (backup at $backup)"
    return $true
}

<#
  Whether trust for a directory is present RIGHT NOW, in both path forms.

  Worth re-checking after launch rather than assuming: on any host with Claude Desktop
  there are always other claude.exe processes, and any of them can rewrite
  ~/.claude.json between the seed and the launch. The consequence is a modal dialog in
  a window nobody can see, which reads as "it hangs for no reason".
#>
function Test-TrustSurvived {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Directory)

    $file = Join-Path $env:USERPROFILE '.claude.json'
    if (-not (Test-Path $file)) { return $false }

    # A READ failure is environmental -- treat as not-survived and let the caller re-seed.
    # A PARSE failure is different: a malformed ~/.claude.json is a real anomaly, so
    # Read-ClaudeProjectMap is allowed to throw rather than be swallowed as "not trusted".
    # The old blanket `catch { return $false }` did exactly that -- and on 5.1 it swallowed
    # the -AsHashtable parameter-binding error, reported a healthy file as untrusted, and
    # drove a spurious re-seed and session restart on every install.
    $raw = try { Get-Content $file -Raw -ErrorAction Stop } catch { return $false }
    $projects = Read-ClaudeProjectMap $raw
    if (-not $projects) { return $false }

    foreach ($f in (@($Directory.Replace('/', '\'), $Directory.Replace('\', '/')) | Select-Object -Unique)) {
        if (-not $projects.ContainsKey($f)) { return $false }
        if (-not $projects[$f]['hasTrustDialogAccepted']) { return $false }
    }
    return $true
}

<#
  Mirror an instance's directory grants into its PROJECT settings, so a session started
  by hand in that directory gets the same scope as the supervised one.

  Merged, never clobbered: the file may hold settings that are nothing to do with us.
#>
function Set-ProjectGrant {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string[]]$Grants = @()
    )

    $dir  = Join-Path $Directory '.claude'
    $file = Join-Path $dir 'settings.json'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $obj = $null
    if (Test-Path $file) {
        try { $obj = Get-Content $file -Raw | ConvertFrom-Json }
        catch { Write-Warning "$file exists but is not valid JSON -- leaving it untouched"; return }
    }
    if (-not $obj) { $obj = [PSCustomObject]@{} }

    if (-not $obj.PSObject.Properties['permissions']) {
        $obj | Add-Member -NotePropertyName permissions -NotePropertyValue ([PSCustomObject]@{})
    }
    if ($obj.permissions.PSObject.Properties['additionalDirectories']) {
        $obj.permissions.additionalDirectories = @($Grants)
    }
    else {
        $obj.permissions | Add-Member -NotePropertyName additionalDirectories -NotePropertyValue @($Grants)
    }

    $obj | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding UTF8
    Write-Verbose "project settings: $file"
}
