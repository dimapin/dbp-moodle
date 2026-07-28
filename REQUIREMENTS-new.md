---
document_id: REQ-DBP-MOODLE
version: 2.0.0
status: APPROVED
classification: INTERNAL
compliance_target: BSI SYS.1.6 / Kubernetes Pod Security Standards (Restricted)
---

# Anforderungen & System-Spezifikation (REQUIREMENTS.md) – dbp-moodle

> **Architektur-Prämisse:** Dieses Dokument ist die unverletzliche Quelle der Wahrheit (*Single Source of Truth*) für das Systemdesign des `dbp-moodle` Services der dBildungsplattform. Es beschreibt das **Was**, das **Warum** und die **unverrückbaren Grenzen** des Systems. Operative Ausführungsrichtlinien für KI-Assistenten sind in `CLAUDE.md` gekapselt.

---

## 1. System-Überblick & Architektur-Design

Das System stellt eine hochverfügbare, BSI-konforme Moodle LMS Instanz auf Kubernetes (≥ 1.25) via Helm (≥ 3.16.3) bereit. Es folgt einem strikten **Split-Container-Design** zur Entkopplung von Applikationsserver und Webserver:

    +-----------------------------------------------------------------------+
    | Pod: Moodle-Core                                                      |
    |  +------------------------+  (FastCGI / Port 9000)                    |
    |  | Container: PHP-FPM     | <---------------------+                   |
    |  | (Debian 13 Trixie)     |                       |                   |
    |  +------------------------+                       |                   |
    |              |                                    |                   |
    |              | ReadWriteMany (NFS)                | PHP_FPM_HOST      |
    |              v                                    |                   |
    |  +-------------------------------------------------------------+      |
    |  | Shared Volume: /dbp-moodle (moodle-code + moodledata)       |      |
    |  +-------------------------------------------------------------+      |
    |              ^                                    |                   |
    |              | ReadWriteMany (NFS)                |                   |
    |  +------------------------+                       |                   |
    |  | Container: Apache      | ----------------------+                   |
    |  | (Debian 12 Bookworm)   |                                           |
    |  +------------------------+                                           |
    +-----------------------------------------------------------------------+

| Eigenschaft | Wert |
| :--- | :--- |
| Moodle-Version | 4.5.12 |
| PHP-Version | 8.3.32 (FPM) |
| Basis-Image | Debian 13 (Trixie) für Moodle- und Tools-Image; Debian 12 (Bookworm) für Apache |
| Chart-Version | 1.6.2 |
| Helm-Version | ≥ 3.16.3 |
| Kubernetes-Version | ≥ 1.25 (getestet mit ≥ 1.33) |
| Lizenz | Apache-2.0 |

| Komponente | Basis-Image / Version | Port / Protokoll | Verantwortung |
| :--- | :--- | :--- | :--- |
| **Moodle Core** | v4.5.12 | – | LMS Applikationskern |
| **PHP-FPM** | `php:8.3.32-fpm-trixie` | 9000 / FastCGI | Ausführung der Moodle-PHP-Logik |
| **Apache** | `debian:bookworm-slim` | 8080 (HTTP) / 8443 (HTTPS) | Web-Proxy, Statisches Dateihandling, TLS/Ingress-Target |
| **moodle-tools** | `bitnami/minideb:trixie` (`1.1.15`) | – | Dediziertes Cron- und Backup-Ausführungsimage |

---

## 2. Hard Constraints (Unverrückbare Systemgrenzen & Compliance)

> **Regel:** Hard Constraints definieren den unverletzlichen architektonischen Raum. Eine funktionale Anforderung oder eine Code-Änderung, die einen Constraint verletzt, ist per Definition ungültig.

| ID | Kategorie | Beschreibung & Rationale | Verifizierungs-Methode |
| :--- | :--- | :--- | :--- |
| **[CON-SEC-001]** | **BSI SYS.1.6** | **Unprivilegierte Container:** Alle Container MÜSSEN zwingend im Non-Root-Kontext (UID `1001` / GID `1001`) laufen. Es MÜSSEN alle Linux-Capabilities gedroppt werden (`capabilities.drop: [ALL]`). Das Seccomp-Profil MUSS auf `RuntimeDefault` gesetzt sein. `privileged: false` ist verbindlich.<br>*Rationale:* Erfüllung der BSI SYS.1.6 Vorgaben und Kubernetes Pod Security Standards (Restricted). | `helm unittest` & CI-Policy-Gate |
| **[CON-SEC-002]** | **Trivy Vulnerability Gate** | **Null-Toleranz bei kritischen Schwachstellen:** Der CI/CD-Build MUSS bei Trivy-Scans mit Schweregrad `HIGH` oder `CRITICAL` abbrechen. Neue Ausnahmen in der `.trivyignore.yaml` DÜRFEN NUR mit einer formellen, BSI-konformen schriftlichen Begründung hinzugefügt werden.<br>*Dokumentierte Bestandsausnahmen:*<br>- `KSV014` (`readOnlyRootFilesystem`): Moodle/PHP-FPM benötigen Schreibzugriff für Sessions, Caches und temporäre Uploads.<br>- `KSV020/021` (UID/GID > 10000): Fest auf `1001` gepinnt zur Kompatibilität mit Moodle-Dateirechten. | CI/CD GitHub Action (`test-helm-chart`) |
| **[CON-SEC-003]** | **Software-Lieferkette** | **Sonderfall OIDC-Plugin:** Das Plugin `auth_oidc` DARF NICHT aus dem Moodle Marketplace bezogen werden. Es MUSS zwingend als Custom-Build aus dem Unternehmens-Repository `dBildungsplattform/dbp-moodle-plugin-oidc` (Branch `v_45`) integriert werden.<br>*Rationale:* Spezifische Anpassungen an die Föderationsinfrastruktur der dBildungsplattform. | CI/CD Sync-Workflow & Dockerfile-Inspection |
| **[CON-RES-001]** | **Data Governance** | **Schutz vor Datenverlust:** Alle PVCs für `moodledata` und Moodle-Code MÜSSEN zwingend die Helm-Annotation `helm.sh/resource-policy: keep` tragen.<br>*Rationale:* Verhindert den Verlust von Nutzerdaten bei versehentlichem `helm uninstall`. | Helm Unit-Test |

---

## 3. Funktionale Anforderungen (Functional Requirements - FR)

### 3.1 Core LMS & Lifecycle
* **[FR-CORE-001] Startup-Sequenz & Auto-Configuration:** Der PHP-FPM Container MUSS beim Start autonom folgende Initiierung durchlaufen:
  1. Datenbank-Konnektivität (PostgreSQL) prüfen (`postgresSetup.sh`).
  2. Moodle-Versionscheck durchführen und bei Versionssprüngen ein Pre-Update-Backup sowie ein CLI-Upgrade ausführen (`updateCheck.sh`, `upgrade_if_pending`).
  3. Konfiguration (`config.php`) dynamisch aus Helm-Values und Kubernetes-Secrets generieren.
  4. Sprachpakete (`de`, `en`) synchronisieren.
* **[FR-CORE-002] Entkoppelte Cron-Verarbeitung:** Die Moodle-Verarbeitung (`cron.php`) DARF NICHT im Haupt-Applikationscontainer laufen. Sie MUSS als separater Kubernetes CronJob im Image `moodle-tools` ausgeführt werden.
* **[FR-CORE-003] Safe-Update-Hooks:** Das Helm-Chart MUSS Lifecycle-Hooks implementieren, die vor einem Chart-Upgrade den CronJob deaktivieren, das Deployment auf 0 skalieren (um Datenbank-Locks zu verhindern) und einen Backup-Snapshot triggern. Erst nach erfolgreicher DB-Migration wird auf Skalierungssollwert hochgefahren und der CronJob reaktiviert.
* **[FR-CORE-004] Mehrsprachige Konfiguration:** Die Applikation MUSS die Sprachen `de` und `en` unterstützen und die Konfigurationseinstellungen entsprechend vorbereiten.

### 3.2 Plugin-Management (Build-Time & Runtime)
* **[FR-PLG-001] Build-Time Ingestion:** Alle unterstützten Plugins MÜSSEN zur Image-Build-Zeit via `downloadPlugins.sh` aus dem Moodle Marketplace in das Image (unter `/plugins`) heruntergeladen werden.
* **[FR-PLG-002] Abhängigkeitsgesteuerte Installation:** Die Installationsreihenfolge MUSS Abhängigkeiten respektieren: `local_wunderbyte_table`, `tool_certificate` sowie die `qbehaviour_*`-Plugins MÜSSEN vor den abhängigen Aktivitäten installiert werden.
* **[FR-PLG-003] Runtime-Steuerung (GitOps):** Im Image enthaltene Plugins sind standardmäßig **deaktiviert**. Die Aktivierung und Ausführung der Installation im DB-Schema MUSS zur Laufzeit über den Schalter `global.moodlePlugins` (in den Helm-Values über ConfigMap `moodle-plugins`) via `pluginCheck.sh` gesteuert werden.
* **[FR-PLG-004] Im Image enthaltene & unterstützte Plugins:**
  * *Aktivitäten:* `board`, `checklist`, `choicegroup`, `coursecertificate`, `etherpadlite`, `hvp`, `pdfannotator`, `subcourse`, `unilabel`, `videotime`, `zoom`
  * *Kursformate & Themes:* `remuiformat`, `tiles`, `topcoll`, `adaptable`, `boost_magnific`, `boost_union`
  * *Blöcke:* `completion_progress`, `sharing_cart`, `stash`, `xp`
  * *Auth & Admin:* `oidc` (via [CON-SEC-003]), `certificate`, `coursearchiver`, `dynamic_cohorts`, `heartbeat`, `usersuspension`
  * *Filter & Fragetypen:* `filter_filtercodes`, `filter_shortcodes`, `qtype_stack`, `qbehaviour_adaptivemultipart`, `qbehaviour_dfexplicitvaildate`, `qbehaviour_dfcbmexplicitvaildate`
  * *Sonstige:* `availability_cohort`, `local_staticpage`, `local_wunderbyte_table`

### 3.3 Datenbank, Sessions & Cron
* **[FR-DB-001] Primäre Datenbank:** PostgreSQL ist die primäre Datenbank; optional können externe Managed-DBs wie AWS RDS verwendet werden.
* **[FR-DB-002] Etherpad-Datenbank:** Für Etherpad-Lite MUSS eine separate PostgreSQL-Instanz optional bereitstehen.
* **[FR-DB-003] Secret-basierte Credentials:** Datenbankpasswörter und Zugangsdaten MÜSSEN ausschließlich über Kubernetes-Secrets verwaltet werden.
* **[FR-SES-001] Session-Management:** Standardmäßig MÜSSEN Dateisessions im Moodledata-Volume verwendet werden; Redis ist optional für verteiltes Session-Management verfügbar.
* **[FR-CRO-001] Cron-Ausführung:** Der Moodle-Cron MUSS in separaten CronJob-Pods laufen und nicht im Haupt-Container.

### 3.4 Backup, Recovery & Integrations
* **[FR-BCK-001] Verschlüsseltes S3-Backup:** Das System MUSS tägliche (03:00 UTC) inkrementelle und wöchentliche Voll-Backups via `duply` (im `moodle-tools` Image) auf einen S3-kompatiblen Objektspeicher schreiben.
* **[FR-BCK-002] GPG-Verschlüsselung:** Backups MÜSSEN clientseitig via GPG verschlüsselt werden. Die Schlüsselnamen MÜSSEN dynamisch über `dbpMoodle.backup.gpg_key_names` via Helm-Helper in die Befehlskette initiiert werden.
* **[FR-BCK-003] Aufbewahrungsfrist:** Die Backup-Retention ist auf exakt 6 Monate zu erzwingen.
* **[FR-INT-001] Optionale Integrationen:** Etherpad-Lite, ClamAV, Redis, OIDC/SAML2 und SQL-Exporter MÜSSEN optional und deaktiviert per Default einsetzbar sein.

### 3.5 Netzwerk & Netzwerksicherheit
* **[FR-NET-001] NetworkPolicy-Templates:** Das Helm-Chart MUSS NetworkPolicies bereitstellen, die Ingress-Verkehr nur auf Port 8080/8443 (Apache) und Egress-Verkehr nur zu definierten Endpunkten (PostgreSQL, Redis, ClamAV, Etherpad, DNS, S3) erlauben.
* **[FR-NET-002] Opt-In Aktivierung:** Um in Kubernetes-Clustern ohne CNI-Support für NetworkPolicies kein Deployment zu blockieren, MÜSSEN die NetworkPolicies per Default deaktiviert sein (`dbpMoodle.networkPolicies.enabled: false`).

---

## 4. Nicht-funktionale Anforderungen (Non-Functional Requirements - NFR)

### 4.1 Security & Compliance
| ID | Metrik / Ziel | Messmethode / Akzeptanzkriterium |
| :--- | :--- | :--- |
| **[NFR-SEC-001]** | **Non-Root & Capabilities** | Alle Container MÜSSEN mit UID/GID `1001` laufen, `capabilities.drop: [ALL]` setzen und `seccompProfile: RuntimeDefault` verwenden. |
| **[NFR-SEC-002]** | **Trivy-Gate** | HIGH/CRITICAL Schwachstellen MÜSSEN den Build abbrechen; MEDIUM/LOW MÜSSEN in SARIF-Reports dokumentiert werden. |

### 4.2 Performance & Storage-Optimierung
| ID | Metrik / Ziel | Messmethode / Akzeptanzkriterium |
| :--- | :--- | :--- |
| **[NFR-PERF-001]** | **OPcache & NFS-Mitigation** | Da Moodle-Code auf einem `ReadWriteMany` NFS-Share (`nfs-client`) liegt, MUSS PHP OPcache zwingend mit `opcache.enable=1`, `opcache.memory_consumption=256` und `opcache.revalidate_freq=60` konfiguriert sein, um I/O-Stat-Staus über das Netzwerk zu verhindern. |
| **[NFR-PERF-002]** | **Payload-Durchsatz** | Das System MUSS Datei-Uploads (POST-Body, PHP-Limit und Apache/Ingress Proxy-Body-Size) bis zu einer Größe von **201 MB** ohne Timeout verarbeiten können. |
| **[NFR-PERF-003]** | **Ressourcen-Limits** | PHP-FPM Pods MÜSSEN mit einem harten Memory-Limit von 513 MB betrieben werden. Der ClamAV-Antivirus-Scanner MUSS im StatefulSet ein Limit von 4 GB RAM erhalten, um Out-of-Memory (OOM) Kills bei Signatur-Updates zu vermeiden. |

### 4.3 Resilienz & Skalierung
| ID | Metrik / Ziel | Messmethode / Akzeptanzkriterium |
| :--- | :--- | :--- |
| **[NFR-RES-001]** | **Horizontale Skalierung (HPA)** | Bei Aktivierung MUSS der HPA zwischen 1 und 4 Repliken skalieren, mit einem Target von 50 % CPU-Auslastung. Scale-Up MUSS mit `stabilizationWindowSeconds: 0` und max. 50 % pro 15 s sofort reagieren; Scale-Down MUSS über ein 60 s Fenster gedrosselt werden (max. 25 %). |
| **[NFR-RES-002]** | **Startup-Puffer für Migrationen** | Die Startup-Probe des Moodle-Containers MUSS mit `failureThreshold: 120` bei `periodSeconds: 10` (ca. 20 Minuten Puffer) konfiguriert sein, um Liveness-Kills während umfangreicher Datenbank-Upgrades zu verhindern. |
| **[NFR-RES-003]** | **Pod Disruption Budget (PDB)** | Bei aktivierter Replikation MUSS ein PDB (`moodle.pdb.create: true`) verhindern, dass bei Cluster-Wartungen alle Moodle-Pods gleichzeitig evakuiert werden. |

### 4.4 Persistenz & Storage
| ID | Metrik / Ziel | Messmethode / Akzeptanzkriterium |
| :--- | :--- | :--- |
| **[NFR-STR-001]** | **Moodledata-Volume** | Ein ReadWriteMany PVC mit Standardgröße 8 Gi und StorageClass `nfs-client` MUSS für Moodledata vorhanden sein. |
| **[NFR-STR-002]** | **Datenverlustschutz** | Die Helm-Annotation `helm.sh/resource-policy: keep` MUSS auf den PVCs gesetzt sein. |

---

## 5. Explicit Out-of-Scope & Bekannte technische Limitationen (OOS)

> **Regel:** Alles in diesem Abschnitt ist **explizit von der Implementierung ausgeschlossen** oder dokumentiert eine harte technische Grenze der aktuellen Version. Die KI darf hierfür eigenmächtig keinen Workaround im Code bauen.

* **[OOS-001] Nicht gebundene Plugins (Known Limitation):** Die Schalter in `global.moodlePlugins` für `groupselect`, `jitsi`, `skype`, `reengagement`, `geogebra`, `flexsections`, `multitopic`, `saml2`, `dash`, `snap` und `customfield_dynamic` sind zwar im Schalterwerk vorhanden, es werden zur Build-Zeit jedoch **keine ZIP-Dateien** hierfür heruntergeladen. Ein Aktivieren zur Laufzeit schlägt fehl. Dies ist ein akzeptierter Zustand.
* **[OOS-002] Modul `mod_booking`:** Das Plugin `mod_booking` ist über keine zuverlässige Upstream-Quelle verfügbar. Die Download-Logik (`download_booking`) in `downloadPlugins.sh` MUSS auskommentiert bleiben. Es ist nicht Bestandteil der Distribution.
* **[OOS-003] Multi-Tenancy:** Das System wird ausschließlich als Single-Tenant-Instanz pro Helm-Release betrieben.
* **[OOS-004] Native Windows-Laufzeit:** Container werden ausschließlich auf Linux-x86_64/ARM64-Nodes getestet und unterstützt.

---

## 6. Laufzeit-Sequenz & Helm-Chart-Abhängigkeiten

### 6.1 Startup-Sequenz (PHP-FPM Entrypoint)
1. PHP-FPM konfigurieren und im Hintergrund starten (`phpSetup.sh`).
2. PostgreSQL-Client initialisieren (`postgresSetup.sh`).
3. Moodle-Version prüfen, bei Bedarf Upgrade durchführen (`updateCheck.sh`, Backup + `upgrade_if_pending`).
4. Datenbank-Setup und Initialisierung (`moodleSetup.sh`).
5. `config.php` anwenden.
6. Sprachpakete `de`/`en` aktualisieren.
7. Ausstehende DB-Migrationen ausführen.
8. Plugins installieren bzw. aktualisieren (`pluginCheck.sh`).
9. PHP-FPM im Vordergrund starten (`exec`).

### 6.2 Helm-Chart-Abhängigkeiten
| Chart (Alias) | Version | Quelle | Zweck |
| :--- | :--- | :--- | :--- |
| `moodle` | 27.0.5 | `file://charts/moodle` | Moodle-Kerndeployment |
| `redis` | 19.5.3 | bitnami | Session-Store (optional) |
| `postgresql` | 15.5.38 | bitnami | Primäre Datenbank (optional) |
| `postgresql` (`etherpad-postgresql`) | 15.5.38 | bitnami | Etherpad-Datenbank (optional) |
| `cronjob` (`moodlecronjob`) | 0.1.0 | `file://charts/cronjob` | Moodle cron.php |
| `cronjob` (`backup-cronjob`) | 0.1.0 | `file://charts/cronjob` | S3-Backup (optional) |
| `etherpad` (`etherpadlite`) | 0.1.0 | `file://charts/etherpad` | Etherpad-Lite (optional) |
| `clamav` | 3.5.0 | wiremind | Antivirenscanner (optional) |
| `sql-exporter` | 0.6.1 | burningalchemist | DB-Metriken (optional) |

---

## 7. Betriebs- & Release-Anforderungen

### 7.1 Monitoring & Health
* Liveness- und Readiness-Probes MÜSSEN in allen Deployment-Templates vorhanden sein.
* ClamAV MUSS Health-Checks für das Antivirenscanning bereitstellen.
* SQL-Exporter ist optional für Datenbankmetriken verfügbar.

### 7.2 Update-Strategie
* Pre-Update-Hook: Cron deaktivieren → Deployment herunterskalieren → Backup erstellen.
* Post-Update: Datenbankmigration → Deployment hochskalieren → Cron aktivieren.

### 7.3 Infrastruktur-Voraussetzungen
* Kubernetes-Cluster mit `ReadWriteMany`-Support (z. B. NFS-StorageClass `nfs-client`).
* Container Registry: GHCR (`ghcr.io/dbildungsplattform/moodle`).
* S3-kompatibler Speicher für Backups.
* Optional: Managed PostgreSQL und Redis.

### 7.4 CI/CD-Anforderungen
| Pipeline | Trigger | Zweck |
| :--- | :--- | :--- |
| `build-and-push-on-tag` | Tag `[0-9]+.[0-9]+.[0-9]+*` | Moodle-/Apache-Images nach GHCR publizieren |
| `moodle-tools-bap-on-tag` | Tag `moodle-tools-<semver>` | moodle-tools-Image nach GHCR publizieren |
| `test-docker-images` | Änderungen in `moodle/` oder `moodle-tools/` | Container-Structure-Tests |
| `test-helm-chart` | Helm-Chart-Änderungen | lint, unittest, Trivy-Scan |
| `test-helm-kind` | Helm-Chart-Änderungen | Integrationstests mit KinD |
| `helm-chart-release-on-push` | Push auf Branch ≠ `main` | Dev-Release des Helm-Charts |
| `helm-chart-release-on-tag` | Tag `dbp-moodle-<semver>` | Helm-Chart-Release |
| `generate-helm-docs-on-pr` | Pull Request | README.md aus Chart-Values generieren |
| `trivy-cron` | Täglich 02:00 UTC | Sicherheitsscan des gesamten Repos |
| `sync-oidc-plugin-repo` | Stündlich / manuell | OIDC-Plugin-Sync |

**Qualitätsgates:** HIGH/CRITICAL brechen den Build ab; MEDIUM/LOW werden als SARIF-Report hinterlegt.

---

## 8. Traceability- & Test-Matrix

| Anforderungs-ID | Relevanter Pfad im Repo | Test-Werkzeug / Pipeline-Job | Status |
| :--- | :--- | :--- | :--- |
| **[CON-SEC-001]** | `charts/dbp-moodle/templates/*` | `helm unittest` / `test-helm-chart.yaml` | VERIFIED |
| **[CON-SEC-003]** | `.github/workflows/sync-oidc-plugin-repo.yaml` | CI Sync-Log | VERIFIED |
| **[FR-CORE-001]** | `moodle/scripts/init/entrypoint.sh` | `container-structure-test` / KinD Test | VERIFIED |
| **[FR-PLG-001]** | `moodle/scripts/install/downloadPlugins.sh` | `test-docker-images.yaml` | VERIFIED |
| **[NFR-RES-002]** | `charts/dbp-moodle/values.yaml` | `helm lint` | VERIFIED |