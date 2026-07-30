# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Tyler Vigario

<#
  The P/Invoke surface for window discovery and visibility.

  The type name carries a revision suffix on purpose. A long-lived shell that has
  already imported an older Greenroom holds the previous type, and Add-Type cannot
  redefine a type in a live session -- so a fixed name plus a "load once" guard
  silently binds to the stale definition and fails on any member added since. Bump
  the suffix whenever the member list changes.

  Being inside a module does not change that: Remove-Module unloads PowerShell
  functions, not a loaded .NET assembly.
#>

if (-not ('Greenroom.Win1' -as [type])) {
    Add-Type -Namespace Greenroom -Name Win1 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
'@
}

# Module-scoped rather than global. In bin/greenroom.ps1 these were script-scoped in
# a script that was the whole world; here the module scope is a real boundary, so
# they cannot collide with a caller's variables.
$script:SW_HIDE    = 0
$script:SW_RESTORE = 9

# Where an instance keeps its config, window record and logs.
function Get-GreenroomStateRoot {
    Join-Path $env:USERPROFILE '.claude\greenroom'
}
