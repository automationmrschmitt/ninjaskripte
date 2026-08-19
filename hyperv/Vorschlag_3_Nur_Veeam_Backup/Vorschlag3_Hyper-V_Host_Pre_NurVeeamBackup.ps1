<#
.SYNOPSIS
    VORSCHLAG 3 - Hyper-V Host PRE-Skript (nur Veeam-Backup als Gate,
    KEIN Snapshot). Ablauf: BackupVM macht Veeam-Vollbackup, legt danach
    ihr Erfolgs-Flag ab -> ALLE VMs (inkl. Backup-VM selbst) warten auf
    dieses eine Flag und updaten dann parallel -> Host wartet auf alle
    VM-Done-Flags -> Host patcht zuletzt.

    Dieses Skript auf dem Host prueft/erstellt KEINEN Snapshot. Es wartet
    nur, bis alle erwarteten VMs (die Liste sollte hier typischerweise
    auch die Backup-VM selbst enthalten) ihr Done-Flag gesetzt haben.

    WICHTIG: Ohne Snapshot gibt es kein schnelles Rollback direkt nach dem
    Update - im Fehlerfall muss aus dem Veeam-Backup vollstaendig
    wiederhergestellt werden (deutlich laenger als ein Snapshot-Revert).

.CUSTOM FIELDS (Geraet: Hyper-V-Host)
    HostExpectedVmList      (Text) - VMs (inkl. Backup-VM), auf deren
                                     Done-Flag der Host warten soll
    FlagFolder              (Text) - UNC-Pfad zum Flag-Share
    NasUser / NasPassword   (Text) - Zugangsdaten fuer den Flag-Share
    VmDoneFlagPrefix        (Text) - Praefix der VM-Done-Flags,
                                     Default "VmUpdateDone"
    HostWaitVmMaxMinutes    (Text) - Max. Wartezeit auf VM-Done-Flags,
                                     Default 240
    HostWaitPollSeconds     (Text) - Abfrageintervall Sekunden, Default 60

.HINWEIS
    Das Veeam-Backup selbst laeuft weiterhin ausschliesslich ueber das
    bestehende Backup-VM-Skript ("VeeamBackupMitFlag") - dieses Host-Skript
    hier startet KEIN Backup, es wartet nur auf die VM-Done-Flags, analog
    zu Hyper-V_Host_Wait_Pre.ps1, nur ohne den vorgeschalteten
    Snapshot-Schritt.
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
            if (Test-Path $FlagPath) {
                Write-Log "Flag fuer '$VmName' gefunden."
            } else {
                $StillPending.Add($VmName)
            }
        }
        $Pending = $StillPending
        if ($Pending.Count -gt 0) {
            Write-Log "Warte weiter auf: $($Pending -join ', ') ..."
            Start-Sleep -Seconds $PollSeconds
        }
    }
    Write-Log "Alle erwarteten VM-Done-Flags sind vorhanden."
}

try {
    Write-Log "=== Start Vorschlag 3: Hyper-V Host Pre (nur Veeam-Backup, kein Snapshot) ==="

    $FlagFolder = if ($FlagFolderOverride) { $FlagFolderOverride } else { Get-NinjaField "flagFolder" }
    $NasUser = Get-NinjaField "nasUser"
    $NasPassword = Get-NinjaField "nasPassword"
    $HostExpectedVmListRaw = Get-NinjaField "hostExpectedVmList"
    if (-not $HostExpectedVmListRaw) { $HostExpectedVmListRaw = Get-NinjaField "expectedVmList" }
    $VmDoneFlagPrefix = if (Get-NinjaField "vmDoneFlagPrefix") { Get-NinjaField "vmDoneFlagPrefix" } else { "VmUpdateDone" }
    $MaxWaitMinutes = if ($MaxWaitMinutesOverride -gt 0) { $MaxWaitMinutesOverride } elseif (Get-NinjaField "hostWaitVmMaxMinutes") { [int](Get-NinjaField "hostWaitVmMaxMinutes") } else { 240 }
    $PollSeconds = if ($PollSecondsOverride -gt 0) { $PollSecondsOverride } elseif (Get-NinjaField "hostWaitPollSeconds") { [int](Get-NinjaField "hostWaitPollSeconds") } else { 60 }

    if (-not $FlagFolder -or -not $HostExpectedVmListRaw) {
        throw "FlagFolder oder HostExpectedVmList/ExpectedVmList ist nicht gesetzt."
    }

    $VmList = $HostExpectedVmListRaw -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    Write-Log "Host wartet auf Done-Flags von (inkl. Backup-VM): $($VmList -join ', ')"

    Connect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser -Password $NasPassword

    Wait-ForAllVmDoneFlags -VmNames $VmList -FlagFolder "FlagShare:\" -FlagPrefix $VmDoneFlagPrefix -MaxWaitMinutes $MaxWaitMinutes -PollSeconds $PollSeconds

    Disconnect-NasFlagShare
    Write-Log "=== Ende Vorschlag 3 Host-Pre (Erfolg) - OS-Patch auf Host wird freigegeben ==="
    exit 0
}
catch {
    Write-Log "FEHLER: $($_.Exception.Message)"
    Disconnect-NasFlagShare
    Write-Error $_.Exception.Message
    exit 1
}
