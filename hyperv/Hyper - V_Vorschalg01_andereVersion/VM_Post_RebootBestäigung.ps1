<#
.SYNOPSIS
    VM POST-Skript - KORRIGIERTE VERSION - gilt fuer ALLE DREI Vorschlaege identisch.
    Laeuft auf JEDER Gast-VM nach dem OS-Patching. Prueft per LastBootUpTime,
    ob die VM seit dem in "update_started.txt" hinterlegten Zeitpunkt
    tatsaechlich neu gestartet wurde (oder kein Reboot noetig war), und legt
    danach das Done-Flag fuer diese VM ab, auf das der Hyper-V-Host wartet.

.AENDERUNG GEGENUEBER VORVERSION
    - NAS-Zugriff jetzt ueber cmdkey.exe + direkten UNC-Pfad (wie im bewaehrten
      Veeam-Backup-Skript), statt ueber New-PSDrive "FlagShare:". Das war die
      Ursache, warum Done-Flags trotz erfolgreichem Reboot-Check gelegentlich
      nicht geschrieben wurden.
    - Flag-Write wird per Test-Path verifiziert -> Fehler wird sofort sichtbar.
    - Eigenes, separates Logfile (VMPost-log-<ComputerName>-<Datum>.txt) statt
      Vermischung mit anderen Skript-Logs.

.CUSTOM FIELDS (Geraet: jede VM)
    FlagFolder                (Text) - UNC-Pfad zum Flag-Share
    LogFolder                 (Text) - UNC-Pfad zum Log-Ordner (optional, sonst = FlagFolder)
    NasUser / NasPassword     (Text) - Zugangsdaten fuer den Flag-Share
    VmDoneFlagPrefix          (Text) - Praefix, Default "VmUpdateDone"
    VmRebootMaxWaitMinutes    (Text) - Max. Wartezeit auf Reboot-Bestaetigung,
                                       Default 30
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

$ComputerName = $env:COMPUTERNAME
$FlagFolder = if ($FlagFolderOverride) { $FlagFolderOverride } else { Get-NinjaField "flagFolder" }
$LogFolder  = if ($LogFolderOverride) { $LogFolderOverride } elseif (Get-NinjaField "logFolder") { Get-NinjaField "logFolder" } else { $FlagFolder }
$NasUser = Get-NinjaField "nasUser"
$NasPassword = Get-NinjaField "nasPassword"
$VmDoneFlagPrefix = if (Get-NinjaField "vmDoneFlagPrefix") { Get-NinjaField "vmDoneFlagPrefix" } else { "VmUpdateDone" }
$MaxWaitMinutes = if ($MaxWaitMinutesOverride -gt 0) { $MaxWaitMinutesOverride } elseif (Get-NinjaField "vmRebootMaxWaitMinutes") { [int](Get-NinjaField "vmRebootMaxWaitMinutes") } else { 30 }

$Today = (Get-Date).ToString("yyyyMMdd")
$logFile = Join-Path $LogFolder "VMPost-log-$($ComputerName)-$Today.txt"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] [VM-POST:$ComputerName] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
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
    Write-Log "=== Start VM Post (gilt fuer alle drei Vorschlaege) ==="

    if (-not $FlagFolder) { throw "FlagFolder ist nicht gesetzt." }

    $UpdateStartFile = "C:\Temp\update_started.txt"
    if (-not (Test-Path $UpdateStartFile)) {
        throw "update_started.txt nicht gefunden - VM-Pre-Skript wurde vermutlich nicht korrekt durchlaufen."
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
        Write-Log "Warte auf Reboot-Bestaetigung von $ComputerName ..."
        Start-Sleep -Seconds 30
    }

    if (-not $RebootConfirmed) {
        throw "Timeout: Reboot von $ComputerName konnte nicht innerhalb von $MaxWaitMinutes Minuten bestaetigt werden."
    }

    Connect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser -Password $NasPassword
    if (-not (Test-Path $FlagFolder)) { throw "Flag-Pfad nicht erreichbar: $FlagFolder" }

    $DoneFlagPath = Join-Path $FlagFolder "$VmDoneFlagPrefix`_$ComputerName`_$Today.flag"
    Set-Content -Path $DoneFlagPath -Value (Get-Date).ToString("o") -Encoding UTF8 -Force
    if (-not (Test-Path $DoneFlagPath)) { throw "Flag-Datei konnte nicht bestaetigt werden: $DoneFlagPath" }
    Write-Log "Done-Flag fuer $ComputerName abgelegt: $DoneFlagPath"

    Remove-Item $UpdateStartFile -Force -ErrorAction SilentlyContinue
    Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser
    Write-Log "=== Ende VM Post (Erfolg) fuer $ComputerName ==="
    exit 0
}
catch {
    Write-Log "FEHLER: $($_.Exception.Message)"
    Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser
    Write-Error $_.Exception.Message
    exit 1
}
