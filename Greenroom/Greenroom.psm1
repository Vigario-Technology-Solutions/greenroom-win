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

# Where this module lives. Needed by the elevation re-launch, which must import the
# module in a NEW elevated process: a script could re-invoke $PSCommandPath, but a
# module has no single file to run, and resolving by name would depend on
# PSModulePath being identical under elevation. An explicit path does not.
$script:GreenroomModuleRoot = $PSScriptRoot

# Read from the manifest rather than inferred from the directory name. The manifest is the
# only version slot in this repository (see cog.toml), and a module copied onto the module
# path by hand may sit in a directory that is not named for a version at all.
$script:GreenroomModuleVersion = [version](Import-PowerShellDataFile (Join-Path $PSScriptRoot 'Greenroom.psd1')).ModuleVersion

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
# One name per Public file. GetFileNameWithoutExtension takes a single string, so
# calling it on the array exported exactly one function and silently hid the rest --
# which is how Show-GreenroomSession briefly became the entire public surface.
Export-ModuleMember -Function @($public | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_) })
