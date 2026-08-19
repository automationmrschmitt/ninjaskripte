<#
.SYNOPSIS
    Hyper-V Host Post-Skript (Hyper-V_Host_Cleanup_Post.ps1) - BESTEHEND,
    gilt fuer ALLE DREI Vorschlaege unveraendert. Als POST-Skript in der
    NinjaOne OS-Patch-Policy des Hyper-V-HOSTS hinterlegen. Prueft per
    LastBootUpTime, ob der Host wirklich neu gestartet wurde, und bereinigt
    danach den kompletten Flag-Ordner fuer den heutigen Lauf (Snapshot-Ready-
    Flags UND VM-Done-Flags), damit der naechste Patch-Zyklus wieder mit
    einem leeren Ordner startet.

.CUSTOM FIELDS (Geraet: Hyper-V-Host)
    FlagFolder             (Text)  - UNC-Pfad zum Flag-Share
    NasUser / NasPassword  (Text)  - Zugangsdaten fuer den Flag-Share
    HostRebootMaxWaitMinutes (Text) - Max. Wartezeit auf Reboot-
                                       Bestaetigung, Default = 30
#>

param(
    [string]$FlagFolderOverride = "",
    [int]$MaxWaitMinutesOverride = 0
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

function Test-PendingReboot {
    $Key1 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
    $Key2 = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    return (Test-Path $Key1) -or (Test-Path $Key2)
}

try {
    Write-Log "=== Start Hyper-V Host Cleanup-Post ==="

    $FlagFolder = if ($FlagFolderOverride) { $FlagFolderOverride } else { Get-NinjaField "flagFolder" }
    $NasUser = Get-NinjaField "nasUser"
    $NasPassword = Get-NinjaField "nasPassword"
    $MaxWaitMinutes = if ($MaxWaitMinutesOverride -gt 0) { $MaxWaitMinutesOverride } elseif (Get-NinjaField "hostRebootMaxWaitMinutes") { [int](Get-NinjaField "hostRebootMaxWaitMinutes") } else { 30 }

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
            Write-Log "Kein Reboot ausstehend und keiner nötig - werte als erfolgreich abgeschlossen."
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

    $Today = (Get-Date).ToString("yyyyMMdd")
    $FilesToClean = Get-ChildItem -Path "FlagShare:\" -Filter "*_$Today.flag" -ErrorAction SilentlyContinue
    foreach ($File in $FilesToClean) {
        Remove-Item $File.FullName -Force -ErrorAction SilentlyContinue
        Write-Log "Flag entfernt: $($File.Name)"
    }

    Remove-Item $UpdateStartFile -Force -ErrorAction SilentlyContinue
    Disconnect-NasFlagShare
    Write-Log "=== Ende Hyper-V Host Cleanup-Post (Erfolg) ==="
    exit 0
}
catch {
    Write-Log "FEHLER: $($_.Exception.Message)"
    Disconnect-NasFlagShare
    Write-Error $_.Exception.Message
    exit 1
}
