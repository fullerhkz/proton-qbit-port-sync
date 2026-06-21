Option Explicit

Dim shell, fileSystem, scriptDirectory, powerShellPath, syncScriptPath
Dim command, exitCode, quote

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

quote = Chr(34)
scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
powerShellPath = fileSystem.BuildPath(shell.ExpandEnvironmentStrings("%SystemRoot%"), "System32\WindowsPowerShell\v1.0\powershell.exe")
syncScriptPath = fileSystem.BuildPath(scriptDirectory, "proton-qbit-port-sync.ps1")

command = quote & powerShellPath & quote & _
    " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & _
    quote & syncScriptPath & quote

exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode
