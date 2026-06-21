<#
.SYNOPSIS
  Cria ou atualiza a tarefa agendada da sincronizacao Proton/qBittorrent.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$TaskName = "proton-qbit-port-sync",
    [string]$ScriptPath = "",
    [string]$LauncherPath = "",
    [ValidateRange(1, 60)]
    [int]$IntervalMinutes = 2,
    [ValidateRange(0, 3600)]
    [int]$LogonDelaySeconds = 60
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if (-not $ScriptPath) {
    $ScriptPath = Join-Path $PSScriptRoot "proton-qbit-port-sync.ps1"
}
if (-not $LauncherPath) {
    $LauncherPath = Join-Path $PSScriptRoot "proton-qbit-port-sync.vbs"
}
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    throw "Sync script not found: $ScriptPath"
}
if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
    throw "Hidden launcher not found: $LauncherPath"
}

$resolvedScript = (Resolve-Path -LiteralPath $ScriptPath).Path
$resolvedLauncher = (Resolve-Path -LiteralPath $LauncherPath).Path
$workingDirectory = Split-Path -Path $resolvedScript -Parent
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$userId = $currentIdentity.Name
$wscriptPath = Join-Path $env:SystemRoot "System32\wscript.exe"
$arguments = '//B //NoLogo "{0}"' -f $resolvedLauncher

$action = New-ScheduledTaskAction `
    -Execute $wscriptPath `
    -Argument $arguments `
    -WorkingDirectory $workingDirectory

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$logonTrigger.Delay = [Xml.XmlConvert]::ToString([TimeSpan]::FromSeconds($LogonDelaySeconds))
$periodicTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes($IntervalMinutes) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$principal = New-ScheduledTaskPrincipal `
    -UserId $userId `
    -LogonType Interactive `
    -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

$task = New-ScheduledTask `
    -Action $action `
    -Trigger @($logonTrigger, $periodicTrigger) `
    -Principal $principal `
    -Settings $settings `
    -Description "Sync qBittorrent listening port with the active Proton VPN forwarded port."

if ($PSCmdlet.ShouldProcess($TaskName, "Create or update scheduled task for $userId")) {
    Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
    Write-Output "Scheduled task '$TaskName' registered for $userId."
}
