<#
.SYNOPSIS
    VM POST-Skript - gilt fuer ALLE DREI Vorschlaege identisch.
    Laeuft auf JEDER Gast-VM nach dem OS-Patching. Prueft per
    LastBootUpTime, ob die VM seit dem in "update_started.txt"
    hinterlegten Zeitpunkt tatsaechlich neu gestartet wurde (oder kein
    Reboot noetig war), und legt danach das Done-Flag fuer diese VM ab,
    auf das der Hyper-V-Host wartet.

.CUSTOM FIELDS (Geraet: jede VM)
    FlagFolder                (Text) - UNC-Pfad zum Flag-Share
    NasUser / NasPassword     (Text) - Zugangsdaten fuer den Flag-Share
    VmDoneFlagPrefix          (Text) - Praefix, Default "VmUpdateDone"
    VmRebootMaxWaitMinutes    (Text) - Max. Wartezeit auf Reboot-Bestaetigung,
                                       Default 30
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
    Write-Log "=== Start VM Post (gilt fuer alle drei Vorschlaege) ==="

    $ComputerName = $env:COMPUTERNAME
    $FlagFolder = if ($FlagFolderOverride) { $FlagFolderOverride } else { Get-NinjaField "flagFolder" }
    $NasUser = Get-NinjaField "nasUser"
    $NasPassword = Get-NinjaField "nasPassword"
    $VmDoneFlagPrefix = if (Get-NinjaField "vmDoneFlagPrefix") { Get-NinjaField "vmDoneFlagPrefix" } else { "VmUpdateDone" }
    $MaxWaitMinutes = if ($MaxWaitMinutesOverride -gt 0) { $MaxWaitMinutesOverride } elseif (Get-NinjaField "vmRebootMaxWaitMinutes") { [int](Get-NinjaField "vmRebootMaxWaitMinutes") } else { 30 }

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

    $Today = (Get-Date).ToString("yyyyMMdd")
    Connect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser -Password $NasPassword

    $DoneFlagPath = Join-Path "FlagShare:\" "$VmDoneFlagPrefix`_$ComputerName`_$Today.flag"
    (Get-Date).ToString("o") | Set-Content -Path $DoneFlagPath -Force
    Write-Log "Done-Flag fuer $ComputerName abgelegt: $DoneFlagPath"

    Remove-Item $UpdateStartFile -Force -ErrorAction SilentlyContinue
    Disconnect-NasFlagShare
    Write-Log "=== Ende VM Post (Erfolg) fuer $ComputerName ==="
    exit 0
}
catch {
    Write-Log "FEHLER: $($_.Exception.Message)"
    Disconnect-NasFlagShare
    Write-Error $_.Exception.Message
    exit 1
}
