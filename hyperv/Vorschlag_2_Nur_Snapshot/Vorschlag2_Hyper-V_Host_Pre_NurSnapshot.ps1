<#
.SYNOPSIS
    VORSCHLAG 2 - Hyper-V Host PRE-Skript (nur Snapshot, KEIN Veeam-Backup)
    Ablauf: Host erstellt sofort Snapshots aller VMs und legt pro VM ein
    SnapshotReady-Flag ab -> VMs warten NUR auf dieses Flag (kein Veeam-Flag
    noetig, da hier auf ein Backup verzichtet wird) -> VMs updaten -> Host
    wartet auf alle VM-Done-Flags -> Host patcht selbst.

    WICHTIG: In diesem Vorschlag entfaellt das Veeam-Backup komplett. Als
    einzige Absicherung dienen die Snapshots. Fuer Domain Controller wird
    davon ABGERATEN (USN-Rollback-Risiko bei Snapshot-Restore) - dort
    zusaetzlich ein separates Backup einplanen.

.CUSTOM FIELDS (Geraet: Hyper-V-Host)
    ExpectedVmList          (Text) - VMs, die einen Snapshot bekommen sollen
    HostExpectedVmList      (Text) - VMs, auf deren Done-Flag der Host warten
                                     soll (i.d.R. identisch zu ExpectedVmList)
    FlagFolder              (Text) - UNC-Pfad zum Flag-Share
    NasUser / NasPassword   (Text) - Zugangsdaten fuer den Flag-Share
    VmDoneFlagPrefix        (Text) - Praefix der VM-Done-Flags,
                                     Default "VmUpdateDone"
    SnapshotPrefix          (Text) - Praefix fuer Checkpoint-Namen,
                                     Default "AutoPatch"
    SnapshotRetentionDays   (Text) - Alte Checkpoints aelter als X Tage
                                     werden bereinigt, Default 3
    HostWaitVmMaxMinutes    (Text) - Max. Wartezeit auf VM-Done-Flags,
                                     Default 240
    HostWaitPollSeconds     (Text) - Abfrageintervall Sekunden, Default 60
#>

param(
    [string]$FlagFolderOverride = "",
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
    Write-Log "=== Start Vorschlag 2: Hyper-V Host Pre (nur Snapshot, kein Backup) ==="

    $FlagFolder = if ($FlagFolderOverride) { $FlagFolderOverride } else { Get-NinjaField "flagFolder" }
    $NasUser = Get-NinjaField "nasUser"
    $NasPassword = Get-NinjaField "nasPassword"
    $ExpectedVmListRaw = Get-NinjaField "expectedVmList"
    $HostExpectedVmListRaw = Get-NinjaField "hostExpectedVmList"
    if (-not $HostExpectedVmListRaw) { $HostExpectedVmListRaw = $ExpectedVmListRaw }
    $VmDoneFlagPrefix = if (Get-NinjaField "vmDoneFlagPrefix") { Get-NinjaField "vmDoneFlagPrefix" } else { "VmUpdateDone" }
    $SnapshotPrefix = if (Get-NinjaField "snapshotPrefix") { Get-NinjaField "snapshotPrefix" } else { "AutoPatch" }
    $SnapshotRetentionDays = if (Get-NinjaField "snapshotRetentionDays") { [int](Get-NinjaField "snapshotRetentionDays") } else { 3 }
    $VmMaxWaitMinutes = if (Get-NinjaField "hostWaitVmMaxMinutes") { [int](Get-NinjaField "hostWaitVmMaxMinutes") } else { 240 }
    $PollSeconds = if ($PollSecondsOverride -gt 0) { $PollSecondsOverride } elseif (Get-NinjaField "hostWaitPollSeconds") { [int](Get-NinjaField "hostWaitPollSeconds") } else { 60 }

    if (-not $FlagFolder -or -not $ExpectedVmListRaw -or -not $HostExpectedVmListRaw) {
        throw "FlagFolder, ExpectedVmList oder HostExpectedVmList ist nicht gesetzt."
    }

    $VmListSnapshot = $ExpectedVmListRaw -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    $VmListWait = $HostExpectedVmListRaw -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    $Today = (Get-Date).ToString("yyyyMMdd")

    Connect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser -Password $NasPassword

    # Schritt 1: Snapshots sofort erstellen (kein Warten auf Backup)
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
            $ReadyFlagFile = Join-Path "FlagShare:\" "SnapshotReady_$VmName`_$Today.flag"
            (Get-Date).ToString("o") | Set-Content -Path $ReadyFlagFile -Force
            Write-Log "SnapshotReady-Flag fuer '$VmName' abgelegt."
        } catch {
            Write-Log "FEHLER beim Snapshot von '$VmName': $($_.Exception.Message)"
            throw "Snapshot fuer $VmName fehlgeschlagen - Abbruch, da hier der Snapshot die EINZIGE Absicherung ist."
        }
    }

    # Schritt 2: Warten auf alle VM-Done-Flags
    Write-Log "Warte auf Done-Flags von: $($VmListWait -join ', ')"
    Wait-ForAllVmDoneFlags -VmNames $VmListWait -FlagFolder "FlagShare:\" -FlagPrefix $VmDoneFlagPrefix -MaxWaitMinutes $VmMaxWaitMinutes -PollSeconds $PollSeconds

    Disconnect-NasFlagShare
    Write-Log "=== Ende Vorschlag 2 Host-Pre (Erfolg) - OS-Patch auf Host wird freigegeben ==="
    exit 0
}
catch {
    Write-Log "FEHLER: $($_.Exception.Message)"
    Disconnect-NasFlagShare
    Write-Error $_.Exception.Message
    exit 1
}
