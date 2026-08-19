<#
.SYNOPSIS
    VM-Policy POST-Skript (SystemUpdateInstall_Post.ps1)
    Prueft NACH dem NinjaOne-Patch-Vorgang per LastBootUpTime, ob wirklich ein
    neuer Reboot stattgefunden hat, BEVOR die Done-Flag fuer den Backup-Server
    geschrieben wird. Verhindert, dass eine zu frueh gesetzte Flag den
    Backup-Server faelschlich glauben laesst, alle VMs seien bereits fertig.

    Beruecksichtigt zusaetzlich den Fall, dass gar kein Reboot notwendig war
    (z.B. reine Definitionsupdates) - dann wird ueber Pending-Reboot-Check
    sofort erkannt, dass kein Neustart mehr ausstehend ist.

    Passt zur Namenskonvention des Veeam-Skripts (Wait-ForAllVmDoneFlags):
    "<VmDoneFlagPrefix>_<ComputerName>_<yyyyMMdd>.flag"

.PARAMETER VmDoneFlagPrefix
    Muss zum VmDoneFlagPrefix des Veeam-Skripts passen. Default: "VmUpdateDone"

.PARAMETER FlagFolder
    Pfad zur Flag-Ablage (NAS/UNC), identisch zum Veeam-Skript.

.PARAMETER MaxWaitMinutes
    Falls der Reboot durch NinjaOne noch nicht erfolgt ist, wartet das Skript
    intern kurz nach, statt die Flag sofort (und faelschlich) zu setzen.

.PARAMETER PollSeconds
    Abfrageintervall waehrend der Reboot-Nachpruefung.

.NOTES
    Custom-Field-Bezug (Multi-Kunden, wie im Veeam-Skript):
      - VmDoneFlagPrefix <- Org Custom Field "vmDoneFlagPrefix"
      - FlagFolder       <- Org Custom Field "flagFolder"
      - NasUser/Password <- Org Custom Field "nasUser" / "nasPassword" (SECURE)

    Erwartet, dass SystemUpdateInstall_Pre.ps1 zuvor "update_started.txt"
    lokal geschrieben hat (im ISO-Format via ToString("o")). Ohne diese Datei
    kann kein Reboot verifiziert werden -> Skript bricht bewusst mit Fehler ab
    (kein "blindes" Flag-Setzen).
    
    Das Skript verfügt über ein Start Delay, und wartet 5.Min damit alle Dienste geladen sind.
#>

param(
    [string]$VmDoneFlagPrefix = "VmUpdateDone",
    [string]$FlagFolder       = "",
    [int]$MaxWaitMinutes      = 30,
    [int]$PollSeconds         = 30,
    [string]$NasUser          = "",
    [string]$NasPassword      = "",
    [string]$LocalStateDir    = "C:\ProgramData\PatchAutomation",
    [int]$StartupDelaySeconds = 300
)



function Get-NinjaOrDefault {
    param([string]$CurrentValue, [string]$FieldName)
    if (-not (Get-Command Ninja-Property-Get -ErrorAction SilentlyContinue)) { return $CurrentValue }
    try {
        $fieldValue = Ninja-Property-Get -Name $FieldName -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($fieldValue)) { return $fieldValue }
    } catch { }
    return $CurrentValue
}

if ($VmDoneFlagPrefix -eq "VmUpdateDone")   { $VmDoneFlagPrefix = Get-NinjaOrDefault -CurrentValue $VmDoneFlagPrefix -FieldName "vmDoneFlagPrefix" }
if ($FlagFolder        -eq "") { $FlagFolder    = Get-NinjaOrDefault -CurrentValue $FlagFolder        -FieldName "flagFolder" }
if ([string]::IsNullOrWhiteSpace($NasUser))     { $NasUser     = Get-NinjaOrDefault -CurrentValue $NasUser     -FieldName "nasUser" }
if ([string]::IsNullOrWhiteSpace($NasPassword)) { $NasPassword = Get-NinjaOrDefault -CurrentValue $NasPassword -FieldName "nasPassword" }

$today           = Get-Date -Format "yyyyMMdd"
$computerName    = $env:COMPUTERNAME
$flagFile        = Join-Path $FlagFolder "$VmDoneFlagPrefix`_$computerName`_$today.flag"
$updateStartFile = Join-Path $LocalStateDir "update_started.txt"
$logFile         = Join-Path $LocalStateDir "vm_post_$today.log"

New-Item -ItemType Directory -Path $LocalStateDir -Force -ErrorAction SilentlyContinue | Out-Null

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
    Write-Output $line
}
 Write-Log "Warte $StartupDelaySeconds Sekunden nach Systemstart, damit Netzwerk/NAS sicher verfuegbar sind..."
 Start-Sleep -Seconds $StartupDelaySeconds


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
    if (-not (Test-Path $UncPath)) { throw "NAS-Anmeldung gesetzt, aber $UncPath nicht erreichbar." }
}

function Disconnect-NasFlagShare {
    param([string]$UncPath, [string]$UserName)
    if ([string]::IsNullOrWhiteSpace($UserName)) { return }
    $server = Get-NasServerPath -UncPath $UncPath
    $null = cmdkey.exe /delete:$($server.TrimStart('\')) 2>$null
}

function Test-PendingReboot {
    # Prueft bekannte Windows-Indikatoren fuer einen noch ausstehenden Reboot.
    # Wenn KEINER dieser Indikatoren gesetzt ist, ist kein Neustart erforderlich
    # (z.B. bei reinen Definitionsupdates oder Patches ohne Reboot-Anforderung).
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $true }
    }
    return $false
}

try {
    Write-Log "=== Start VM-Post fuer $computerName ==="

    if (-not (Test-Path $updateStartFile)) {
        throw "update_started.txt nicht gefunden - Reboot kann nicht verifiziert werden. Flag wird NICHT gesetzt."
    }

    $rawContent = Get-Content $updateStartFile -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($rawContent)) {
        throw "update_started.txt ist leer oder nicht vorhanden ($updateStartFile). Pre-Skript wurde vermutlich nicht korrekt ausgefuehrt."
    }

    try {
        $updateStart = [DateTime]::Parse($rawContent, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        throw "update_started.txt enthaelt kein gueltiges ISO-DateTime ('$rawContent'). Pre-Skript muss ToString('o') verwenden."
    }

    $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
    Write-Log "Update-Start war: $updateStart. Pruefe Reboot-Status (Timeout: $MaxWaitMinutes min)..."

    $rebootConfirmed = $false
    while ((Get-Date) -le $deadline) {
        $lastBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $pending  = Test-PendingReboot

        if ($lastBoot -gt $updateStart) {
            Write-Log "Reboot bestaetigt (LastBoot: $lastBoot)."
            $rebootConfirmed = $true
            break
        }
        elseif (-not $pending) {
            Write-Log "Kein Reboot erforderlich (kein Pending-Reboot-Flag gesetzt). Update ohne Neustart abgeschlossen."
            $rebootConfirmed = $true
            break
        }

        Write-Log "Reboot steht noch aus (Pending: $pending, LastBoot: $lastBoot). Warte $PollSeconds s..."
        Start-Sleep -Seconds $PollSeconds
    }

    if (-not $rebootConfirmed) {
        throw "TIMEOUT: Weder Reboot bestaetigt noch Pending-Reboot-Flag geloescht nach $MaxWaitMinutes Minuten. Flag wird NICHT gesetzt - moeglicher Loop-Fall!"
    }

    Connect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser -Password $NasPassword
    if (-not (Test-Path $FlagFolder)) { throw "Flag-Pfad nicht erreichbar: $FlagFolder" }

    Set-Content -Path $flagFile -Value "VM Update+Reboot OK: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Encoding UTF8
    if (-not (Test-Path $flagFile)) { throw "Done-Flag konnte nicht bestaetigt werden: $flagFile" }

    Write-Log "Done-Flag geschrieben: $flagFile"
    Remove-Item $updateStartFile -Force -ErrorAction SilentlyContinue

    Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser
    Write-Log "=== Ende VM-Post (Erfolg) ==="
    exit 0
}
catch {
    Write-Log "FEHLER: $($_.Exception.Message)"
    Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser
    Write-Error $_.Exception.Message
    exit 1
}