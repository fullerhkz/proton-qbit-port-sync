<#
.SYNOPSIS
  Sincroniza a porta encaminhada do Proton VPN com o qBittorrent no Windows.
.DESCRIPTION
  Lê a porta de port forwarding nos logs do Proton VPN, atualiza Session\Port
  no qBittorrent.ini e reinicia o qBittorrent para aplicar a mudança.
.PARAMETER ProtonVpnLogDir
  Caminho dos logs do Proton VPN (padrao: %LOCALAPPDATA%\Proton\Proton VPN\Logs).
.PARAMETER QbitConfigPath
  Caminho do qBittorrent.ini (padrao: %APPDATA%\qBittorrent\qBittorrent.ini).
.PARAMETER QbitExePath
  Caminho do qbittorrent.exe (auto-detect se vazio).
.PARAMETER LogPath
  Caminho do arquivo de log (padrao: %ProgramData%\ProtonQbitPortSync\proton-qbit-port-sync.log).
.PARAMETER LogTailLines
  Quantidade de linhas finais lidas por log para achar a porta.
.PARAMETER SkipRestartIfSame
  Se informado, nao reinicia quando a porta ja estiver correta.
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\proton-qbit-port-sync\proton-qbit-port-sync.ps1"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ProtonVpnLogDir = (Join-Path $env:LOCALAPPDATA "Proton\Proton VPN\Logs"),
    [string]$QbitConfigPath = (Join-Path $env:APPDATA "qBittorrent\qBittorrent.ini"),
    [string]$QbitExePath = "",
    [string]$LogPath = (Join-Path $env:ProgramData "ProtonQbitPortSync\proton-qbit-port-sync.log"),
    [int]$LogTailLines = 2000,
    [switch]$SkipRestartIfSame
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function New-LogPath {
    param([string]$Path)
    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Add-Content -Path $LogPath -Value $line -Encoding utf8
    Write-Output $line
}

function Get-FileEncoding {
    param([byte[]]$Bytes)
    # Preserva o encoding do qBittorrent.ini ao escrever de volta.
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE -and $Bytes[2] -eq 0x00 -and $Bytes[3] -eq 0x00) {
        return [System.Text.UTF32Encoding]::new($false, $true)
    }
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0x00 -and $Bytes[1] -eq 0x00 -and $Bytes[2] -eq 0xFE -and $Bytes[3] -eq 0xFF) {
        return [System.Text.UTF32Encoding]::new($true, $true)
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [System.Text.UTF8Encoding]::new($true)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [System.Text.UnicodeEncoding]::new($false, $true)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [System.Text.UnicodeEncoding]::new($true, $true)
    }
    return [System.Text.Encoding]::Default
}

function Find-ProtonForwardedPort {
    param([string]$LogDir, [int]$TailLines)
    # Procura a ultima ocorrencia de "Port pair <port>->" nos logs.
    if (-not (Test-Path $LogDir)) {
        throw "Proton VPN log dir not found: $LogDir"
    }

    $logs = Get-ChildItem -Path $LogDir -Filter "*.txt" -File | Sort-Object LastWriteTime -Descending
    if (-not $logs) {
        throw "No Proton VPN log files found in: $LogDir"
    }

    foreach ($log in $logs) {
        $tail = Get-Content -Path $log.FullName -Tail $TailLines -ErrorAction Stop
        $text = $tail -join "`n"
        $portMatches = [regex]::Matches($text, "Port pair (\\d+)->")
        if ($portMatches.Count -gt 0) {
            $port = $portMatches[$portMatches.Count - 1].Groups[1].Value
            return [int]$port
        }
    }

    throw "No 'Port pair <port>->' entry found in Proton VPN logs. Is Port Forwarding enabled and connected?"
}

function Update-QbitConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$ConfigPath, [int]$Port)
    # Atualiza Session\Port mantendo encoding e quebra de linha do arquivo.

    if (-not (Test-Path $ConfigPath)) {
        throw "qBittorrent config not found: $ConfigPath"
    }

    $bytes = [System.IO.File]::ReadAllBytes($ConfigPath)
    $encoding = Get-FileEncoding -Bytes $bytes
    $text = $encoding.GetString($bytes)

    $newLine = "`n"
    if ($text -match "`r`n") { $newLine = "`r`n" }

    $portPattern = '(?m)^Session\\Port=(\\d+).*$'
    $match = [regex]::Match($text, $portPattern)

    $currentPort = $null
    if ($match.Success) {
        $currentPort = $match.Groups[1].Value
    }

    if ($currentPort -eq "$Port") {
        return [pscustomobject]@{
            Changed = $false
            OldPort = $currentPort
            NewPort = $Port
        }
    }

    $updatedText = $text
    if ($match.Success) {
        $updatedText = [regex]::Replace($text, $portPattern, "Session\\Port=$Port")
    }
    else {
        $updatedText = $text.TrimEnd() + $newLine + "Session\\Port=$Port" + $newLine
    }

    if ($PSCmdlet.ShouldProcess($ConfigPath, "Update Session\\Port to $Port")) {
        [System.IO.File]::WriteAllText($ConfigPath, $updatedText, $encoding)
    }

    return [pscustomobject]@{
        Changed = $true
        OldPort = $currentPort
        NewPort = $Port
    }
}

function Find-QbitExe {
    param([string]$OverridePath)
    # Resolve o caminho do qbittorrent.exe por prioridade.

    if ($OverridePath) {
        if (Test-Path $OverridePath) { return $OverridePath }
        throw "qBittorrent exe not found at: $OverridePath"
    }

    $candidates = @(
        "C:\\Program Files\\qBittorrent\\qbittorrent.exe",
        "C:\\Program Files (x86)\\qBittorrent\\qbittorrent.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }

    $cmd = Get-Command "qbittorrent.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $uninstallKeys = @(
        "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*",
        "HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*"
    )
    foreach ($key in $uninstallKeys) {
        $apps = Get-ItemProperty $key -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "qBittorrent*" }
        foreach ($app in $apps) {
            if ($app.DisplayIcon -and (Test-Path $app.DisplayIcon)) { return $app.DisplayIcon }
            if ($app.InstallLocation) {
                $exe = Join-Path $app.InstallLocation "qbittorrent.exe"
                if (Test-Path $exe) { return $exe }
            }
        }
    }

    throw "qBittorrent exe not found. Provide -QbitExePath explicitly."
}

function Restart-Qbit {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$ExePath)
    # Encerra e reinicia o qBittorrent para aplicar a nova porta.

    if ($PSCmdlet.ShouldProcess("qBittorrent", "Restart")) {
        $running = Get-Process -Name "qbittorrent" -ErrorAction SilentlyContinue
        if ($running) {
            Write-Log "Stopping qBittorrent..."
            $running | Stop-Process -Force
            Start-Sleep -Seconds 2
        }
        else {
            Write-Log "qBittorrent was not running."
        }

        if (-not (Test-Path $ExePath)) {
            throw "qBittorrent exe not found at: $ExePath"
        }

        Start-Process -FilePath $ExePath
        Write-Log "qBittorrent started."
    }
}

New-LogPath -Path $LogPath
Write-Log "=== Start ==="
Write-Log "User: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Log "Proton log dir: $ProtonVpnLogDir"
Write-Log "qBittorrent config: $QbitConfigPath"

try {
    Write-Log "Finding forwarded port in Proton VPN logs..."
    $newPort = Find-ProtonForwardedPort -LogDir $ProtonVpnLogDir -TailLines $LogTailLines
    if ($newPort -lt 1 -or $newPort -gt 65535) {
        throw "Invalid port parsed from logs: $newPort"
    }
    Write-Log "Forwarded port found: $newPort"

    Write-Log "Updating qBittorrent config..."
    $result = Update-QbitConfig -ConfigPath $QbitConfigPath -Port $newPort
    if ($result.Changed) {
        Write-Log "Port updated: $($result.OldPort) -> $($result.NewPort)"
    }
    else {
        Write-Log "Port already set to $($result.NewPort)"
    }

    if (-not $SkipRestartIfSame -or $result.Changed) {
        $exe = Find-QbitExe -OverridePath $QbitExePath
        Write-Log "Restarting qBittorrent..."
        Restart-Qbit -ExePath $exe
    }
    else {
        Write-Log "Skipping restart because port did not change."
    }

    Write-Log "=== Done ==="
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log "StackTrace: $($_.Exception.StackTrace)"
    Write-Log "=== Failed ==="
    exit 1
}
