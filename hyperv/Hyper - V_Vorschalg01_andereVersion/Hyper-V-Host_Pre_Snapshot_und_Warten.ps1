<#
.SYNOPSIS
    VORSCHLAG 1 - Hyper-V Host PRE-Skript (kombiniert) - KORRIGIERTE VERSION
    Ablauf: BackupVM macht Veeam-Backup -> Host wartet -> Host macht Snapshots
    aller VMs -> VMs warten auf SnapshotReady-Flag + Veeam-Flag -> VMs updaten
    -> Host wartet auf alle VM-Done-Flags -> Host patcht selbst.

    Dieses Skript vereint Snapshot-Erstellung UND Warten auf die VM-Done-Flags
    in EINEM Lauf, damit es als einzelnes PRE-Skript in der NinjaOne
    OS-Patch-Policy des Hyper-V-Hosts eingetragen werden kann.

.AENDERUNG GEGENUEBER VORVERSION
    - NAS-Zugriff jetzt ueber cmdkey.exe + direkten UNC-Pfad (wie im bewaehrten
      Veeam-Backup-Skript), statt ueber New-PSDrive "FlagShare:". Das war die
      Ursache, warum Snapshot-Flags trotz erfolgreichem Checkpoint nicht
      geschrieben wurden.
    - Jeder Flag-Write wird per Test-Path verifiziert -> Fehler werden sofort
      sichtbar statt "still" zu verschwinden.
    - Eigenes, separates Logfile (HostPreKombiniert-log-<Datum>.txt).

    Reihenfolge im Skript:
    1. Warten, bis das Veeam-Backup-Flag (von der BackupVM) vorhanden ist.
    2. Snapshots fuer alle VMs aus ExpectedVmList erstellen, pro VM ein
       SnapshotReady-Flag ablegen.
    3. Warten, bis alle VMs (inkl. Backup01, falls in HostExpectedVmList)
       ihr Done-Flag nach Update+Reboot abgelegt haben.
    4. Erst danach exit 0 -> NinjaOne gibt das OS-Patching des Hosts frei.

.CUSTOM FIELDS (Geraet: Hyper-V-Host)
    ExpectedVmList          (Text) - VMs, die einen Snapshot bekommen sollen
    HostExpectedVmList      (Text) - VMs (inkl. ggf. Backup01), auf deren
                                     Done-Flag der Host warten soll
    FlagFolder              (Text) - UNC-Pfad zum Flag-Share
    LogFolder               (Text) - UNC-Pfad zum Log-Ordner (optional, sonst = FlagFolder)
    NasUser / NasPassword   (Text) - Zugangsdaten fuer den Flag-Share
    VeeamFlagName           (Text) - Basisname des Veeam-Erfolgs-Flags,
                                     Default "VeeamBackup"
    VmDoneFlagPrefix        (Text) - Praefix der VM-Done-Flags,
                                     Default "VmUpdateDone"
    SnapshotPrefix          (Text) - Praefix fuer Checkpoint-Namen,
                                     Default "AutoPatch"
    SnapshotRetentionDays   (Text) - Alte Checkpoints aelter als X Tage
                                     werden bereinigt, Default 3
    HostWaitBackupMaxMinutes(Text) - Max. Wartezeit auf Veeam-Flag,
                                     Default 240
    HostWaitVmMaxMinutes    (Text) - Max. Wartezeit auf VM-Done-Flags,
                                     Default 240
    HostWaitPollSeconds     (Text) - Abfrageintervall Sekunden, Default 60
#>

param(
    [string]$FlagFolderOverride = "",
    [string]$LogFolderOverride = "",
    [int]$PollSecondsOverride = 0
)

function Get-NinjaField {
    param([string]$FieldName)
    try { return (Ninja-Property-Get $FieldName) } catch { return $null }
}

$FlagFolder = if ($FlagFolderOverride) { $FlagFolderOverride } else { Get-NinjaField "flagFolder" }
$LogFolder  = if ($LogFolderOverride) { $LogFolderOverride } elseif (Get-NinjaField "logFolder") { Get-NinjaField "logFolder" } else { $FlagFolder }
$NasUser = Get-NinjaField "nasUser"
$NasPassword = Get-NinjaField "nasPassword"
$ExpectedVmListRaw = Get-NinjaField "expectedVmList"
$HostExpectedVmListRaw = Get-NinjaField "hostExpectedVmList"
if (-not $HostExpectedVmListRaw) { $HostExpectedVmListRaw = $ExpectedVmListRaw }
$VeeamFlagName = if (Get-NinjaField "veeamFlagName") { Get-NinjaField "veeamFlagName" } else { "VeeamBackup" }
$VmDoneFlagPrefix = if (Get-NinjaField "vmDoneFlagPrefix") { Get-NinjaField "vmDoneFlagPrefix" } else { "VmUpdateDone" }
$SnapshotPrefix = if (Get-NinjaField "snapshotPrefix") { Get-NinjaField "snapshotPrefix" } else { "AutoPatch" }
$SnapshotRetentionDays = if (Get-NinjaField "snapshotRetentionDays") { [int](Get-NinjaField "snapshotRetentionDays") } else { 3 }
$BackupMaxWaitMinutes = if (Get-NinjaField "hostWaitBackupMaxMinutes") { [int](Get-NinjaField "hostWaitBackupMaxMinutes") } else { 240 }
$VmMaxWaitMinutes = if (Get-NinjaField "hostWaitVmMaxMinutes") { [int](Get-NinjaField "hostWaitVmMaxMinutes") } else { 240 }
$PollSeconds = if ($PollSecondsOverride -gt 0) { $PollSecondsOverride } elseif (Get-NinjaField "hostWaitPollSeconds") { [int](Get-NinjaField "hostWaitPollSeconds") } else { 60 }

$Today = (Get-Date).ToString("yyyyMMdd")
$logFile = Join-Path $LogFolder "HostPreKombiniert-log-$Today.txt"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] [HOST-PRE-KOMBINIERT] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
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

function Wait-ForAllVmDoneFlags {
    param([string[]]$VmNames, [string]$FlagFolder, [string]$FlagPrefix, [int]$MaxWaitMinutes, [int]$PollSeconds)
    $Deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
    $Today = (Get-Date).ToString("yyyyMMdd")
    $Pending = [System.Collections.Generic.List[string]]::new($VmNames)

    while ($Pending.Count -gt 0) {
        if ((Get-Date) -gt $Deadline) {
            throw "Timeout nach $MaxWaitMinutes Minuten. Noch offen: $($Pending -join ', ')"
        }
        $StillPending = [System.Collections.Generic.List[string]]::new()
        foreach ($VmName in $Pending) {
            $FlagPath = Join-Path $FlagFolder "$FlagPrefix`_$VmName`_$Today.flag"
            if (-not (Test-Path $FlagPath)) { $StillPending.Add($VmName) }
        }
        $Pending = $StillPending
        if ($Pending.Count -gt 0) {
            Write-Log "Warte weiter auf VM-Done-Flags: $($Pending -join ', ') ..."
            Start-Sleep -Seconds $PollSeconds
        }
    }
    Write-Log "Alle erwarteten VM-Done-Flags sind vorhanden."
}

try {
    Write-Log "=== Start Vorschlag 1: Hyper-V Host Pre (Backup-Warten -> Snapshot -> VM-Warten) ==="

    if (-not $FlagFolder -or -not $ExpectedVmListRaw -or -not $HostExpectedVmListRaw) {
        throw "FlagFolder, ExpectedVmList oder HostExpectedVmList ist nicht gesetzt."
    }

    $VmListSnapshot = $ExpectedVmListRaw -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    $VmListWait = $HostExpectedVmListRaw -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    Connect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser -Password $NasPassword
    if (-not (Test-Path $FlagFolder)) { throw "Flag-Pfad nicht erreichbar: $FlagFolder" }

    # Schritt 1: Warten auf Veeam-Backup-Erfolgsflag
    $VeeamFlagPath = Join-Path $FlagFolder "$VeeamFlagName`_Success_$Today.flag"
    Wait-ForFlag -FlagPath $VeeamFlagPath -MaxWaitMinutes $BackupMaxWaitMinutes -PollSeconds $PollSeconds -Description "Veeam-Backup-Erfolgsflag"

    # Schritt 2: Snapshots erstellen
    Write-Log "Erstelle Snapshots fuer: $($VmListSnapshot -join ', ')"
    foreach ($VmName in $VmListSnapshot) {
        $Vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
        if (-not $Vm) {
            Write-Log "WARNUNG: VM '$VmName' nicht auf diesem Host gefunden, wird uebersprungen."
            continue
        }

        $OldSnaps = Get-VMSnapshot -VMName $VmName -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$SnapshotPrefix*" -and $_.CreationTime -lt (Get-Date).AddDays(-$SnapshotRetentionDays) }
        foreach ($Snap in $OldSnaps) {
            Write-Log "Entferne alten Checkpoint '$($Snap.Name)' von VM '$VmName'."
            Remove-VMSnapshot -VMSnapshot $Snap -Confirm:$false -ErrorAction SilentlyContinue
        }

        $CheckpointName = "$SnapshotPrefix-$VmName-$Today"
        try {
            Checkpoint-VM -Name $VmName -SnapshotName $CheckpointName -ErrorAction Stop
            Write-Log "Checkpoint fuer '$VmName' erfolgreich erstellt."

            $ReadyFlagFile = Join-Path $FlagFolder "SnapshotReady_$($VmName)_$Today.flag"
            Set-Content -Path $ReadyFlagFile -Value (Get-Date).ToString("o") -Encoding UTF8 -Force
            if (-not (Test-Path $ReadyFlagFile)) { throw "Flag-Datei konnte nicht bestaetigt werden: $ReadyFlagFile" }
            Write-Log "SnapshotReady-Flag fuer '$VmName' abgelegt: $ReadyFlagFile"
        } catch {
            Write-Log "FEHLER beim Snapshot/Flag von '$VmName': $($_.Exception.Message)"
            throw "Snapshot/Flag fuer $VmName fehlgeschlagen - Abbruch, damit keine VM ohne Snapshot patcht."
        }
    }

    # Schritt 3: Warten auf alle VM-Done-Flags
    Write-Log "Warte auf Done-Flags von: $($VmListWait -join ', ')"
    Wait-ForAllVmDoneFlags -VmNames $VmListWait -FlagFolder $FlagFolder -FlagPrefix $VmDoneFlagPrefix -MaxWaitMinutes $VmMaxWaitMinutes -PollSeconds $PollSeconds

    Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser
    Write-Log "=== Ende Vorschlag 1 Host-Pre (Erfolg) - OS-Patch auf Host wird freigegeben ==="
    exit 0
}
catch {
    Write-Log "FEHLER: $($_.Exception.Message)"
    Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser
    Write-Error $_.Exception.Message
    exit 1
}
