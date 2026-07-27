# Anforderungen – dbp-moodle

Dieses Dokument beschreibt die funktionalen und nicht-funktionalen Anforderungen des **dbp-moodle**-Services – einer produktionsreifen Moodle-LMS-Deployment-Lösung für die dBildungsplattform auf Kubernetes.

---

## 1. Überblick

| Eigenschaft        | Wert                          |
|--------------------|-------------------------------|
| Moodle-Version     | 4.5.10                        |
| PHP-Version        | 8.2.30                        |
| Chart-Version      | 1.1.2                         |
| Helm-Version       | ≥ 3.16.3                      |
| Kubernetes-Version | ≥ 1.25 (getestet mit ≥ 1.33)  |
| Lizenz             | Apache-2.0                    |

---

## 2. Funktionale Anforderungen

### 2.1 Moodle-Kernsystem

- Bereitstellung von Moodle LMS in Version 4.5.10 mit PHP 8.2 (FPM)
- Unterstützung mehrsprachiger Konfiguration (Deutsch `de`, Englisch `en`)
- Automatisches Datenbank-Setup und Migrations-Handling beim Start
- Konfiguration via `config.php` (generiert aus Helm-Values und Umgebungsvariablen)

### 2.2 Plugin-Management

- Installation von Plugins zur Image-Build-Zeit via `downloadPlugins.sh` (Plugin-ZIPs unter `/plugins` im Image)
- Abhängigkeitsbasierte Installationsreihenfolge (`local_wunderbyte_table`, `tool_certificate` und die `qbehaviour_*`-Plugins werden zuerst installiert)
- `auth_oidc` wird als Sonderfall aus `dBildungsplattform/dbp-moodle-plugin-oidc` (Branch `v_45`) gebaut
- Aktivierung zur Laufzeit über `global.moodlePlugins` in den Helm-Values → ConfigMap `moodle-plugins` → Env `MOODLE_PLUGINS` → `pluginCheck.sh` (installiert bzw. deinstalliert entsprechend dem Soll-Zustand)
- Alle Plugins sind per Default deaktiviert
- Im Image enthaltene Plugins:

  | Kategorie          | Plugins                                                                                     |
  |--------------------|---------------------------------------------------------------------------------------------|
  | Aktivitäten        | booking, board, checklist, choicegroup, coursecertificate, etherpadlite, hvp, pdfannotator, subcourse, unilabel, videotime, zoom |
  | Kursformate        | remuiformat, tiles, topcoll                                                                  |
  | Themes             | adaptable, boost_magnific, boost_union                                                       |
  | Blöcke             | completion_progress, sharing_cart, stash, xp                                                 |
  | Authentifizierung  | oidc                                                                                         |
  | Administration     | certificate, coursearchiver, dynamic_cohorts, heartbeat, usersuspension                      |
  | Filter             | filter_filtercodes, filter_shortcodes                                                        |
  | Fragetypen         | qtype_stack inkl. qbehaviour_adaptivemultipart, qbehaviour_dfexplicitvaildate, qbehaviour_dfcbmexplicitvaildate |
  | Sonstige           | availability_cohort, local_staticpage, local_wunderbyte_table                                |

> **Bekannte Lücke:** `global.moodlePlugins` bietet zusätzlich Schalter für `groupselect`, `jitsi`, `skype`, `reengagement`, `geogebra`, `flexsections`, `multitopic`, `saml2`, `dash`, `snap` und `customfield_dynamic`. Für diese Plugins wird in `downloadPlugins.sh` kein ZIP heruntergeladen — ein Aktivieren schlägt zur Laufzeit fehl.

### 2.3 Datenbank

- **Primäre Datenbank:** PostgreSQL (Bitnami-Chart v15.5.38) oder externe Managed-DB (z. B. AWS RDS)
- **Etherpad-Datenbank:** Separate PostgreSQL-Instanz, optional (Bitnami-Chart v15.5.38, Image-Tag `14.18.0-debian-12-r0`)
- Datenbankpasswörter werden über Kubernetes-Secrets verwaltet

### 2.4 Session-Management

- Standard: Dateibasierte Sessions im Moodledata-Volume
- Optional: Redis (Bitnami-Chart v19.5.3) für verteiltes Session-Management

### 2.5 Cron-Verarbeitung

- Moodle `cron.php` läuft in separaten CronJob-Pods (nicht im Haupt-Container)
- Cron wird während Updates automatisch deaktiviert und danach wieder aktiviert

### 2.6 Backup & Restore

- Werkzeug: `duply` (inkrementelles Backup via duplicity)
- Ziel: S3-kompatible Endpunkte (AWS S3, MinIO, etc.)
- Zeitplan: täglich 03:00 Uhr, wöchentliches Full-Backup, Aufbewahrung 6 Monate
- Verschlüsselung: GPG (konfigurierbare Schlüssel)
- Restore: One-Shot-Job für Rollback-Szenarien

### 2.7 Optionale Integrationen

| Komponente  | Zweck                              | Standardmäßig |
|-------------|------------------------------------|---------------|
| Etherpad-Lite | Kollaboratives Dokumentenbearbeiten | deaktiviert |
| ClamAV      | Antivirenprüfung hochgeladener Dateien | deaktiviert |
| Redis       | Verteiltes Session-Management      | deaktiviert   |
| OIDC/SAML2  | Föderiertes Identity-Management    | deaktiviert   |
| SQL-Exporter | Datenbankmetriken für Monitoring   | deaktiviert   |

---

## 3. Nicht-funktionale Anforderungen

### 3.1 Sicherheit (BSI SYS.1.6)

- Alle Container laufen als Non-Root (UID 1001 / GID 1001)
- Alle Linux-Capabilities werden gedroppt (`capabilities.drop: [ALL]`)
- Seccomp-Profil `RuntimeDefault` aktiviert
- Keine privilegierten Container (`privileged: false`)
- NetworkPolicies zur Steuerung der Ost-West-Kommunikation (Ingress für PostgreSQL, Redis, ClamAV, Etherpad, SQL-Exporter; optionale Egress-Sperre für Moodle) — per Default deaktiviert (`dbpMoodle.networkPolicies.enabled: false`), Aktivierung erfordert ein CNI mit NetworkPolicy-Support
- Trivy-Konfigurationsscan (CIS, NSA/CISA, Pod Security Standards) im CI/CD
- Geplante Sicherheitsscans via GitHub Actions (`trivy-cron`, täglich 02:00 UTC)

**Dokumentierte Ausnahmen (`.trivyignore.yaml`):**

| Regel              | Begründung                                                                       |
|--------------------|----------------------------------------------------------------------------------|
| KSV014 (`readOnlyRootFilesystem`) | PHP-FPM schreibt temp. Dateien (Sessions, Opcache, Uploads); Moodle schreibt Plugin-Assets. Mitigiert durch Non-Root, Capability-Drop, Seccomp, ClamAV |
| KSV020/KSV021 (UID/GID > 10000) | Fest auf 1001 im Image; Migration im laufenden Betrieb nicht praktikabel. Mitigiert durch `runAsNonRoot`-Enforcement |

### 3.2 Verfügbarkeit & Skalierung

- Horizontale Skalierung via HPA (optional, standardmäßig deaktiviert)
  - Minimum: 1 Replik, Maximum: 4 Repliken
  - CPU-Zielauslastung (`averageUtilization`): 50 %
  - Maximale Schrittweite je Periode: 50 % (up) / 25 % (down)
  - Periodendauer: 15 s (up) / 60 s (down); `stabilizationWindowSeconds: 0` beim Scale-up
- Pod Disruption Budgets (PDB) für Update-Sicherheit (`moodle.pdb.create: true`)
- Pre-Update-Hooks skalieren das Deployment kontrolliert herunter und sichern es vor dem Update

### 3.3 Performance

| Parameter              | Konfigurierter Wert |
|------------------------|---------------------|
| PHP Memory Limit       | 513 MB              |
| Upload Max Filesize    | 201 MB              |
| Post Max Size          | 201 MB              |
| Ingress `proxy-body-size` | 201 MB           |
| ClamAV Memory          | Request 2 GB / Limit 4 GB (StatefulSet) |
| Backup-Job Memory      | Request 1 GB / Limit 4 GB |

### 3.4 Persistenz & Storage

- **Moodledata-Volume:** ReadWriteMany PVC (`nfs-client` StorageClass), Standard 8 Gi
- **Shared Access:** PHP-FPM- und Apache-Container greifen gemeinsam auf `/dbp-moodle/moodle` (Code) und `/dbp-moodle/moodledata` (Nutzdaten) zu
- **Resource-Policy:** `helm.sh/resource-policy: keep` verhindert unbeabsichtigtes Löschen des PVC

---

## 4. Architektur-Anforderungen

### 4.1 Split-Container-Design

- **PHP-FPM-Container** (Port 9000): Moodle-PHP-Applikation
- **Apache-Container** (Port 8080 HTTP / 8443 HTTPS): Webserver, leitet Requests an PHP-FPM weiter
- Beide Container teilen sich Moodle-Code und Moodledata via gemeinsames Volume
- Apache erkennt den PHP-FPM-Host via `PHP_FPM_HOST`-Umgebungsvariable

### 4.2 Startup-Sequenz (PHP-FPM-Entrypoint)

1. PHP-FPM konfigurieren und im Hintergrund starten (`phpSetup.sh`)
2. PostgreSQL-Client initialisieren (`postgresSetup.sh`)
3. Moodle-Version prüfen, bei Bedarf Update durchführen (`updateCheck.sh`, mit Backup)
4. Datenbank-Setup & Initialisierung (`moodleSetup.sh`)
5. `config.php` anwenden
6. Sprachpakete `de`/`en` aktualisieren (sofern bereits vorhanden)
7. Ausstehende DB-Migration ausführen (`upgrade_if_pending`)
8. Plugins installieren / aktualisieren (`pluginCheck.sh`)
9. Hintergrund-PHP-FPM beenden und PHP-FPM im Vordergrund starten (`exec`)

### 4.3 Helm-Chart-Abhängigkeiten

| Chart (Alias)                       | Version | Quelle                      | Zweck                          |
|-------------------------------------|---------|-----------------------------|--------------------------------|
| `moodle`                            | 27.0.4  | `file://charts/moodle`      | Moodle-Kerndeployment          |
| `redis`                             | 19.5.3  | bitnami                     | Session-Store (optional)       |
| `postgresql`                        | 15.5.38 | bitnami                     | Primäre Datenbank (optional)   |
| `postgresql` (`etherpad-postgresql`)| 15.5.38 | bitnami                     | Etherpad-Datenbank (optional)  |
| `cronjob` (`moodlecronjob`)         | 0.1.0   | `file://charts/cronjob`     | Moodle cron.php                |
| `cronjob` (`backup-cronjob`)        | 0.1.0   | `file://charts/cronjob`     | S3-Backup (optional)           |
| `etherpad` (`etherpadlite`)         | 0.1.0   | `file://charts/etherpad`    | Etherpad-Lite (optional)       |
| `clamav`                            | 3.5.0   | wiremind                    | Antivirenscanner (optional)    |
| `sql-exporter`                      | 0.6.1   | burningalchemist            | DB-Metriken (optional)         |

Die Subcharts `moodle`, `cronjob` und `etherpad` liegen als lokale Charts unter `charts/dbp-moodle/charts/` im Repository.

---

## 5. CI/CD-Anforderungen

| Pipeline                          | Trigger                         | Zweck                                           |
|-----------------------------------|---------------------------------|-------------------------------------------------|
| `build-and-push-on-tag`           | Tag `[0-9]+.[0-9]+.[0-9]+*`     | Moodle-/Apache-Images nach GHCR publizieren     |
| `moodle-tools-bap-on-tag`         | Tag `moodle-tools-<semver>`     | moodle-tools-Image nach GHCR publizieren        |
| `test-docker-images`              | Änderungen in `moodle/` oder `moodle-tools/` | Container-Structure-Tests (v1.19.3)  |
| `test-helm-chart`                 | Helm-Chart-Änderungen           | lint, unittest (SecurityContext, NetPol, RBAC, Ressourcelimits), Trivy-Scan |
| `test-helm-kind`                  | Helm-Chart-Änderungen           | Integrationstests mit KinD                      |
| `helm-chart-release-on-push`      | Push auf Branch ≠ `main`        | Dev-Release des Helm-Charts inkl. Image-Build   |
| `helm-chart-release-on-tag`       | Tag `dbp-moodle-<semver>`       | Helm-Chart-Release (nach KICS-Scan)             |
| `generate-helm-docs-on-pr`        | Pull Request                    | README.md aus Chart-Values generieren           |
| `trivy-cron`                      | Zeitgesteuert (täglich 02:00 UTC) | Sicherheitsscan des gesamten Repos            |
| `sync-oidc-plugin-repo`           | Zeitgesteuert (stündlich) / manuell | OIDC-Plugin aus dBildungsplattform-Repo synchronisieren |

**Qualitätsgates:**
- Sicherheitsprobleme der Schwere HIGH / CRITICAL brechen den Build ab
- MEDIUM / LOW werden als SARIF-Report hinterlegt

---

## 6. Betriebliche Anforderungen

### 6.1 Monitoring & Health

- Liveness- und Readiness-Probes in allen Deployment-Templates
- ClamAV-Health-Checks für Antivirenscanning
- Optional: SQL-Exporter für Datenbankmetriken

### 6.2 Update-Strategie

- Pre-Update-Hook: Cron deaktivieren → Deployment herunterskalieren → Backup erstellen
- Post-Update: Datenbankmigration → Deployment hochskalieren → Cron aktivieren

### 6.3 Infrastruktur-Voraussetzungen

- Kubernetes-Cluster mit Unterstützung für `ReadWriteMany`-Volumes (z. B. NFS-StorageClass `nfs-client`)
- Container Registry: GHCR (`ghcr.io/dbildungsplattform/moodle`)
- S3-kompatibler Speicher für Backups
- (Optional) Managed PostgreSQL-Datenbank (AWS RDS o. ä.)
- (Optional) Redis-Instanz für Session-Clustering
