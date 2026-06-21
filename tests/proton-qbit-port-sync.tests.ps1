[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Path $PSScriptRoot -Parent
. (Join-Path $projectRoot "proton-qbit-port-sync.ps1")

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message. Expected=[$Expected] Actual=[$Actual]"
    }
}

$testRoot = Join-Path $env:TEMP ("proton-qbit-port-sync-tests-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    Write-Output "TEST: parses a recent Proton port"
    $logDir = Join-Path $testRoot "logs"
    New-Item -ItemType Directory -Path $logDir | Out-Null
    $timestamp = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    Set-Content -LiteralPath (Join-Path $logDir "client-logs.txt") -Encoding UTF8 -Value @(
        "$timestamp | INFO | Port pair 12345->12345",
        "$timestamp | INFO | Port pair 54321 -> 54321"
    )
    $portInfo = Find-ProtonForwardedPort -LogDir $logDir -TailLines 100 -MaxAgeMinutes 10
    Assert-Equal 54321 $portInfo.Port "latest port should win"

    Write-Output "TEST: rejects a stale Proton port"
    $staleDir = Join-Path $testRoot "stale-logs"
    New-Item -ItemType Directory -Path $staleDir | Out-Null
    $staleTimestamp = [DateTimeOffset]::UtcNow.AddHours(-1).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    Set-Content -LiteralPath (Join-Path $staleDir "client-logs.txt") -Encoding UTF8 -Value "$staleTimestamp | INFO | Port pair 22222->22222"
    $staleRejected = $false
    try {
        $null = Find-ProtonForwardedPort -LogDir $staleDir -TailLines 100 -MaxAgeMinutes 10
    }
    catch {
        $staleRejected = $_.Exception.Message -match "stale"
    }
    Assert-True $staleRejected "stale port should be rejected"

    Write-Output "TEST: preserves UTF-8 BOM and CRLF and creates a backup"
    $configPath = Join-Path $testRoot "qBittorrent.ini"
    $originalConfig = "[Preferences]`r`nSession\Port=11111`r`nGeneral\Locale=pt_BR`r`n"
    [IO.File]::WriteAllText($configPath, $originalConfig, (New-Object Text.UTF8Encoding($true)))
    $update = Update-QbitConfig -ConfigPath $configPath -Port 33333
    Assert-True $update.Changed "port update should report a change"
    Assert-True (Test-Path -LiteralPath $update.BackupPath) "backup should exist"
    Assert-Equal 11111 (Get-QbitConfigPort -ConfigPath $update.BackupPath) "backup should retain old port"
    Assert-Equal 33333 (Get-QbitConfigPort -ConfigPath $configPath) "config should contain new port"
    $bytes = [IO.File]::ReadAllBytes($configPath)
    Assert-True (($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)) "UTF-8 BOM should be preserved"
    Assert-True (-not (($bytes[3] -eq 0xEF) -and ($bytes[4] -eq 0xBB) -and ($bytes[5] -eq 0xBF))) "BOM should not be duplicated"
    $updatedInfo = Get-TextFileInfo -Path $configPath
    Assert-True ($updatedInfo.Text.Contains("`r`n")) "CRLF should be preserved"
    Assert-True (-not ($updatedInfo.Text -match "(?<!`r)`n")) "bare LF should not be introduced"

    Write-Output "TEST: inserts a missing key inside the Preferences section"
    $missingPortPath = Join-Path $testRoot "missing-port.ini"
    $missingPortConfig = "[Preferences]`r`nGeneral\Locale=en`r`n[RSS]`r`nAutoDownloader\Enabled=false`r`n"
    [IO.File]::WriteAllText($missingPortPath, $missingPortConfig, (New-Object Text.UTF8Encoding($false)))
    $null = Update-QbitConfig -ConfigPath $missingPortPath -Port 44444
    $insertedText = (Get-TextFileInfo -Path $missingPortPath).Text
    Assert-Equal 44444 (Get-QbitConfigPort -ConfigPath $missingPortPath) "missing port should be inserted"
    Assert-True ($insertedText.IndexOf("Session\Port=44444") -lt $insertedText.IndexOf("[RSS]")) "port should be inside Preferences"

    Write-Output "TEST: leaves an unchanged config untouched"
    $beforeHash = (Get-FileHash -LiteralPath $missingPortPath -Algorithm SHA256).Hash
    $unchanged = Update-QbitConfig -ConfigPath $missingPortPath -Port 44444
    $afterHash = (Get-FileHash -LiteralPath $missingPortPath -Algorithm SHA256).Hash
    Assert-True (-not $unchanged.Changed) "same port should not report a change"
    Assert-Equal $beforeHash $afterHash "same port should not rewrite the file"

    Write-Output "TEST: runs end-to-end without touching the qBittorrent process"
    $e2eConfig = Join-Path $testRoot "e2e-qBittorrent.ini"
    $e2eLog = Join-Path $testRoot "sync.log"
    [IO.File]::WriteAllText($e2eConfig, "[Preferences]`r`nSession\Port=10000`r`n", (New-Object Text.UTF8Encoding($false)))
    & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File (Join-Path $projectRoot "proton-qbit-port-sync.ps1") `
        -ProtonVpnLogDir $logDir `
        -QbitConfigPath $e2eConfig `
        -LogPath $e2eLog `
        -NoRestart
    Assert-Equal 0 $LASTEXITCODE "end-to-end process should exit successfully"
    Assert-Equal 54321 (Get-QbitConfigPort -ConfigPath $e2eConfig) "end-to-end run should update the port"
    Assert-True ((Get-Content -LiteralPath $e2eLog -Raw) -match "=== Done ===") "end-to-end log should report success"

    Write-Output "All tests passed."
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
