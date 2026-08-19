<#
.SYNOPSIS
    VORSCHLAG 1 - VM PRE-Skript - KORRIGIERTE VERSION
    Laeuft auf JEDER Gast-VM (ausser Backup-VM selbst, siehe Hinweis).
    Wartet, bis BEIDE Bedingungen erfuellt sind, bevor NinjaOne das
    OS-Patching dieser VM freigibt:
      1. Veeam-Backup-Erfolgsflag der BackupVM ist vorhanden.
      2. Der Hyper-V-Host hat fuer DIESE VM einen Snapshot erstellt
         (SnapshotReady-Flag mit dem Computernamen dieser VM).

.AENDERUNG GEGENUEBER VORVERSION
    - NAS-Zugriff jetzt ueber cmdkey.exe + direkten UNC-Pfad (wie im bewaehrten
      Veeam-Backup-Skript), statt ueber New-PSDrive "FlagShare:".
    - Eigenes, separates Logfile (VMPre-log-<ComputerName>-<Datum>.txt).

.CUSTOM FIELDS (Geraet: jede VM)
    FlagFolder              (Text) - UNC-Pfad zum Flag-Share
    LogFolder               (Text) - UNC-Pfad zum Log-Ordner (optional, sonst = FlagFolder)
    NasUser / NasPassword   (Text) - Zugangsdaten fuer den Flag-Share
    VeeamFlagName           (Text) - Basisname Veeam-Flag, Default "VeeamBackup"
    VmWaitMaxMinutes        (Text) - Max. Wartezeit gesamt, Default 240
    VmWaitPollSeconds       (Text) - Abfrageintervall Sekunden, Default 30

.HINWEIS
    Verwendet den lokalen Computernamen (hostname) automatisch, um das
    passende SnapshotReady-Flag zu suchen - daher auf jeder VM identisch
    einsetzbar, ohne den VM-Namen manuell zu pflegen.
    Legt am Ende "C:\Temp\update_started.txt" an (Zeitstempel), damit das
    zugehoerige VM-Post-Skript den Reboot verifizieren kann.
#>

param(
    [string]$FlagFolderOverride = "",
    [string]$LogFolderOverride = "",
    [int]$MaxWaitMinutesOverride = 0,
    [int]$PollSecondsOverride = 0
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
$VeeamFlagName = if (Get-NinjaField "veeamFlagName") { Get-NinjaField "veeamFlagName" } else { "VeeamBackup" }
$MaxWaitMinutes = if ($MaxWaitMinutesOverride -gt 0) { $MaxWaitMinutesOverride } elseif (Get-NinjaField "vmWaitMaxMinutes") { [int](Get-NinjaField "vmWaitMaxMinutes") } else { 240 }
$PollSeconds = if ($PollSecondsOverride -gt 0) { $PollSecondsOverride } elseif (Get-NinjaField "vmWaitPollSeconds") { [int](Get-NinjaField "vmWaitPollSeconds") } else { 30 }

$Today = (Get-Date).ToString("yyyyMMdd")
$logFile = Join-Path $LogFolder "VMPre-log-$($ComputerName)-$Today.txt"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] [VM-PRE:$ComputerName] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
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

function Wait-ForFlag {
    param([string]$FlagPath, [int]$MaxWaitMinutes, [int]$PollSeconds, [string]$Description)
    $Deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
    while (-not (Test-Path $FlagPath)) {
        if ((Get-Date) -gt $Deadline) {
            throw "Timeout beim Warten auf $Description ($FlagPath)."
        }
        Write-Log "Warte auf $Description ..."
        Start-Sleep -Seconds $PollSeconds
    }
    Write-Log "$Description gefunden: $FlagPath"
}

try {
    Write-Log "=== Start Vorschlag 1: VM Pre (Warten auf Backup + Snapshot) ==="

    if (-not $FlagFolder) { throw "FlagFolder ist nicht gesetzt." }

    Connect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser -Password $NasPassword
    if (-not (Test-Path $FlagFolder)) { throw "Flag-Pfad nicht erreichbar: $FlagFolder" }

    $VeeamFlagPath = Join-Path $FlagFolder "$VeeamFlagName`_Success_$Today.flag"
    Wait-ForFlag -FlagPath $VeeamFlagPath -MaxWaitMinutes $MaxWaitMinutes -PollSeconds $PollSeconds -Description "Veeam-Backup-Erfolgsflag"

    $SnapshotFlagPath = Join-Path $FlagFolder "SnapshotReady_$($ComputerName)_$Today.flag"
    Wait-ForFlag -FlagPath $SnapshotFlagPath -MaxWaitMinutes $MaxWaitMinutes -PollSeconds $PollSeconds -Description "Snapshot-Ready-Flag fuer $ComputerName"

    Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser

    if (-not (Test-Path "C:\Temp")) { New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null }
    Set-Content -Path "C:\Temp\update_started.txt" -Value (Get-Date).ToString("o") -Force

    Write-Log "=== Ende Vorschlag 1 VM-Pre (Erfolg) - Update auf $ComputerName wird freigegeben ==="
    exit 0
}
catch {
    Write-Log "FEHLER: $($_.Exception.Message)"
    Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser
    Write-Error $_.Exception.Message
    exit 1
}
