<#
.SYNOPSIS
    Hyper-V Host Post-Skript (Hyper-V_Host_Cleanup_Post.ps1) - KORRIGIERTE VERSION,
    gilt fuer ALLE DREI Vorschlaege unveraendert. Als POST-Skript in der
    NinjaOne OS-Patch-Policy des Hyper-V-HOSTS hinterlegen. Prueft per
    LastBootUpTime, ob der Host wirklich neu gestartet wurde, und bereinigt
    danach den kompletten Flag-Ordner fuer den heutigen Lauf (Snapshot-Ready-
    Flags UND VM-Done-Flags), damit der naechste Patch-Zyklus wieder mit
    einem leeren Ordner startet.

.AENDERUNG GEGENUEBER VORVERSION
    - Tippfehler "Out-Nulll" (drei l) behoben -> haette einen Parser-Fehler
      ausgeloest, da kein gueltiges Cmdlet.
    - NAS-Zugriff jetzt ueber cmdkey.exe + direkten UNC-Pfad (wie im bewaehrten
      Veeam-Backup-Skript), statt ueber New-PSDrive "FlagShare:".
    - Flag-Ordner-Zugriff wird nach dem Connect per Test-Path verifiziert.
    - Eigenes, separates Logfile (CleanupPost-log-<Datum>.txt).

.CUSTOM FIELDS (Geraet: Hyper-V-Host)
    FlagFolder               (Text)  - UNC-Pfad zum Flag-Share
    LogFolder                (Text)  - UNC-Pfad zum Log-Ordner (optional, sonst = FlagFolder)
    NasUser / NasPassword    (Text)  - Zugangsdaten fuer den Flag-Share
    HostRebootMaxWaitMinutes (Text)  - Max. Wartezeit auf Reboot-Bestaetigung, Default = 30
#>

param(
    [string]$FlagFolderOverride = "",
    [string]$LogFolderOverride = "",
    [int]$MaxWaitMinutesOverride = 0
)

function Get-NinjaField {
    param([string]$FieldName)
    try { return (Ninja-Property-Get $FieldName) } catch { return $null }
}

$FlagFolder = if ($FlagFolderOverride) { $FlagFolderOverride } else { Get-NinjaField "flagFolder" }
$LogFolder  = if ($LogFolderOverride) { $LogFolderOverride } elseif (Get-NinjaField "logFolder") { Get-NinjaField "logFolder" } else { $FlagFolder }
$NasUser = Get-NinjaField "nasUser"
$NasPassword = Get-NinjaField "nasPassword"
$MaxWaitMinutes = if ($MaxWaitMinutesOverride -gt 0) { $MaxWaitMinutesOverride } elseif (Get-NinjaField "hostRebootMaxWaitMinutes") { [int](Get-NinjaField "hostRebootMaxWaitMinutes") } else { 30 }

$Today = (Get-Date).ToString("yyyyMMdd")
$logFile = Join-Path $LogFolder "CleanupPost-log-$Today.txt"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] [CLEANUP-POST] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    try {
        if (-not (Test-Path $LogFolder)) { New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null }
        Add-Content -Path $logFile -Value $line -Encoding UTF8
    } catch { }
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
    if (-not (Test-Path $UncPath)) { throw "NAS-Anmeldung gesetzt, aber $UncPath ist trotzdem nicht erreichbar." }
    Write-Log "NAS-Share verbunden (cmdkey): $UncPath"
}

function Disconnect-NasFlagShare {
    param([string]$UncPath, [string]$UserName)
    if ([string]::IsNullOrWhiteSpace($UserName)) { return }
    $server = Get-NasServerPath -UncPath $UncPath
    $null = cmdkey.exe /delete:$($server.TrimStart('\')) 2>$null
}

function Test-PendingReboot {
    $Key1 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
    $Key2 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    return (Test-Path $Key1) -or (Test-Path $Key2)
}

try {
    Write-Log "=== Start Hyper-V Host Cleanup-Post ==="

    if (-not $FlagFolder) { throw "FlagFolder ist nicht gesetzt." }

    $UpdateStartFile = "C:\Temp\update_started.txt"
    if (-not (Test-Path $UpdateStartFile)) {
        throw "update_started.txt nicht gefunden - Host-Pre-Skript wurde vermutlich nicht korrekt durchlaufen."
    }
    $UpdateStartTime = [DateTime]::Parse((Get-Content $UpdateStartFile -Raw), $null, [System.Globalization.DateTimeStyles]::RoundtripKind)

    $Deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
    $RebootConfirmed = $false
    while ((Get-Date) -lt $Deadline) {
        $LastBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        if ($LastBoot -gt $UpdateStartTime) {
            Write-Log "Reboot bestaetigt: LastBootUpTime ($LastBoot) liegt nach Update-Start ($UpdateStartTime)."
            $RebootConfirmed = $true
            break
        }
        if (-not (Test-PendingReboot)) {
            Write-Log "Kein Reboot ausstehend und keiner noetig - werte als erfolgreich abgeschlossen."
            $RebootConfirmed = $true
            break
        }
        Write-Log "Warte auf Host-Reboot-Bestaetigung..."
        Start-Sleep -Seconds 30
    }

    if (-not $RebootConfirmed) {
        throw "Timeout: Host-Reboot konnte nicht innerhalb von $MaxWaitMinutes Minuten bestaetigt werden."
    }

    Connect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser -Password $NasPassword
    if (-not (Test-Path $FlagFolder)) { throw "Flag-Pfad nicht erreichbar: $FlagFolder" }

    $FilesToClean = Get-ChildItem -Path $FlagFolder -Filter "*_$Today.flag" -ErrorAction SilentlyContinue
    foreach ($File in $FilesToClean) {
        Remove-Item $File.FullName -Force -ErrorAction SilentlyContinue
        Write-Log "Flag entfernt: $($File.Name)"
    }

    Remove-Item $UpdateStartFile -Force -ErrorAction SilentlyContinue
    Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser
    Write-Log "=== Ende Hyper-V Host Cleanup-Post (Erfolg) ==="
    exit 0
}
catch {
    Write-Log "FEHLER: $($_.Exception.Message)"
    Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser
    Write-Error $_.Exception.Message
    exit 1
}
