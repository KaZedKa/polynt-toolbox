Option Explicit
Dim shell, fso, root, scriptPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(root, "tools\PolyntToolbox.ps1")
command = "powershell.exe -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptPath & """"
shell.Run command, 0, False
