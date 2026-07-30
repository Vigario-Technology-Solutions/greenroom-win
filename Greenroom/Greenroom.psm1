# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  Root module. Loads Private/ then Public/ and exports only Public/.
  See Greenroom.psd1 for the manifest -- ModuleVersion lives there and nowhere else.

  The Private/Public split IS the API boundary. Everything in Private is reachable
  from inside the module and invisible outside it, which is the thing a collection
  of loose scripts cannot express: in bin/greenroom.ps1 every helper is exactly as
  reachable, and as undocumented, as the commands an operator is meant to call.

  Dot-sourced in two passes rather than one, because a Public function may call a
  Private one at load time and the reverse never happens.
#>

$ErrorActionPreference = 'Stop'

# Win32.ps1 first and by name: it defines the P/Invoke surface the window helpers
# bind against, so ordering here is load-bearing rather than alphabetical luck.
$private = @(Join-Path $PSScriptRoot 'Private\Win32.ps1')
$private += @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -File |
              Where-Object Name -ne 'Win32.ps1' | Select-Object -ExpandProperty FullName)

$public = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File |
            Select-Object -ExpandProperty FullName)

foreach ($file in @($private) + @($public)) {
    try { . $file }
    catch { throw "failed to load $($file): $($_.Exception.Message)" }
}

# Exported explicitly from the file names rather than a wildcard. FunctionsToExport
# in the manifest is the real gate -- a wildcard there defeats command discovery,
# because PowerShell must then import the whole module to find out what it offers.
Export-ModuleMember -Function ([IO.Path]::GetFileNameWithoutExtension($public))
