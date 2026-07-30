# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

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
    },
"@
        $raw = $raw.Substring(0, $insertAt) + $entry + $raw.Substring($insertAt)
        $seeded = $true
    }

    if (-not $seeded) {
        Write-Verbose 'trust already present for both path forms'
        return $true
    }

    # -AsHashtable because this file can carry keys differing only in case, which the
    # object parser refuses. The question is whether the result is well-formed JSON.
    try { $null = $raw | ConvertFrom-Json -AsHashtable }
    catch {
        Write-Warning "refusing to write ~/.claude.json, the result was invalid JSON: $($_.Exception.Message)"
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

    try { $j = Get-Content $file -Raw | ConvertFrom-Json -AsHashtable } catch { return $false }
    if (-not $j.projects) { return $false }

    foreach ($f in (@($Directory.Replace('/', '\'), $Directory.Replace('\', '/')) | Select-Object -Unique)) {
        if (-not $j.projects.ContainsKey($f)) { return $false }
        if (-not $j.projects[$f]['hasTrustDialogAccepted']) { return $false }
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
