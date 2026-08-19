<#
.SYNOPSIS
    VORSCHLAG 2 - VM PRE-Skript (nur Snapshot, kein Veeam-Backup)
    Laeuft auf JEDER Gast-VM. Wartet NUR auf das SnapshotReady-Flag
    des Hyper-V-Hosts fuer diese VM, bevor NinjaOne das OS-Patching
    freigibt. Kein Warten auf ein Veeam-Backup-Flag, da in diesem
    Vorschlag kein Backup gefahren wird.

.CUSTOM FIELDS (Geraet: jede VM)
    FlagFolder              (Text) - UNC-Pfad zum Flag-Share
    NasUser / NasPassword   (Text) - Zugangsdaten fuer den Flag-Share
    VmWaitMaxMinutes        (Text) - Max. Wartezeit, Default 240
    VmWaitPollSeconds       (Text) - Abfrageintervall Sekunden, Default 30

.HINWEIS
    Nutzt automatisch den lokalen Computernamen (hostname).
    Legt "C:\Temp\update_started.txt" an fuer die Reboot-Verifikation
    im zugehoerigen VM-Post-Skript.
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
    Write-Log "=== Start Vorschlag 2: VM Pre (nur Snapshot-Warten) ==="

    $ComputerName = $env:COMPUTERNAME
    $FlagFolder = if ($FlagFolderOverride) { $FlagFolderOverride } else { Get-NinjaField "flagFolder" }
    $NasUser = Get-NinjaField "nasUser"
    $NasPassword = Get-NinjaField "nasPassword"
    $MaxWaitMinutes = if ($MaxWaitMinutesOverride -gt 0) { $MaxWaitMinutesOverride } elseif (Get-NinjaField "vmWaitMaxMinutes") { [int](Get-NinjaField "vmWaitMaxMinutes") } else { 240 }
    $PollSeconds = if ($PollSecondsOverride -gt 0) { $PollSecondsOverride } elseif (Get-NinjaField "vmWaitPollSeconds") { [int](Get-NinjaField "vmWaitPollSeconds") } else { 30 }

    if (-not $FlagFolder) { throw "FlagFolder ist nicht gesetzt." }

    $Today = (Get-Date).ToString("yyyyMMdd")
    Connect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser -Password $NasPassword

    $SnapshotFlagPath = Join-Path "FlagShare:\" "SnapshotReady_$ComputerName`_$Today.flag"
    Wait-ForFlag -FlagPath $SnapshotFlagPath -MaxWaitMinutes $MaxWaitMinutes -PollSeconds $PollSeconds -Description "Snapshot-Ready-Flag fuer $ComputerName"

    Disconnect-NasFlagShare

    if (-not (Test-Path "C:\Temp")) { New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null }
    (Get-Date).ToString("o") | Set-Content -Path "C:\Temp\update_started.txt" -Force

    Write-Log "=== Ende Vorschlag 2 VM-Pre (Erfolg) - Update auf $ComputerName wird freigegeben ==="
    exit 0
}
catch {
    Write-Log "FEHLER: $($_.Exception.Message)"
    Disconnect-NasFlagShare
    Write-Error $_.Exception.Message
    exit 1
}
