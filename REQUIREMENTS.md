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

- Installation von Plugins zur Image-Build-Zeit via `downloadPlugins.sh`
- Abhängigkeitsbasierte Installationsreihenfolge (z. B. `local_wunderbyte_table` vor `mod_booking`)
- Konfigurierbare Plugin-Auswahl via `global.moodlePlugins` in den Helm-Values
- Unterstützte Plugin-Kategorien:

  | Kategorie       | Beispiele                                                                        |
  |-----------------|----------------------------------------------------------------------------------|
  | Aktivitäten     | booking, checklist, hvp, pdfannotator, zoom, videotime, etherpadlite            |
  | Kursformate     | tiles, topcoll, remuiformat                                                      |
  | Themes          | boost_union, boost_magnific, adaptable, snap                                     |
  | Blöcke          | xp, sharing_cart, stash, completion_progress                                     |
  | Authentifizierung | oidc, saml2                                                                    |
  | Administration  | coursearchiver, usersuspension, dynamic_cohorts, certificate, heartbeat          |
  | Filter          | filter_filtercodes, filter_shortcodes                                            |

### 2.3 Datenbank

- **Primäre Datenbank:** PostgreSQL (Bitnami-Chart v15.5.38) oder externe Managed-DB (z. B. AWS RDS)
- **Etherpad-Datenbank:** Separate PostgreSQL-Instanz (v14), optional
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
- NetworkPolicies zur Steuerung der Ost-West-Kommunikation
- Trivy-Konfigurationsscan (CIS, NSA/CISA, Pod Security Standards) im CI/CD
- Geplante Sicherheitsscans via GitHub Actions (wöchentlich)

**Dokumentierte Ausnahmen (`.trivyignore.yaml`):**

| Regel              | Begründung                                                                       |
|--------------------|----------------------------------------------------------------------------------|
| KSV014 (`readOnlyRootFilesystem`) | PHP-FPM schreibt temp. Dateien (Sessions, Opcache, Uploads); Moodle schreibt Plugin-Assets. Mitigiert durch Non-Root, Capability-Drop, Seccomp, ClamAV |
| KSV020/KSV021 (UID/GID > 10000) | Fest auf 1001 im Image; Migration im laufenden Betrieb nicht praktikabel. Mitigiert durch `runAsNonRoot`-Enforcement |

### 3.2 Verfügbarkeit & Skalierung

- Horizontale Skalierung via HPA (optional)
  - Minimum: 1 Replik, Maximum: 4 Repliken
  - CPU-Schwellwert: Scale-up bei 50 %, Scale-down bei 25 %
  - Cooldown: 15 s (up) / 60 s (down)
- Pod Disruption Budgets (PDB) für Update-Sicherheit
- Pre-Update-Hooks skalieren das Deployment kontrolliert herunter und sichern es vor dem Update

### 3.3 Performance

| Parameter              | Konfigurierter Wert |
|------------------------|---------------------|
| PHP Memory Limit       | 513 MB              |
| Upload Max Filesize    | 201 MB              |
| Post Max Size          | 150 MB              |
| ClamAV Memory          | 2 GB (StatefulSet)  |
| Backup-Job Memory      | 4 GB                |

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

1. PHP-FPM konfigurieren und im Hintergrund starten
2. PostgreSQL-Client initialisieren
3. Moodle-Version prüfen, bei Bedarf Update durchführen (mit Backup)
4. Datenbank-Setup & Initialisierung
5. `config.php` anwenden
6. Plugins installieren / aktualisieren
7. PHP-FPM neu starten (Vordergrund)

### 4.3 Helm-Chart-Abhängigkeiten

| Chart              | Version    | Zweck                          |
|--------------------|------------|--------------------------------|
| bitnami/moodle     | 27.0.4     | Moodle-Kerndeployment          |
| bitnami/redis      | 19.5.3     | Session-Store                  |
| bitnami/postgresql | 15.5.38    | Primäre Datenbank              |
| bitnami/postgresql | 14.x       | Etherpad-Datenbank (optional)  |
| cronjob            | 0.1.0      | Moodle cron.php                |
| backup-cronjob     | 0.1.0      | S3-Backup                      |
| etherpad           | 0.1.0      | Etherpad-Lite (optional)       |
| wiremind/clamav    | 3.5.0      | Antivirenscanner (optional)    |
| sql-exporter       | 0.6.1      | DB-Metriken (optional)         |

---

## 5. CI/CD-Anforderungen

| Pipeline                          | Trigger                         | Zweck                                           |
|-----------------------------------|---------------------------------|-------------------------------------------------|
| `build-and-push-on-tag`           | Semver-Tag (z. B. `1.0.0`)      | Docker-Images nach GHCR publizieren             |
| `test-docker-images`              | Änderungen in `moodle/` oder `moodle-tools/` | Container-Structure-Tests (v1.19.3)  |
| `test-helm-chart`                 | Helm-Chart-Änderungen           | lint, unittest (SecurityContext, NetPol, RBAC, Ressourcelimits), Trivy-Scan |
| `test-helm-kind`                  | Helm-Chart-Änderungen           | Integrationstests mit KinD                      |
| `helm-chart-release-on-push`      | Push auf `main`                 | Helm-Chart veröffentlichen                      |
| `generate-helm-docs-on-pr`        | Pull Request                    | README.md aus Chart-Values generieren           |
| `trivy-cron`                      | Zeitgesteuert (wöchentlich)     | Sicherheitsscan des gesamten Repos              |
| `sync-oidc-plugin-repo`           | Manuell / Schedule              | OIDC-Plugin aus dBildungsplattform-Repo synchronisieren |

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
