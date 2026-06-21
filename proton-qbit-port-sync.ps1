<#
.SYNOPSIS
  Sincroniza a porta encaminhada do Proton VPN com o qBittorrent no Windows.
.DESCRIPTION
  Le a porta mais recente nos logs do Proton VPN, atualiza Session\Port no
  qBittorrent.ini com backup e reinicia o qBittorrent somente quando necessario.
.PARAMETER ProtonVpnLogDir
  Diretorio dos logs do Proton VPN.
.PARAMETER QbitConfigPath
  Caminho do qBittorrent.ini.
.PARAMETER QbitExePath
  Caminho do qbittorrent.exe. Se vazio, tenta detectar automaticamente.
.PARAMETER LogPath
  Caminho do log desta automacao.
.PARAMETER LogTailLines
  Quantidade de linhas finais lidas de cada log do Proton VPN.
.PARAMETER MaxPortAgeMinutes
  Idade maxima da entrada de porta. Use 0 para desabilitar esta validacao.
.PARAMETER NoRestart
  Atualiza somente o arquivo INI, sem encerrar ou iniciar o qBittorrent.
.PARAMETER StartIfNotRunning
  Inicia o qBittorrent apos uma alteracao mesmo se ele nao estava em execucao.
.PARAMETER ForceRestart
  Reinicia o qBittorrent mesmo quando a porta ja esta correta.
.PARAMETER SkipRestartIfSame
  Mantido para compatibilidade. Nao reiniciar quando a porta e igual agora e o padrao.
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\proton-qbit-port-sync.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ProtonVpnLogDir = (Join-Path $env:LOCALAPPDATA "Proton\Proton VPN\Logs"),
    [string]$QbitConfigPath = (Join-Path $env:APPDATA "qBittorrent\qBittorrent.ini"),
    [string]$QbitExePath = "",
    [string]$LogPath = (Join-Path $env:LOCALAPPDATA "ProtonQbitPortSync\proton-qbit-port-sync.log"),
    [ValidateRange(100, 1000000)]
    [int]$LogTailLines = 5000,
    [ValidateRange(0, 1440)]
    [int]$MaxPortAgeMinutes = 10,
    [ValidateRange(1, 100)]
    [int]$MaxLogSizeMB = 5,
    [switch]$NoRestart,
    [switch]$StartIfNotRunning,
    [switch]$ForceRestart,
    [switch]$SkipRestartIfSame
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Initialize-LogPath {
    param([string]$Path, [int]$MaxSizeMB)

    $directory = Split-Path -Path $Path -Parent
    if (-not $directory) {
        throw "LogPath must include a directory: $Path"
    }
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Path) {
        $maxBytes = $MaxSizeMB * 1MB
        if ((Get-Item -LiteralPath $Path).Length -ge $maxBytes) {
            $backupPath = "$Path.1"
            Move-Item -LiteralPath $Path -Destination $backupPath -Force
        }
    }
}

function Write-Log {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Output $line
}

function Get-TextFileInfo {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $offset = 0

    if (($bytes.Length -ge 4) -and ($bytes[0] -eq 0xFF) -and ($bytes[1] -eq 0xFE) -and ($bytes[2] -eq 0x00) -and ($bytes[3] -eq 0x00)) {
        $encoding = New-Object System.Text.UTF32Encoding($false, $true, $true)
        $offset = 4
    }
    elseif (($bytes.Length -ge 4) -and ($bytes[0] -eq 0x00) -and ($bytes[1] -eq 0x00) -and ($bytes[2] -eq 0xFE) -and ($bytes[3] -eq 0xFF)) {
        $encoding = New-Object System.Text.UTF32Encoding($true, $true, $true)
        $offset = 4
    }
    elseif (($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)) {
        $encoding = New-Object System.Text.UTF8Encoding($true, $true)
        $offset = 3
    }
    elseif (($bytes.Length -ge 2) -and ($bytes[0] -eq 0xFF) -and ($bytes[1] -eq 0xFE)) {
        $encoding = New-Object System.Text.UnicodeEncoding($false, $true, $true)
        $offset = 2
    }
    elseif (($bytes.Length -ge 2) -and ($bytes[0] -eq 0xFE) -and ($bytes[1] -eq 0xFF)) {
        $encoding = New-Object System.Text.UnicodeEncoding($true, $true, $true)
        $offset = 2
    }
    else {
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        try {
            $null = $encoding.GetString($bytes)
        }
        catch [System.Text.DecoderFallbackException] {
            $encoding = [System.Text.Encoding]::Default
        }
    }

    $text = $encoding.GetString($bytes, $offset, ($bytes.Length - $offset))
    $newLine = [Environment]::NewLine
    if ($text.Contains("`r`n")) {
        $newLine = "`r`n"
    }
    elseif ($text.Contains("`n")) {
        $newLine = "`n"
    }

    [pscustomobject]@{
        Text     = $text
        Encoding = $encoding
        NewLine  = $newLine
        HasBom   = ($offset -gt 0)
    }
}

function Find-ProtonForwardedPort {
    param([string]$LogDir, [int]$TailLines, [int]$MaxAgeMinutes)

    if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) {
        throw "Proton VPN log directory not found: $LogDir"
    }

    $logs = Get-ChildItem -LiteralPath $LogDir -Filter "*.txt" -File |
    Sort-Object LastWriteTimeUtc -Descending
    if (-not $logs) {
        throw "No Proton VPN log files found in: $LogDir"
    }

    $portPattern = [regex]'(?i)\bPort\s+pair\s+(?<port>\d{1,5})\s*->'
    $timestampPattern = [regex]'^(?<timestamp>\d{4}-\d{2}-\d{2}T\S+)'

    foreach ($log in $logs) {
        $lines = @(Get-Content -LiteralPath $log.FullName -Tail $TailLines -ErrorAction Stop)
        for ($index = $lines.Count - 1; $index -ge 0; $index--) {
            $portMatch = $portPattern.Match([string]$lines[$index])
            if (-not $portMatch.Success) {
                continue
            }

            $port = [int]$portMatch.Groups['port'].Value
            if (($port -lt 1) -or ($port -gt 65535)) {
                continue
            }

            $observedAt = [DateTimeOffset]$log.LastWriteTime
            $timestampMatch = $timestampPattern.Match([string]$lines[$index])
            if ($timestampMatch.Success) {
                $parsedTimestamp = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse(
                        $timestampMatch.Groups['timestamp'].Value,
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::RoundtripKind,
                        [ref]$parsedTimestamp
                    )) {
                    $observedAt = $parsedTimestamp
                }
            }

            $age = [DateTimeOffset]::UtcNow - $observedAt.ToUniversalTime()
            if (($MaxAgeMinutes -gt 0) -and ($age.TotalMinutes -gt $MaxAgeMinutes)) {
                throw ("Latest Proton forwarded port is stale ({0:N1} minutes old): {1}" -f $age.TotalMinutes, $observedAt)
            }
            if ($age.TotalMinutes -lt -5) {
                throw "Latest Proton forwarded port has a timestamp in the future: $observedAt"
            }

            return [pscustomobject]@{
                Port       = $port
                ObservedAt = $observedAt
                Source     = $log.FullName
            }
        }
    }

    throw "No 'Port pair <port>->' entry found in Proton VPN logs. Is Port Forwarding enabled and connected?"
}

function Get-QbitConfigPort {
    param([string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "qBittorrent config not found: $ConfigPath"
    }

    $fileInfo = Get-TextFileInfo -Path $ConfigPath
    $match = [regex]::Match($fileInfo.Text, '(?m)^[ \t]*Session\\Port[ \t]*=[ \t]*(?<port>\d+)[ \t]*\r?$')
    if (-not $match.Success) {
        return $null
    }
    return [int]$match.Groups['port'].Value
}

function Update-QbitConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$ConfigPath, [int]$Port)

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "qBittorrent config not found: $ConfigPath"
    }

    $fileInfo = Get-TextFileInfo -Path $ConfigPath
    $text = $fileInfo.Text
    $newLine = $fileInfo.NewLine
    $portPattern = '(?m)^[ \t]*Session\\Port[ \t]*=[^\r\n]*'
    $match = [regex]::Match($text, $portPattern)
    $oldPort = Get-QbitConfigPort -ConfigPath $ConfigPath

    if (($oldPort -eq $Port) -and $match.Success) {
        return [pscustomobject]@{ Changed = $false; OldPort = $oldPort; NewPort = $Port; BackupPath = $null }
    }

    $portLine = "Session\Port=$Port"
    if ($match.Success) {
        $updatedText = $text.Substring(0, $match.Index) + $portLine + $text.Substring($match.Index + $match.Length)
    }
    else {
        $preferencesHeader = [regex]::Match($text, '(?mi)^\[Preferences\][ \t]*(?:\r?\n|$)')
        if ($preferencesHeader.Success) {
            $insertAt = $preferencesHeader.Index + $preferencesHeader.Length
            $separator = ""
            if (-not $preferencesHeader.Value.EndsWith("`n")) {
                $separator = $newLine
            }
            $updatedText = $text.Insert($insertAt, $separator + $portLine + $newLine)
        }
        else {
            $trimmedText = $text.TrimEnd("`r", "`n")
            $updatedText = $trimmedText + $newLine + $newLine + "[Preferences]" + $newLine + $portLine + $newLine
        }
    }

    $backupPath = "$ConfigPath.proton-qbit-port-sync.bak"
    if ($PSCmdlet.ShouldProcess($ConfigPath, "Set Session\Port to $Port (backup: $backupPath)")) {
        $tempPath = Join-Path (Split-Path -Path $ConfigPath -Parent) (".{0}.{1}.tmp" -f ([IO.Path]::GetFileName($ConfigPath)), [guid]::NewGuid().ToString('N'))
        try {
            [System.IO.File]::WriteAllText($tempPath, $updatedText, $fileInfo.Encoding)
            try {
                [System.IO.File]::Replace($tempPath, $ConfigPath, $backupPath, $true)
            }
            catch [System.PlatformNotSupportedException] {
                Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
                Move-Item -LiteralPath $tempPath -Destination $ConfigPath -Force
            }
            catch [System.IO.IOException] {
                Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
                Move-Item -LiteralPath $tempPath -Destination $ConfigPath -Force
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempPath) {
                Remove-Item -LiteralPath $tempPath -Force
            }
        }
    }

    [pscustomobject]@{ Changed = $true; OldPort = $oldPort; NewPort = $Port; BackupPath = $backupPath }
}

function Find-QbitExe {
    param([string]$OverridePath)

    if ($OverridePath) {
        if (Test-Path -LiteralPath $OverridePath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $OverridePath).Path
        }
        throw "qBittorrent executable not found at: $OverridePath"
    }

    $running = Get-Process -Name "qbittorrent" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($running -and $running.Path -and (Test-Path -LiteralPath $running.Path)) {
        return $running.Path
    }

    $candidates = @(
        "C:\Program Files\qBittorrent\qbittorrent.exe",
        "C:\Program Files (x86)\qBittorrent\qbittorrent.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $command = Get-Command "qbittorrent.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw "qBittorrent executable not found. Provide -QbitExePath explicitly."
}

function Stop-Qbit {
    [CmdletBinding(SupportsShouldProcess)]
    param([System.Diagnostics.Process[]]$Processes, [int]$GracefulTimeoutSeconds = 10)

    if (-not $Processes) {
        return
    }
    if (-not $PSCmdlet.ShouldProcess("qBittorrent", "Stop before updating its configuration")) {
        return
    }

    $requestedGracefulClose = $false
    foreach ($process in $Processes) {
        try {
            if ($process.CloseMainWindow()) {
                $requestedGracefulClose = $true
            }
        }
        catch {
            Write-Log "Could not request graceful close for qBittorrent PID $($process.Id): $($_.Exception.Message)"
        }
    }

    if ($requestedGracefulClose) {
        $deadline = (Get-Date).AddSeconds($GracefulTimeoutSeconds)
        do {
            Start-Sleep -Milliseconds 250
            $remaining = @(Get-Process -Name "qbittorrent" -ErrorAction SilentlyContinue)
        } while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline)
    }

    $remaining = @(Get-Process -Name "qbittorrent" -ErrorAction SilentlyContinue)
    if ($remaining.Count -gt 0) {
        Write-Log "Graceful close was unavailable; forcing qBittorrent to stop."
        $remaining | Stop-Process -Force -ErrorAction Stop
        $remaining | Wait-Process -Timeout 15 -ErrorAction Stop
    }
    Write-Log "qBittorrent stopped."
}

function Start-Qbit {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$ExePath)

    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        throw "qBittorrent executable not found at: $ExePath"
    }
    if ($PSCmdlet.ShouldProcess("qBittorrent", "Start $ExePath")) {
        $process = Start-Process -FilePath $ExePath -PassThru
        Start-Sleep -Seconds 2
        if ($process.HasExited) {
            throw "qBittorrent exited immediately with code $($process.ExitCode)."
        }
        Write-Log "qBittorrent started (PID $($process.Id))."
    }
}

function Invoke-PortSync {
    $mutex = $null
    $hasMutex = $false
    $qbitWasStopped = $false
    $qbitShouldStart = $false
    $qbitExe = $null

    try {
        $mutex = New-Object System.Threading.Mutex($false, "Local\ProtonQbitPortSync")
        $hasMutex = $mutex.WaitOne(0, $false)
        if (-not $hasMutex) {
            Write-Output "Another Proton qBittorrent port sync is already running."
            return
        }

        Initialize-LogPath -Path $LogPath -MaxSizeMB $MaxLogSizeMB
        Write-Log "=== Start ==="
        Write-Log "User: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        Write-Log "Proton log directory: $ProtonVpnLogDir"
        Write-Log "qBittorrent config: $QbitConfigPath"

        $portInfo = Find-ProtonForwardedPort -LogDir $ProtonVpnLogDir -TailLines $LogTailLines -MaxAgeMinutes $MaxPortAgeMinutes
        Write-Log "Forwarded port found: $($portInfo.Port) (observed $($portInfo.ObservedAt.ToString('o')))"

        $currentPort = Get-QbitConfigPort -ConfigPath $QbitConfigPath
        if (($currentPort -eq $portInfo.Port) -and (-not $ForceRestart)) {
            Write-Log "Port already set to $currentPort; no restart needed."
            Write-Log "=== Done ==="
            return
        }

        $runningProcesses = @(Get-Process -Name "qbittorrent" -ErrorAction SilentlyContinue)
        $qbitShouldStart = ($runningProcesses.Count -gt 0) -or $StartIfNotRunning
        if ((-not $NoRestart) -and $qbitShouldStart) {
            $qbitExe = Find-QbitExe -OverridePath $QbitExePath
        }

        if ((-not $NoRestart) -and ($runningProcesses.Count -gt 0)) {
            Write-Log "Stopping qBittorrent before changing its configuration..."
            Stop-Qbit -Processes $runningProcesses
            $qbitWasStopped = $true
        }
        elseif ($NoRestart -and ($runningProcesses.Count -gt 0)) {
            Write-Log "WARNING: -NoRestart was used while qBittorrent is running; the new port may require a later restart."
        }

        if ($currentPort -ne $portInfo.Port) {
            $result = Update-QbitConfig -ConfigPath $QbitConfigPath -Port $portInfo.Port
            Write-Log "Port updated: $($result.OldPort) -> $($result.NewPort)"
            if ($result.BackupPath) {
                Write-Log "Config backup: $($result.BackupPath)"
            }
        }
        else {
            Write-Log "Port is unchanged; restart was explicitly requested."
        }

        if ((-not $NoRestart) -and $qbitShouldStart) {
            Start-Qbit -ExePath $qbitExe
            $qbitWasStopped = $false
        }
        Write-Log "=== Done ==="
    }
    catch {
        if (Test-Path -LiteralPath (Split-Path -Path $LogPath -Parent)) {
            try {
                Write-Log "ERROR: $($_.Exception.Message)"
                Write-Log "=== Failed ==="
            }
            catch {
                Write-Error $_.Exception.Message
            }
        }
        else {
            Write-Error $_.Exception.Message
        }
        $script:PortSyncExitCode = 1
    }
    finally {
        if ($qbitWasStopped -and $qbitExe) {
            try {
                Write-Log "Recovering qBittorrent after a failed update..."
                Start-Qbit -ExePath $qbitExe
            }
            catch {
                try { Write-Log "ERROR: qBittorrent recovery failed: $($_.Exception.Message)" } catch {}
                $script:PortSyncExitCode = 1
            }
        }
        if ($hasMutex -and $mutex) {
            $mutex.ReleaseMutex()
        }
        if ($mutex) {
            $mutex.Dispose()
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $script:PortSyncExitCode = 0
    Invoke-PortSync
    exit $script:PortSyncExitCode
}
