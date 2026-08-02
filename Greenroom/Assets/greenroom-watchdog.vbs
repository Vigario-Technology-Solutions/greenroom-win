' SPDX-License-Identifier: AGPL-3.0-or-later
' Copyright (C) 2026 Tyler Vigario

' Scheduled-task entry point for a greenroom instance.
'
' Usage:  wscript.exe greenroom-watchdog.vbs <instance-name>
'
' WHY VBS AT ALL: wscript.exe is a GUI-subsystem binary, so it allocates no
' console of its own, and Run(cmd, 0, False) passes STARTF_USESHOWWINDOW with
' SW_HIDE at PROCESS CREATION time. That is the whole point. Hiding a console
' from inside the process is too late -- the OS creates the window visible and
' pwsh needs ~370ms to boot before any of our code can run. That was measured
' as a 367ms flash of a visible terminal at every logon.
'
' This starts the WATCHDOG, not the session. The watchdog owns launching and
' restarting the session, so closing the session window never stops supervision.

Option Explicit

Dim sh, fso, args, instance, here, shell, script, cmd

Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
Set args = WScript.Arguments

If args.Count < 1 Then
    ' No MsgBox -- this runs hidden at logon and a modal box would hang the task.
    WScript.Quit 2
End If
instance = args(0)

' Resolve the watchdog next to THIS script, so greenroom works from any install path.
here   = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(here, "greenroom-watchdog.ps1")

If Not fso.FileExists(script) Then WScript.Quit 3

' Resolve the shell to launch the watchdog with. Prefer pwsh 7 -- the WindowsApps alias
' is version-independent, then the real install path -- and fall back to the Windows
' PowerShell 5.1 that ships in-box on every Windows host, so a machine with no pwsh 7
' installed still starts. greenroom's code runs on both editions.
shell = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Microsoft\WindowsApps\pwsh.exe"
If Not fso.FileExists(shell) Then
    shell = sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
End If
If Not fso.FileExists(shell) Then
    shell = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
End If
If Not fso.FileExists(shell) Then WScript.Quit 4

sh.CurrentDirectory = sh.ExpandEnvironmentStrings("%USERPROFILE%")

cmd = """" & shell & """ -NoLogo -NoProfile -ExecutionPolicy Bypass -File """ & _
      script & """ -Instance """ & instance & """"

' 0 = SW_HIDE at creation, False = do not wait
sh.Run cmd, 0, False
