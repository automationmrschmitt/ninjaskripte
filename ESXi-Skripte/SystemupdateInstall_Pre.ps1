<#
.SYNOPSIS
    VM-Policy PRE-Skript (SystemUpdateInstall_Pre.ps1)
    Wartet auf die Veeam-Backup-Flag, bevor der Patch-Vorgang fuer diese VM startet.
    Passt zur Namenskonvention des Veeam-Skripts: "<FlagName>_Success_<yyyyMMdd>.flag"

.PARAMETER FlagName
    Muss zum FlagName des Veeam-Skripts passen. Default: "VeeamBackup"

.PARAMETER FlagFolder
    Pfad zur Flag-Ablage (NAS/UNC), identisch zum Veeam-Skript.

.PARAMETER TimeoutHours
    Maximale Wartezeit auf die Backup-Flag, bevor abgebrochen wird (verhindert Endlos-Loop).

.PARAMETER PollSeconds
    Abfrageintervall waehrend des Wartens.

.PARAMETER NasUser / NasPassword
    Dedizierter NAS-Zugang, falls das Computerkonto keinen Zugriff auf FlagFolder hat.

.NOTES
    Custom-Field-Bezug (Multi-Kunden, wie im Veeam-Skript):
      - FlagName    <- Device Custom Field "veeamFlagName"
      - FlagFolder  <- Org Custom Field    "flagFolder"
      - NasUser     <- Org Custom Field    "nasUser"
      - NasPassword <- Org Custom Field    "nasPassword" (SECURE)

    Schreibt zusaetzlich einen Zeitstempel in "update_started.txt" (lokal),
    den das Post-Skript (SystemUpdateInstall_Post.ps1) fuer den
    LastBootUpTime-Vergleich benoetigt.
#>

param(
    [string]$FlagName       = "VeeamBackup",
    [string]$FlagFolder     = "",
    [int]$TimeoutHours      = 4,
    [int]$PollSeconds       = 30,
    [string]$NasUser        = "",
    [string]$NasPassword    = "",
    [string]$LocalStateDir  = "C:\ProgramData\PatchAutomation"
)

function Get-NinjaOrDefault {
    param([string]$CurrentValue, [string]$FieldName)
    if (-not (Get-Command Ninja-Property-Get -ErrorAction SilentlyContinue)) { return $CurrentValue }
    try {
        $fieldValue = Ninja-Property-Get -Name $FieldName -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($fieldValue)) { return $fieldValue }
    } catch { }
    return $CurrentValue
}

if ($FlagName    -eq "VeeamBackup")      { $FlagName    = Get-NinjaOrDefault -CurrentValue $FlagName    -FieldName "veeamFlagName" }
if ($FlagFolder  -eq "") { $FlagFolder  = Get-NinjaOrDefault -CurrentValue $FlagFolder  -FieldName "flagFolder" }
if ([string]::IsNullOrWhiteSpace($NasUser))     { $NasUser     = Get-NinjaOrDefault -CurrentValue $NasUser     -FieldName "nasUser" }
if ([string]::IsNullOrWhiteSpace($NasPassword)) { $NasPassword = Get-NinjaOrDefault -CurrentValue $NasPassword -FieldName "nasPassword" }

$today            = Get-Date -Format "yyyyMMdd"
$flagFilter       = "$FlagName`_Success_*.flag"
$expectedName     = "$FlagName`_Success_$today.flag"
$logFile          = Join-Path $LocalStateDir "vm_pre_$today.log"
$updateStartFile  = Join-Path $LocalStateDir "update_started.txt"
$startTime        = Get-Date

New-Item -ItemType Directory -Path $LocalStateDir -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
    Write-Output $line
}

function Get-NasServerPath {
    param([string]$UncPath)
    $parts = $UncPath.TrimStart('\') -split '\\'
    return "\\" + $parts[0]
}

function Connect-NasFlagShare {
    param([string]$UncPath, [string]$UserName, [string]$Password)
    if ([string]::IsNullOrWhiteSpace($UserName)) { return }
    $server = Get-NasServerPath -UncPath $UncPath
    net use $server /delete /y 2>$null | Out-Null
    cmdkey.exe /delete:$($server.TrimStart('\')) 2>$null | Out-Null
    $null = cmdkey.exe /add:$($server.TrimStart('\')) /user:$UserName /pass:$Password
    if ($LASTEXITCODE -ne 0) { throw "cmdkey-Anmeldung am NAS fehlgeschlagen (Exit $LASTEXITCODE)." }
    Start-Sleep -Seconds 1
    if (-not (Test-Path $UncPath)) { throw "NAS-Anmeldung gesetzt, aber $UncPath nicht erreichbar." }
}

function Disconnect-NasFlagShare {
    param([string]$UncPath, [string]$UserName)
    if ([string]::IsNullOrWhiteSpace($UserName)) { return }
    $server = Get-NasServerPath -UncPath $UncPath
    $null = cmdkey.exe /delete:$($server.TrimStart('\')) 2>$null
}

try {
    Write-Log "=== Start VM-Pre: warte auf Backup-Flag '$expectedName' ==="
    Connect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser -Password $NasPassword

    if (-not (Test-Path $FlagFolder)) { throw "Flag-Pfad nicht erreichbar: $FlagFolder" }

    while ($true) {
        $latestFlag = Get-ChildItem -Path $FlagFolder -Filter $flagFilter -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1

        if ($latestFlag -and $latestFlag.Name -eq $expectedName -and $latestFlag.LastWriteTime.Date -eq (Get-Date).Date) {
            Write-Log "Backup-Flag erkannt: $($latestFlag.FullName). Patch-Vorgang wird freigegeben."
            break
        }

        if (((Get-Date) - $startTime).TotalHours -ge $TimeoutHours) {
            throw "TIMEOUT: Backup-Flag '$expectedName' nach $TimeoutHours h nicht erschienen."
        }

        Start-Sleep -Seconds $PollSeconds
    }

    # Zeitstempel VOR dem Update festhalten - wird vom Post-Skript fuer den
    # LastBootUpTime-Vergleich benoetigt (Reboot-Nachweis).
    (Get-Date).ToString("o") | Set-Content -Path $updateStartFile -Force
    Write-Log "Zeitstempel geschrieben: $updateStartFile"

    Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser
    Write-Log "=== Ende VM-Pre (Erfolg) ==="
    exit 0
}
catch {
    Write-Log "FEHLER: $($_.Exception.Message)"
    Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser
    Write-Error $_.Exception.Message
    exit 1
}
