ninjaone-scripts

Reposting with the official company account. Here are the scripts from before again — I'd be happy if someone wants to keep developing them with me and iron out the bugs.
Thanks to all of you!

NinjaOne Patch Orchestration: Backup Before Update, Staggered VM Patching
A script collection for NinjaOne that ensures a backup server (Veeam) only patches after a successful backup, and that guest VMs only patch after a successful snapshot/backup — coordinated via flag files on a shared NAS share, without the servers having to talk to each other directly.
Why bother with this?
Without coordination, NinjaOne patches all devices simultaneously according to schedule. In a virtualized setup (Hyper-V host + guest VMs, or ESXi + backup server), this leads to scenarios such as:
The backup server patches and reboots while the nightly backup is still running.
All VMs reboot at the same time as the Hyper-V host — nothing is reachable anymore.
But also plain laziness:
A snapshot/backup is marked as "successful" even though the actual application inside was never cleanly restarted afterward.
These scripts solve this using simple flag files on a NAS: each stage (backup, snapshot, VM reboot) leaves behind a timestamped file that the next stage checks as a "release condition" — technically implemented as a PRE-script in the respective NinjaOne patch policy.


Process Flow (Simplified)

Backup Server (Veeam)  --Backup OK-->  Flag: VeeamBackup_Success_<Date>.flag
                                              |
                                              v
VM policy PRE-script waits for exactly this flag, then patches the VM
                                              |
                                              v
VM policy POST-script (after reboot verification) writes
    VmUpdateDone_<ComputerName>_<Date>.flag
                                              |
                                              v
Backup server script waits for ALL VmUpdateDone flags,
    ONLY THEN is the backup server allowed to patch itself
For Hyper-V, there's an additional stage: the host must create a checkpoint per VM before the VM update (ESXi already handles this itself via Veeam's native VMware integration, so no equivalent is needed there). For Hyper-V, several alternative implementation variants exist in the repo (see repo structure), since snapshot and backup don't always need to be combined depending on customer requirements.
Repo Structure
text
.
├── README.md
├── .gitignore
├── ESXi-Scripts/
│   └── ...                                     Scripts for the pure ESXi
│                                                environment: backup server
│                                                script + VM pre/post without
│                                                a separate host snapshot
│                                                stage (Veeam handles
│                                                snapshotting for ESXi
│                                                itself via native VMware
│                                                integration).
│
└── hyperv/
    ├── Hyper-V_Proposal01_otherVer.../         Alternative/main variant of
    │                                           Proposal 1 (backup + snapshot
    │                                           combined) — possibly with a
    │                                           different flow or flag
    │                                           logic. TODO: briefly
    │                                           describe how this variant
    │                                           differs from Proposal_1.
    │
    ├── Proposal_1_Backup_and_Snapshot/         Combined approach: Veeam
    │                                           backup success AND a
    │                                           host-side checkpoint per
    │                                           guest VM must both be
    │                                           present before a VM may be
    │                                           patched. Highest level of
    │                                           safety, but also the
    │                                           longest lead time per patch
    │                                           cycle.
    │
    ├── Proposal_2_Snapshot_Only/                Reduced approach: only the
    │                                           host checkpoint per guest VM
    │                                           is a prerequisite for
    │                                           patching, independent of
    │                                           Veeam backup status. Useful
    │                                           when the backup window
    │                                           cannot be time-synced with
    │                                           the patch window.
    │
    └── Proposal_3_Veeam_Backup_Only/            Reduced approach: only
                                                Veeam backup success is a
                                                prerequisite, no separate
                                                host checkpoint. Useful
                                                when checkpoints should be
                                                avoided for performance or
                                                storage reasons.
Note: hyperv/ deliberately contains several alternative implementations instead of a single final solution. Only the applicable proposal is used per customer — depending on whether snapshot and backup should be checked in combination, or whether only one of the two conditions is sufficient. ESXi-Scripts/ is independent of this and covers only the ESXi environment.
TODO: Add the exact script names and their PRE/POST assignment within each Proposal_* folder here once it's finally decided which variant is used in production, or how the folders differ in detail.
Required NinjaOne Custom Fields
All scripts read their configuration exclusively via Ninja-Property-Get — no paths or credentials are hardcoded. The following fields must be created and maintained per customer/organization; whether it's an org- or device-level field can be left up to you:

Field NameTypeUsed ByDescription
| Field Name | Type | Used By | Description |
|---|---|---|---|
| veeamJobName | Text | VeeamBackupWithFlag | Exact name of the Veeam backup job (Veeam console → Jobs) |
| veeamFlagName | Text | VeeamBackupWithFlag | Base name of the success flag file, default VeeamBackup |
| vmDoneFlagPrefix | Text | VeeamBackupWithFlag, Hyper-V Host-Wait-Pre | Prefix of the VM done flags, default VmUpdateDone |
| expectedVmList | Text | VeeamBackupWithFlag, Hyper-V Host-Snapshot-Pre | Comma-separated list of exact Windows computer names (e.g. DC01,TS01,DB01) — no IPs, no SIDs, no FQDNs (unless the VM post-scripts themselves use FQDN) |
| hostExpectedVmList | Text | Hyper-V Host-Wait-Pre | Optional, if different from expectedVmList (e.g. additionally the backup server) |
| flagFolder | Text | all | UNC path to the flag share, e.g. \\NAS01\Flags |
| logFolder | Text | VeeamBackupWithFlag | UNC path for the log file, can be identical to flagFolder |
| nasUser | Text | all | NAS username for the flag share |
| nasPassword | Secure | all | NAS password — always as a Secure Custom Field, never as a plaintext parameter |
| snapshotPrefix | Text | Hyper-V Host-Snapshot-Pre | Optional, prefix for checkpoint names, default AutoPatch |
| snapshotRetentionDays | Text | Hyper-V Host-Snapshot-Pre | Optional, delete old checkpoints after X days, default 3 |
| hostRebootMaxWaitMinutes | Text | Hyper-V Host-Cleanup-Post | Optional, max wait time for host reboot confirmation, default 30 |
| hostWaitMaxMinutes | Text | Hyper-V Host-Wait-Pre | Optional, max wait time for VM flags, default 240 (4 h) |
| hostWaitPollSeconds | Text | Hyper-V Host-Wait-Pre | Optional, polling interval, default 60 |

Hyper-V Host-Wait-Pre
Optional, polling interval, default 60
Each custom field can be created at device level (per server individually) or organization level (shared across all of a customer's devices, e.g. flagFolder/nasUser/nasPassword, if all servers use the same NAS) — depending on how granular you need it per customer.
Setup Order for a New Customer
Create the NAS share (flagFolder), set up a dedicated user (nasUser) with write permission to exactly this share. Check whether the user is also enabled in the application permissions (e.g. Synology: explicitly allow SMB) — a successful DSM web login doesn't automatically guarantee SMB access.
Populate the custom fields from the table above for the customer.
Depending on the environment, deploy the appropriate backup server script as the PRE-script of the backup server patch policy, run as System: ESXi-Scripts/... (ESXi) or the chosen hyperv/Proposal_* set (Hyper-V).
For ESXi: distribute the matching PRE/POST scripts from ESXi-Scripts/ to the guest VM patch policies.
For Hyper-V: choose one of the three proposals (do not mix!) and distribute its host and guest VM scripts to host and VM patch policies as described in the respective subfolder.
Run a first test without expectedVmList (leave the field empty) to confirm that backup start, NAS access, and flag creation work on their own, before the VM waiting logic comes into play.
Populate expectedVmList with the real computer names and test the full end-to-end flow once.
Known Pitfalls
SYSTEM context has no network profile of its own. Saved net use/Credential Manager entries from an interactive admin session are invisible to the System context. VeeamBackupWithFlag.ps1 solves this by setting cmdkey itself on every run and removing it again at the end — if nasUser is empty, this happens silently, and NAS access fails with "access denied" without it being obvious why.
Start-VBRJob can block synchronously until the backup is finished. For long backups, be sure to set the NinjaOne script timeout accordingly high (total runtime can reach TimeoutHours + WaitForVmsTimeoutHours), otherwise an actually successful but merely slow run gets flagged as a timeout/error.
expectedVmList expects exact computer names, not IP addresses or SIDs. The matching is done via wildcard search in the filename — the name must match 1:1 with what the VM post-script uses when writing the done flag (usually $env:COMPUTERNAME).
If expectedVmList is empty, the entire waiting logic is deliberately skipped (no error, no wait time) — useful for customers without dependent VMs, but easy to overlook if VMs were actually expected and the field was simply forgotten.
Synology & co.: DSM web login ≠ SMB access. A successful login to the NAS web interface does not automatically mean the same user is also allowed to write to a share via SMB — these are separate permission layers (application permission + share ACL).
License / Usage
Internal script collection. Before sharing with third parties, please make sure no customer-specific paths, job names, or credentials remain — all scripts in this repo are already maintained as blank templates without hardcoding.






ninjaone-scripts

Repost mit offiziellen Firmen Account. Nochmal die Skripte von damals, ich freu mich wenn jemand sie mit mir entwickelt weiter und Fehler ausmerzt.

Ich danke euch allen 

NinjaOne Patch-Orchestrierung: Backup vor Update, gestaffeltes VM-Patching

Skript-Sammlung für NinjaOne, die sicherstellt, dass ein Backup-Server (Veeam)
erst nach einem erfolgreichen Backup patcht, und dass Gast-VMs erst nach
einem erfolgreichen Snapshot/Backup patchen — koordiniert über Flag-Dateien auf
einem gemeinsamen NAS-Share, ohne dass die Server sich direkt gegenseitig
ansprechen müssen.

Warum das Ganze?
Ohne Koordination patcht NinjaOne alle Geräte gemäß Zeitplan gleichzeitig.
Bei einem virtualisierten Setup (Hyper-V-Host + Gast-VMs, oder ESXi + Backup-
Server) führt das zu Szenarien wie:

Der Backup-Server patcht und rebootet, während das nächtliche Backup noch läuft.

Alle VMs rebooten gleichzeitig mit dem Hyper-V-Host — nichts ist mehr erreichbar.

Aber auch die Faulheit:

Ein Snapshot/Backup wird als "erfolgreich" gewertet, obwohl die eigentliche
Anwendung danach nie sauber neu gestartet wurde.

Diese Skripte lösen das über einfache Flag-Dateien auf einem NAS: Jede
Stufe (Backup, Snapshot, VM-Reboot) hinterlässt eine Datei mit Zeitstempel im
Namen, die von der nächsten Stufe als "Freigabe-Bedingung" abgefragt wird —
technisch als PRE-Skript in der jeweiligen NinjaOne-Patch-Policy.

Ablaufprinzip (vereinfacht)


Backup-Server (Veeam)  --Backup OK-->  Flag: VeeamBackup_Success_<Datum>.flag
                                              |
                                              v
VM-Policy PRE-Skript wartet auf genau dieses Flag, dann patcht die VM
                                              |
                                              v
VM-Policy POST-Skript (nach Reboot-Verifikation) schreibt
    VmUpdateDone_<ComputerName>_<Datum>.flag
                                              |
                                              v
Backup-Server-Skript wartet auf ALLE VmUpdateDone-Flags,
    erst DANN darf der Backup-Server selbst patchen
Bei Hyper-V kommt eine zusätzliche Stufe dazu: Der Host muss vor dem
VM-Update einen Checkpoint pro VM erstellen (ESXi übernimmt das bereits über
die Veeam-VMware-Integration selbst, daher kein Äquivalent nötig). Für
Hyper-V liegen dazu im Repo mehrere alternative Umsetzungsvarianten vor
(siehe Repo-Struktur), da je nach Kundenanforderung nicht immer Snapshot
und Backup kombiniert werden müssen.

Repo-Struktur


.
├── README.md
├── .gitignore
├── ESXi-Skripte/
│   └── ...                                     Skripte für die reine ESXi-
│                                                Umgebung: Backup-Server-
│                                                Skript + VM-Pre/Post ohne
│                                                separate Host-Snapshot-Stufe
│                                                (Veeam übernimmt das
│                                                Snapshot-Handling für ESXi
│                                                selbst über die native
│                                                VMware-Integration).
│
└── hyperv/
    ├── Hyper-V_Vorschalg01_andereVer.../       Alternative/main Variante
    │                                           von Vorschlag 1 (Backup +
    │                                           Snapshot kombiniert) — ggf.
    │                                           mit abweichendem Ablauf oder
    │                                           anderer Flag-Logik. TODO: Kurz
    │                                           beschreiben, worin sich diese
    │                                           Variante von Vorschlag_1
    │                                           unterscheidet.
    │
    ├── Vorschlag_1_Backup_und_Snapshot/        Kombinierter Ansatz: Veeam-
    │                                           Backup-Erfolg UND Host-seitiger
    │                                           Checkpoint je Gast-VM müssen
    │                                           vorliegen, bevor eine VM
    │                                           gepatcht werden darf. Höchste
    │                                           Absicherung, aber auch längste
    │                                           Vorlaufzeit pro Patch-Zyklus.
    │
    ├── Vorschlag_2_Nur_Snapshot/                Reduzierter Ansatz: Nur der
    │                                           Host-Checkpoint pro Gast-VM
    │                                           ist Voraussetzung fürs Patchen,
    │                                           unabhängig vom Veeam-Backup-
    │                                           Status. Sinnvoll, wenn das
    │                                           Backup-Fenster zeitlich nicht
    │                                           mit dem Patch-Fenster
    │                                           synchronisiert werden kann.
    │
    └── Vorschlag_3_Nur_Veeam_Backup/            Reduzierter Ansatz: Nur der
                                                Veeam-Backup-Erfolg ist
                                                Voraussetzung, kein separater
                                                Host-Checkpoint. Sinnvoll,
                                                wenn Checkpoints aus
                                                Performance- oder Storage-
                                                Gründen vermieden werden
                                                sollen.
Hinweis: hyperv/ enthält bewusst mehrere alternative Umsetzungen statt
einer einzigen finalen Lösung. Pro Kunde wird nur der jeweils passende
Vorschlag eingesetzt — je nachdem, ob Snapshot und Backup kombiniert
geprüft werden sollen, oder nur eine der beiden Bedingungen ausreicht.
ESXi-Skripte/ ist davon unabhängig und deckt ausschließlich die
ESXi-Umgebung ab.

TODO: Die genauen Skriptnamen und deren PRE/POST-Zuordnung innerhalb jedes
Vorschlag_*-Ordners hier ergänzen, sobald final entschieden ist, welche
Variante produktiv genutzt wird bzw. wie sich die Ordner inhaltlich im
Detail unterscheiden.

Erforderliche NinjaOne Custom Fields
Alle Skripte lesen ihre Konfiguration ausschließlich über
Ninja-Property-Get — es sind keine Pfade oder Zugangsdaten im Code
hinterlegt. Folgende Felder müssen pro Kunde/Organisation angelegt und
gepflegt werden, welche Orga- oder Device-Field wird kann jedem selbst
überlassen bleiben:

Feldname	Typ	Verwendet von	Beschreibung
| Feldname | Typ | Verwendet von | Beschreibung |
|---|---|---|---|
| veeamJobName | Text | VeeamBackupMitFlag | Exakter Name des Veeam-Backup-Jobs (Veeam-Konsole → Jobs) |
| veeamFlagName | Text | VeeamBackupMitFlag | Basisname der Erfolgs-Flag-Datei, Default VeeamBackup |
| vmDoneFlagPrefix | Text | VeeamBackupMitFlag, Hyper-V Host-Wait-Pre | Präfix der VM-Done-Flags, Default VmUpdateDone |
| expectedVmList | Text | VeeamBackupMitFlag, Hyper-V Host-Snapshot-Pre | Kommagetrennte Liste exakter Windows-Computernamen (z. B. DC01,TS01,DB01) — keine IPs, keine SIDs, keine FQDNs (außer die VM-Post-Skripte nutzen selbst FQDN) |
| hostExpectedVmList | Text | Hyper-V Host-Wait-Pre | Optional, wenn abweichend von expectedVmList (z. B. zusätzlich Backup-Server) |
| flagFolder | Text | alle | UNC-Pfad zum Flag-Share, z. B. \\NAS01\Flags |
| logFolder | Text | VeeamBackupMitFlag | UNC-Pfad für das Logfile, kann identisch zu flagFolder sein |
| nasUser | Text | alle | NAS-Benutzername für den Flag-Share |
| nasPassword | Secure | alle | NAS-Passwort — immer als Secure Custom Field, niemals als Klartext-Parameter |
| snapshotPrefix | Text | Hyper-V Host-Snapshot-Pre | Optional, Präfix für Checkpoint-Namen, Default AutoPatch |
| snapshotRetentionDays | Text | Hyper-V Host-Snapshot-Pre | Optional, alte Checkpoints löschen nach X Tagen, Default 3 |
| hostRebootMaxWaitMinutes | Text | Hyper-V Host-Cleanup-Post | Optional, max. Wartezeit auf Host-Reboot-Bestätigung, Default 30 |
| hostWaitMaxMinutes | Text | Hyper-V Host-Wait-Pre | Optional, max. Wartezeit auf VM-Flags, Default 240 (4 h) |
| hostWaitPollSeconds | Text | Hyper-V Host-Wait-Pre | Optional, Abfrageintervall, Default 60 |

Setup-Reihenfolge für einen neuen Kunden
NAS-Freigabe (flagFolder) anlegen, dedizierten Benutzer (nasUser)
mit Schreibrecht auf genau diese Freigabe einrichten. Prüfen, ob der
Benutzer auch in den Anwendungsberechtigungen (z. B. Synology: SMB
explizit erlauben) freigeschaltet ist — DSM-Weblogin-Erfolg garantiert
nicht automatisch SMB-Zugriff.

Custom Fields aus der Tabelle oben für den Kunden befüllen.

Je nach Umgebung das passende Backup-Server-Skript als PRE-Skript der
Backup-Server-Patch-Policy hinterlegen, Ausführung als System:
ESXi-Skripte/... (ESXi) bzw. den gewählten hyperv/Vorschlag_*-Satz
(Hyper-V).

Bei ESXi: die passenden PRE-/POST-Skripte aus ESXi-Skripte/ auf den
Gast-VM-Patch-Policies verteilen.

Bei Hyper-V: einen der drei Vorschläge auswählen (nicht mischen!)
und dessen Host- sowie Gast-VM-Skripte gemäß der Beschreibung im
jeweiligen Unterordner auf Host- und VM-Patch-Policies verteilen.

Ersten Testlauf ohne expectedVmList (Feld leer lassen) durchführen,
um zu bestätigen, dass Backup-Start, NAS-Zugriff und Flag-Erstellung für
sich funktionieren, bevor die VM-Wartelogik mit ins Spiel kommt.

expectedVmList mit den echten Computernamen befüllen und Gesamtablauf
einmal Ende-zu-Ende testen.

Bekannte Stolperfallen
SYSTEM-Kontext hat kein eigenes Netzwerkprofil. Gespeicherte
net use/Credential-Manager-Einträge aus einer interaktiven Admin-Sitzung
sind für den System-Kontext unsichtbar. VeeamBackupMitFlag.ps1 löst das,
indem es bei jedem Lauf selbst cmdkey setzt und am Ende wieder entfernt —
ist nasUser leer, passiert das lautlos, und der NAS-Zugriff schlägt
mit "Zugriff verweigert" fehl, ohne dass das offensichtlich ist.

Start-VBRJob kann synchron blockieren, bis das Backup fertig ist.
Bei langen Backups unbedingt das NinjaOne-Skript-Timeout entsprechend hoch
setzen (die Gesamtlaufzeit kann TimeoutHours + WaitForVmsTimeoutHours
erreichen), sonst wird ein eigentlich erfolgreicher, nur langsamer Lauf als
Timeout/Fehler gewertet.

expectedVmList erwartet exakte Computernamen, keine IP-Adressen oder
SIDs. Der Abgleich läuft per Wildcard-Suche im Dateinamen — der Name muss
1:1 mit dem übereinstimmen, was das VM-Post-Skript beim Schreiben der
Done-Flag verwendet (i. d. R. $env:COMPUTERNAME).

Ist expectedVmList leer, wird die gesamte Wartelogik bewusst
übersprungen (kein Fehler, keine Wartezeit) — sinnvoll für Kunden ohne
abhängige VMs, aber leicht zu übersehen, wenn eigentlich VMs erwartet
wurden und das Feld nur vergessen wurde.

Synology & Co.: DSM-Weblogin ≠ SMB-Zugriff. Ein erfolgreicher Login in
die NAS-Weboberfläche bedeutet nicht automatisch, dass derselbe Benutzer
auch per SMB auf eine Freigabe schreiben darf — das sind getrennte
Berechtigungsebenen (Anwendungsberechtigung + Freigabe-ACL).

Lizenz / Nutzung
Interne Skript-Sammlung. Vor Weitergabe an Dritte bitte sicherstellen, dass
keine kundenspezifischen Pfade, Jobnamen oder Zugangsdaten mehr enthalten
sind — alle Skripte in diesem Repo sind bereits als Blanko-Vorlagen ohne
Hardcoding gepflegt.
