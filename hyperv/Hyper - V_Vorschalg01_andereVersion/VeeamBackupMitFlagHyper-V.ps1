<#
.SYNOPSIS
    Veeam Backup Job starten, ueberwachen, Ergebnis loggen, Flag-Datei setzen
    UND anschliessend im selben Lauf auf die Rueckmeldung ("VM_Done"-Flags) der
    anderen VMs warten, bevor das Skript erfolgreich endet.

    Dadurch haelt NinjaOne das OS-Patching auf dem Backup-Server selbst so lange
    "on hold", bis wirklich ALLE VMs ihr Update+Reboot abgeschlossen haben -
    obwohl die Backup-Flag fuer die anderen VMs schon viel frueher gesetzt wurde.
    Das verhindert das Szenario: Backup fertig -> Flag gesetzt -> Skript endet ->
    NinjaOne patcht sofort den Backup-Server UND alle VMs patchen gleichzeitig ->
    ggf. alle Server gleichzeitig im Reboot, keine VM erreichbar.

.AENDERUNG (v2)
    - NEU: Unmittelbar bevor dieses Skript erfolgreich mit exit 0 endet (d.h.
      unmittelbar bevor NinjaOne das OS-Patching auf dieser Backup-VM startet),
      wird "C:\Temp\update_started.txt" mit dem aktuellen Zeitstempel angelegt -
      exakt wie es das normale VM-Pre-Skript auf den anderen Gast-VMs tut.
      Grund: Das gemeinsame VM-Post-Skript (VM_Post_AllVorschlaege.ps1), das
      auch auf dieser Backup-VM als POST-Skript laeuft, benoetigt diese Datei,
      um per LastBootUpTime zu pruefen, ob seit Update-Start ein Reboot
      stattgefunden hat. Ohne diese Zeile bricht das VM-Post-Skript auf der
      Backup-VM IMMER mit "update_started.txt nicht gefunden" ab, und das
      Done-Flag der Backup-VM wird nie gesetzt -> Host wartet ewig.

.PARAMETER JobName
    Name des Veeam Backup Jobs (in Veeam B&R).

.PARAMETER FlagName
    Basisname fuer die Flag-Datei, die die VM-Pre-Skripte abfragen (-WaitForFlags).
    Default: "VeeamBackup" -> Datei "VeeamBackup_Success_<yyyyMMdd>.flag"

.PARAMETER VmDoneFlagPrefix
    Praefix der Flag-Dateien, die die VMs NACH ihrem Update+Reboot ablegen
    (siehe SystemUpdateInstall.ps1 / VM-Post-Skript). Erwartetes Muster:
    "<VmDoneFlagPrefix>_<ComputerName>_<yyyyMMdd>.flag"

.PARAMETER ExpectedVmList
    Kommagetrennte Liste der Computernamen, die nach dem Backup patchen und
    deren "Done"-Flag abgewartet werden muss, bevor der Backup-Server selbst
    patchen darf. Kann leer bleiben -> dann wird aus Org Custom Field
    "expectedVmList" gelesen.

.PARAMETER WaitForVmsTimeoutHours
    Maximale Wartezeit auf die VM-Done-Flags, nachdem das Backup selbst
    erfolgreich war. Bei Ueberschreitung: Exit 1 -> OS-Patching auf dem
    Backup-Server bleibt in NinjaOne "on hold".

.PARAMETER FlagFolder
    Pfad zur Flag/Log-Ablage (NAS/UNC).

.PARAMETER LogFolder
    Ablageort fuer ausfuehrliches Logfile.

.PARAMETER RetentionDays
    Wie viele Tage alte Flag/Log-Dateien aufgehoben werden.

.PARAMETER PollSeconds
    Intervall der Statusabfrage waehrend Backup UND VM-Warteschleife.

.PARAMETER TimeoutHours
    Maximale Laufzeit des Backups selbst, bevor abgebrochen wird.

.PARAMETER Mode
    "Run"   = Backup starten, ueberwachen, Flag setzen, auf VMs warten
    "Check" = nur pruefen, ob Backup-Flag fuer heute existiert (separate Policy)

.PARAMETER NasUser / NasPassword
    Dedizierter NAS-Zugang fuer den Flag-Ordner. NasPassword IMMER als
    Secure Custom Field / Secure Parameter in NinjaOne hinterlegen.

.NOTES
    Multi-Kunden-Betrieb ueber Custom Fields (siehe Get-NinjaOrDefault):
      - JobName          <- Device Custom Field "veeamJobName"
      - FlagName         <- Device Custom Field "veeamFlagName"
      - VmDoneFlagPrefix <- Org Custom Field    "vmDoneFlagPrefix" (Default "VmUpdateDone")
      - ExpectedVmList   <- Org Custom Field    "expectedVmList"   (kommagetrennt)
      - FlagFolder       <- Org Custom Field    "flagFolder"
      - LogFolder        <- Org Custom Field    "logFolder"
      - NasUser/Password <- Org Custom Field    "nasUser" / "nasPassword" (SECURE)

    ABLAUF IN NINJAONE:
    1. Backup-Policy PRE-Skript = dieses Skript (Mode Run).
       - Exit 0 wird erst zurueckgegeben, wenn Backup UND alle VM-Done-Flags da sind.
       - Solange das Skript laeuft/wartet, wird das OS-Patching des Backup-Servers
         durch NinjaOne NICHT gestartet (Policy-Verhalten: Patch-Job startet erst
         nach erfolgreichem Pre-Skript).
       - Exit 1 (Timeout oder Backup-Fehler) -> OS-Patching des Backup-Servers
         bleibt in NinjaOne "on hold" / wird abgebrochen.
    2. VM-Policy PRE-Skript (separat) wartet nur auf "<FlagName>_Success_<Datum>.flag".
    3. VM-Policy POST-Skript (separat) schreibt nach verifiziertem Reboot
       "<VmDoneFlagPrefix>_<ComputerName>_<Datum>.flag" - genau das, worauf
       dieses Skript hier wartet.
#>

param(
    [string]$JobName               = "",
    [string]$FlagName              = "VeeamBackup",
    [string]$VmDoneFlagPrefix      = "VmUpdateDone",
    [string]$ExpectedVmList        = "",
    [int]$WaitForVmsTimeoutHours   = 6,
    [string]$FlagFolder            = "",
    [string]$LogFolder             = "",
    [int]$RetentionDays            = 14,
    [int]$PollSeconds              = 30,
    [int]$TimeoutHours             = 12,
    [int]$CheckTimeoutHours        = 6,
    [ValidateSet("Run","Check")]
    [string]$Mode                  = "Run",
    [string]$NasUser               = "",
    [string]$NasPassword           = ""
)

function Get-VeeamMajorVersion {
    try {
        $regPath = "HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication"
        if (Test-Path $regPath) {
            $ver = (Get-ItemProperty -Path $regPath -Name "ProductVersion" -ErrorAction SilentlyContinue).ProductVersion
            if ($ver) { return [int]($ver -split '\.')[0] }
        }
        $exePath = "C:\Program Files\Veeam\Backup and Replication\Console\Veeam.Backup.Shell.exe"
        if (Test-Path $exePath) {
            $fileVer = (Get-Item $exePath).VersionInfo.FileVersion
            return [int]($fileVer -split '\.')[0]
        }
    } catch { }
    return $null
}

$veeamMajor = Get-VeeamMajorVersion
$currentPSMajor = $PSVersionTable.PSVersion.Major

if ($veeamMajor -ge 13 -and $currentPSMajor -lt 7) {
    $pwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"
    if (Test-Path $pwshPath) {
        & $pwshPath -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args
        exit $LASTEXITCODE
    } else {
        Write-Error "Veeam $veeamMajor benoetigt PowerShell 7, aber pwsh.exe wurde nicht gefunden."
        exit 1
    }
}

if ($veeamMajor -lt 13 -and $currentPSMajor -ge 7) {
    $ps5Path = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path $ps5Path) {
        & $ps5Path -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args
        exit $LASTEXITCODE
    } else {
        Write-Error "Veeam $veeamMajor benoetigt Windows PowerShell 5.1, aber powershell.exe wurde nicht gefunden."
        exit 1
    }
}

#if ($PSVersionTable.PSVersion.Major -lt 7) {
 #   $pwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"
 #   if (Test-Path $pwshPath) {
  #      & $pwshPath -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args
   #     exit $LASTEXITCODE
    #}
#}

function Get-NinjaOrDefault {
    param([string]$CurrentValue, [string]$FieldName)
    if (-not (Get-Command Ninja-Property-Get -ErrorAction SilentlyContinue)) { return $CurrentValue }
    try {
        $fieldValue = Ninja-Property-Get -Name $FieldName -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($fieldValue)) { return $fieldValue }
    } catch { }
    return $CurrentValue
}

if ($JobName          -eq "Backup Job daily to NAS01") { $JobName          = Get-NinjaOrDefault -CurrentValue $JobName          -FieldName "veeamJobName" }
if ($FlagName         -eq "VeeamBackup")                { $FlagName         = Get-NinjaOrDefault -CurrentValue $FlagName         -FieldName "veeamFlagName" }
if ($VmDoneFlagPrefix -eq "VmUpdateDone")               { $VmDoneFlagPrefix = Get-NinjaOrDefault -CurrentValue $VmDoneFlagPrefix -FieldName "vmDoneFlagPrefix" }
if ([string]::IsNullOrWhiteSpace($ExpectedVmList))      { $ExpectedVmList   = Get-NinjaOrDefault -CurrentValue $ExpectedVmList   -FieldName "expectedVmList" }
if ($FlagFolder       -eq "")           { $FlagFolder       = Get-NinjaOrDefault -CurrentValue $FlagFolder       -FieldName "flagFolder" }
if ($LogFolder        -eq "")      { $LogFolder        = Get-NinjaOrDefault -CurrentValue $LogFolder        -FieldName "logFolder" }
if ([string]::IsNullOrWhiteSpace($NasUser))             { $NasUser          = Get-NinjaOrDefault -CurrentValue $NasUser          -FieldName "nasUser" }
if ([string]::IsNullOrWhiteSpace($NasPassword))         { $NasPassword      = Get-NinjaOrDefault -CurrentValue $NasPassword      -FieldName "nasPassword" }

$today          = Get-Date -Format "yyyyMMdd"
$flagFile       = Join-Path $FlagFolder "$FlagName`_Success_$today.flag"
$logFile        = Join-Path $LogFolder  "backup-log-$today.txt"
$expectedName   = "$FlagName`_Success_$today.flag"
$flagFilter     = "$FlagName`_Success_*.flag"
$vmDoneFilter   = "$VmDoneFlagPrefix`_*_$today.flag"
$startTime      = Get-Date

$vmList = @()
if (-not [string]::IsNullOrWhiteSpace($ExpectedVmList)) {
    $vmList = $ExpectedVmList -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
}

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    try {
        if (-not (Test-Path $LogFolder)) { New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null }
        Add-Content -Path $logFile -Value $line -Encoding UTF8
    } catch { }
    Write-Output $line
}

function Cleanup-OldFiles {
    param([string]$Path, [string]$Filter)
    Get-ChildItem -Path $Path -Filter $Filter -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
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
}

function Disconnect-NasFlagShare {
    param([string]$UncPath, [string]$UserName)
    if ([string]::IsNullOrWhiteSpace($UserName)) { return }
    $server = Get-NasServerPath -UncPath $UncPath
    $null = cmdkey.exe /delete:$($server.TrimStart('\')) 2>$null
}

function Connect-VeeamModule {
    $loaded = $false
    if (Get-Module -ListAvailable -Name Veeam.Backup.PowerShell -ErrorAction SilentlyContinue) {
        try {
            Import-Module Veeam.Backup.PowerShell -ErrorAction Stop
            $loaded = $true
            Write-Log "Veeam-Modul geladen: Veeam.Backup.PowerShell"
        } catch {
            Write-Log "WARNUNG: Veeam.Backup.PowerShell gefunden, aber Import fehlgeschlagen: $($_.Exception.Message)"
        }
    }
    if (-not $loaded) {
        try {
            Add-PSSnapin VeeamPSSnapin -ErrorAction Stop
            $loaded = $true
            Write-Log "Veeam-PSSnapin geladen (Legacy-Modus, Veeam <=10/11)"
        } catch {
            Write-Log "WARNUNG: VeeamPSSnapin nicht verfuegbar: $($_.Exception.Message)"
        }
    }
    if (-not $loaded) { throw "Weder Veeam.Backup.PowerShell-Modul noch VeeamPSSnapin konnten geladen werden." }
}

function Wait-ForAllVmDoneFlags {
    param([string]$FlagFolder, [string]$Filter, [string[]]$ExpectedVms, [int]$TimeoutHours)

    if ($ExpectedVms.Count -eq 0) {
        Write-Log "WARNUNG: Keine ExpectedVmList konfiguriert - Wartelogik wird UEBERSPRUNGEN."
        return $true
    }

    $deadline = (Get-Date).AddHours($TimeoutHours)
    Write-Log "Warte auf VM-Done-Flags fuer: $($ExpectedVms -join ', ') (Timeout: $TimeoutHours h)"

    while ($true) {
        $existing = Get-ChildItem -Path $FlagFolder -Filter $Filter -File -ErrorAction SilentlyContinue
        $doneVms  = @()
        foreach ($f in $existing) {
            foreach ($vm in $ExpectedVms) {
                if ($f.Name -like "*_$vm`_*") { $doneVms += $vm }
            }
        }
        $doneVms = $doneVms | Select-Object -Unique
        $missing = $ExpectedVms | Where-Object { $_ -notin $doneVms }

        if ($missing.Count -eq 0) {
            Write-Log "Alle VMs bestaetigt: $($doneVms -join ', ')"
            return $true
        }

        if ((Get-Date) -gt $deadline) {
            Write-Log "TIMEOUT beim Warten auf VM-Done-Flags. Fehlend: $($missing -join ', ')"
            return $false
        }

        Write-Log "Noch offen: $($missing -join ', ') - warte $PollSeconds s..."
        Start-Sleep -Seconds $PollSeconds
    }
}

function New-UpdateStartedMarker {
    try {
        if (-not (Test-Path "C:\Temp")) { New-Item -Path "C:\Temp" -ItemType Directory -Force | Out-Null }
        (Get-Date).ToString("o") | Set-Content -Path "C:\Temp\update_started.txt" -Force
        Write-Log "update_started.txt angelegt - VM-Post-Skript kann jetzt den Reboot dieser Backup-VM verifizieren."
    } catch {
        Write-Log "WARNUNG: update_started.txt konnte nicht angelegt werden: $($_.Exception.Message)"
    }
}

if ($Mode -eq "Check") {
    try {
        Connect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser -Password $NasPassword
        if (-not (Test-Path $FlagFolder)) { throw "Flag-Pfad nicht erreichbar: $FlagFolder" }

        while ($true) {
            $latestFlag = Get-ChildItem -Path $FlagFolder -Filter $flagFilter -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1

            if ($latestFlag) {
                $isTodayByName      = ($latestFlag.Name -eq $expectedName)
                $isTodayByWriteTime = ($latestFlag.LastWriteTime.Date -eq (Get-Date).Date)
                if ($isTodayByName -and $isTodayByWriteTime) {
                    Write-Output "OK: Backup fuer heute ($today) erfolgreich. Flag: $($latestFlag.FullName)"
                    Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser
                    exit 0
                }
            }
            if (((Get-Date) - $startTime).TotalHours -ge $CheckTimeoutHours) {
                throw "Timeout: Kein aktuelles Backup-Flag fuer heute ($today) gefunden in $FlagFolder."
            }
            Start-Sleep -Seconds 60
        }
    }
    catch {
        Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser
        Write-Error $_.Exception.Message
        exit 1
    }
}

try {
    Write-Log "=== Start Backup-Job '$JobName' ==="

    Connect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser -Password $NasPassword
    if (-not (Test-Path $FlagFolder)) { throw "Flag-Pfad nicht erreichbar: $FlagFolder" }

    Connect-VeeamModule

    $job = Get-VBRJob -Name $JobName
    if (-not $job) { throw "Veeam-Job nicht gefunden: $JobName" }

    Cleanup-OldFiles -Path $FlagFolder -Filter $flagFilter
    Cleanup-OldFiles -Path $FlagFolder -Filter $vmDoneFilter
    Cleanup-OldFiles -Path $LogFolder  -Filter "backup-log-*.txt"

    if (Test-Path $flagFile) {
        Remove-Item $flagFile -Force -ErrorAction SilentlyContinue
        Write-Log "Altes Flag fuer heute entfernt (Re-Run erkannt)."
    }

    Write-Log "Starte Veeam-Job..."
    Start-VBRJob -Job $job | Out-Null

    $session = $null
    do {
        Start-Sleep -Seconds 5
        $session = Get-VBRBackupSession |
                Where-Object { $_.JobName -eq $JobName } |
                Sort-Object EndTimeUTC, CreationTimeUTC -Descending |
                Select-Object -First 1
    } until ($session)

    Write-Log "Session erkannt (ID: $($session.Id)). Warte auf Abschluss..."

    while (-not $session.IsCompleted) {
        if (((Get-Date) - $startTime).TotalHours -ge $TimeoutHours) {
            throw "Timeout: Backup lief laenger als $TimeoutHours Stunden."
        }
        Start-Sleep -Seconds $PollSeconds
        $session = Get-VBRBackupSession |
                Where-Object { $_.JobName -eq $JobName } |
                Sort-Object EndTimeUTC, CreationTimeUTC -Descending |
                Select-Object -First 1
    }

    $result = $session.Result.ToString()
    Write-Log "Session abgeschlossen. Ergebnis: $result"

    if ($result -ne "Success") {
        $reason = $session.GetTaskSessions() |
                Where-Object { $_.Status -ne "Success" } |
                ForEach-Object { "$($_.Name): $($_.GetLogger().GetLog() | Select-Object -Last 1)" }
        if ($reason) { Write-Log "Details: $($reason -join ' | ')" }
        throw "Backup nicht erfolgreich. Ergebnis: $result"
    }

    Set-Content -Path $flagFile -Value "Backup OK: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Encoding UTF8
    if (-not (Test-Path $flagFile)) { throw "Flag-Datei konnte nicht bestaetigt werden: $flagFile" }
    Write-Log "Flag-Datei erfolgreich erstellt: $flagFile -> VMs koennen jetzt patchen."

    $allVmsDone = Wait-ForAllVmDoneFlags -FlagFolder $FlagFolder -Filter $vmDoneFilter -ExpectedVms $vmList -TimeoutHours $WaitForVmsTimeoutHours

    if (-not $allVmsDone) {
        Write-Log "=== Ende Backup-Job (VMs nicht rechtzeitig fertig - OS-Patching Backup-Server bleibt ON HOLD) ==="
        Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser
        exit 1
    }

    # NEU (v2): update_started.txt anlegen, BEVOR das Skript erfolgreich endet und
    # NinjaOne das OS-Patching auf dieser Backup-VM freigibt. Ohne diese Zeile kann
    # das gemeinsame VM-Post-Skript auf dieser VM den Reboot nie verifizieren.
    New-UpdateStartedMarker

    Write-Log "=== Ende Backup-Job (Erfolg, alle VMs bestaetigt, OS-Patching Backup-Server darf starten) ==="
    Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser
    exit 0
}
catch {
    Write-Log "FEHLER: $($_.Exception.Message)"
    Write-Log "=== Ende Backup-Job (Fehler) ==="
    Disconnect-NasFlagShare -UncPath $FlagFolder -UserName $NasUser
    Write-Error $_.Exception.Message
    exit 1
}
