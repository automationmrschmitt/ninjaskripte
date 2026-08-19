<#
.SYNOPSIS
    VORSCHLAG 1 - VM PRE-Skript
    Laeuft auf JEDER Gast-VM (ausser Backup-VM selbst, siehe Hinweis).
    Wartet, bis BEIDE Bedingungen erfuellt sind, bevor NinjaOne das
    OS-Patching dieser VM freigibt:
      1. Veeam-Backup-Erfolgsflag der BackupVM ist vorhanden.
      2. Der Hyper-V-Host hat fuer DIESE VM einen Snapshot erstellt
         (SnapshotReady-Flag mit dem Computernamen dieser VM).

.CUSTOM FIELDS (Geraet: jede VM)
    FlagFolder              (Text) - UNC-Pfad zum Flag-Share
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
    [int]$MaxWaitMinutesOverride = 0,
    [int]$PollSecondsOverride = 0
)

function Write-Log {
    param([string]$Message)
    $ts = (Get-Date).ToString("o")
    Write-Output "[$ts] $Message"
}

function Get-NinjaField {
    param([string]$FieldName)
    try { return (Ninja-Property-Get $FieldName) } catch { return $null }
}

function Connect-NasFlagShare {
    param([string]$UncPath, [string]$UserName, [string]$Password)
    if (-not $UserName) { return }
    $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ($UserName, $secure)
    try {
        New-PSDrive -Name "FlagShare" -PSProvider FileSystem -Root $UncPath -Credential $cred -ErrorAction Stop | Out-Null
        Write-Log "NAS-Share verbunden: $UncPath"
    } catch {
        Write-Log "WARNUNG: Verbindung zum NAS-Share fehlgeschlagen: $($_.Exception.Message)"
    }
}

function Disconnect-NasFlagShare {
    Remove-PSDrive -Name "FlagShare" -ErrorAction SilentlyContinue
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

    $ComputerName = $env:COMPUTERNAME
    $FlagFolder = if ($FlagFolderOverride) { $FlagFolderOverride } else { Get-NinjaField "flagFolder" }
    $NasUser = Get-NinjaField "nasUser"
    $NasPassword = Get-NinjaField "nasPassword"
    $VeeamFlagName = if (Get-NinjaField "veeamFlagName") { Get-NinjaField "veeamFlagName" } else { "VeeamBackup" }
    $MaxWaitMinutes = if ($MaxWaitMinutesOverride -gt 0) { $MaxWaitMinutesOverride } elseif (Get-NinjaField "vmWaitMaxMinutes") { [int](Get-NinjaField "vmWaitMaxMinutes") } else { 240 }
    $PollSeconds = if ($PollSecondsOverride -gt 0) { $PollSecondsOverride } elseif (Get-NinjaField "vmWaitPollSeconds") { [int](Get-NinjaField "vmWaitPollSeconds") } else { 30 }

    if (-not $FlagFolder) { throw "FlagFolder ist nicht gesetzt." }

    $Today = (Get-Date).ToString("yyyyMMdd")
    Connect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser -Password $NasPassword

    $VeeamFlagPath = Join-Path "FlagShare:\" "$VeeamFlagName`_Success_$Today.flag"
    Wait-ForFlag -FlagPath $VeeamFlagPath -MaxWaitMinutes $MaxWaitMinutes -PollSeconds $PollSeconds -Description "Veeam-Backup-Erfolgsflag"

    $SnapshotFlagPath = Join-Path "FlagShare:\" "SnapshotReady_$ComputerName`_$Today.flag"
    Wait-ForFlag -FlagPath $SnapshotFlagPath -MaxWaitMinutes $MaxWaitMinutes -PollSeconds $PollSeconds -Description "Snapshot-Ready-Flag fuer $ComputerName"

    Disconnect-NasFlagShare

    if (-not (Test-Path "C:\Temp")) { New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null }
    (Get-Date).ToString("o") | Set-Content -Path "C:\Temp\update_started.txt" -Force

    Write-Log "=== Ende Vorschlag 1 VM-Pre (Erfolg) - Update auf $ComputerName wird freigegeben ==="
    exit 0
}
catch {
    Write-Log "FEHLER: $($_.Exception.Message)"
    Disconnect-NasFlagShare
    Write-Error $_.Exception.Message
    exit 1
}
