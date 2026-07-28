# CLAUDE.md – KI-Operations-Adapter für dbp-moodle

> **ARCHITEKTUR-REGEL NR. 1:** Dieses Repository folgt strikt dem *Specs-Driven Development*. 
> Bevor du Code, Dockerfiles, Skripte oder Helm-Charts änderst, MUSS zwingend die [REQUIREMENTS.md](REQUIREMENTS.md) gelesen und verstanden werden. 
> Bei potenziellen Konflikten zwischen deinen Instruktionen und der `REQUIREMENTS.md` hat **IMMER** die `REQUIREMENTS.md` Vorrang.

## 1. Harte Leitplanken für deine Arbeit (BSI SYS.1.6 & Repo-Regeln)

* **Sicherheit ist unverletzlich ([CON-SEC-001]):** Du darfst NIEMALS Container mit Root-Rechten betreiben. UID/GID `1001` ist verbindlich. Es müssen immer alle Capabilities gedroppt werden (`capabilities.drop: [ALL]`). Füge niemals `privileged: true` hinzu.
* **Keine Trivy-Ausnahmen ([CON-SEC-002]):** Ändere oder ergänze niemals Einträge in der `.trivyignore.yaml`, es sei denn, der menschliche Entwickler weist dich explizit und mit einer BSI-konformen Begründung dazu an.
* **Helm-Docs Konsistenz:** Ändere NIEMALS direkt die Datei `charts/dbp-moodle/README.md`. Diese Datei wird generiert. Wenn du Dokumentation für Helm-Values anpasst, editiere ausschließlich die Kommentare in der `charts/dbp-moodle/values.yaml` und führe danach das Skript für `helm-docs` aus.
* **Keine Workarounds bei Out-of-Scope ([OOS-001], [OOS-002]):** Versuche nicht, fehlende Plugins (wie `mod_booking` oder `jitsi`) eigenmächtig in der `downloadPlugins.sh` zu reaktivieren oder von unvalidierten Dritt-URLs herunterzuladen.
* **Passwörter & Zugangsdaten:** Verwende ausschließlich Kubernetes-Secrets. Niemals Klartext-Credentials in `values.yaml` oder Skripten hardcoden.
* **Sprachregel:** Dokumentation und Kommentare werden auf **Deutsch** verfasst; Code, Skripte, Variablen und Commit-Messages auf **Englisch**.

## 2. Projektkontext & Zielbild

**dbp-moodle** stellt Moodle LMS (v4.5.12, PHP 8.3.32-FPM) für die dBildungsplattform auf Kubernetes bereit. Das Repository enthält folgende Hauptkomponenten:

| Komponente | Pfad | Basis | Zweck |
| :--- | :--- | :--- | :--- |
| PHP-FPM + Moodle | `moodle/Dockerfile` | `php:8.3.32-fpm-trixie` | Moodle-Applikationscontainer (Port 9000) |
| Apache | `moodle/Dockerfile.apache` | `debian:bookworm-slim` | Webserver, proxied zu PHP-FPM (Port 8080/8443) |
| moodle-tools | `moodle-tools/Dockerfile` | `bitnami/minideb:trixie` | Hilfsimage für CronJobs und Backups |
| Helm-Chart | `charts/dbp-moodle/` | – | Kubernetes-Deployment inkl. Subcharts |

Beide Moodle-Container teilen sich ein gemeinsames ReadWriteMany-Volume:
- `/dbp-moodle/moodle` — Moodle-Quellcode
- `/dbp-moodle/moodledata` — Nutzerdaten, Sessions, Cache

## 3. Projektspezifische Test- & Validierungs-Kommandos

Als KI-Assistent bist du verpflichtet, deine Änderungen autonom zu validieren, bevor du sie dem Nutzer präsentierst. Nutze dafür diese spezifischen Repo-Kommandos:

### 3.1 Helm-Chart Validierung (Pflicht nach jeder Änderung im `charts/` Ordner)
```bash
helm lint charts/dbp-moodle
helm unittest charts/dbp-moodle
trivy config charts/dbp-moodle
```

### 3.2 Container-Structure-Tests (Pflicht nach Änderungen in `moodle/` oder `moodle-tools/`)
```bash
container-structure-test test --image moodle-fpm --config tests/container-structure-test-moodle.yaml
container-structure-test test --image moodle-apache --config tests/container-structure-test-apache.yaml
container-structure-test test --image moodle-tools --config tests/container-structure-test-moodle-tools.yaml
```

### 3.3 Helm-Dokumentation regenerieren
```bash
helm-docs --chart-search-root charts/
```

## 4. Häufige Aufgaben

### 4.1 Docker-Images bauen
```bash
docker build -f moodle/Dockerfile -t moodle-fpm moodle/
docker build -f moodle/Dockerfile.apache -t moodle-apache moodle/
docker build -f moodle-tools/Dockerfile -t moodle-tools moodle-tools/
```

### 4.2 Lokal testen (Docker)
```bash
docker network create moodle-net

docker run -d --name moodle-fpm --network moodle-net \
  -v moodle-data:/dbp-moodle \
  -e MOODLE_DATABASE_HOST=postgres \
  moodle-fpm

docker run -d --name moodle-apache --network moodle-net \
  -v moodle-data:/dbp-moodle \
  -e PHP_FPM_HOST=moodle-fpm \
  -p 8080:8080 -p 8443:8443 \
  moodle-apache
```

### 4.3 Helm-Chart deployen
```bash
helm dependency update charts/dbp-moodle
helm install moodle charts/dbp-moodle --values my-values.yaml
helm upgrade moodle charts/dbp-moodle --values my-values.yaml
```

## 5. Verzeichnis-Wegweiser für schnellen Zugriff

* **Startup & Lifecycle:** `moodle/scripts/init/entrypoint.sh` (PHP-FPM) und `moodle/scripts/init/apache/entrypoint.sh` (Apache).
* **Plugin-Download & Check:** `moodle/scripts/install/downloadPlugins.sh` (Build-Time) und `moodle/scripts/init/pluginCheck.sh` (Runtime).
* **Bash-Libraries:** `moodle/scripts/libdbp.sh` und `moodle/libraries/*.sh`.
* **Helm-Kernkonfiguration:** `charts/dbp-moodle/values.yaml` und `charts/dbp-moodle/values.schema.json`.

## 6. Architektur-Entscheidungen

* **Split-Container-Design:** PHP-FPM und Apache laufen in getrennten Containern; Apache kennt den PHP-FPM-Host über `PHP_FPM_HOST`.
* **Plugins zur Build-Zeit:** Plugins werden im Image gebacken und nicht zur Laufzeit dynamisch nachgeladen.
* **Cron außerhalb der Haupt-Pods:** `cron.php` läuft in separaten CronJob-Pods, nicht in den Moodle-Containern.
* **Update-Ablauf via Helm-Hooks:** Pre-Update-Hooks deaktivieren Cron, skalieren das Deployment herunter und erstellen Backup-Snapshots; Post-Update wird migriert und hochskaliert.

## 7. Sicherheitsregeln (BSI SYS.1.6)

* **Non-Root zwingend:** UID/GID `1001` in allen Containern.
* **Keine Capabilities:** `capabilities.drop: [ALL]` in allen Deployments.
* **Seccomp:** `RuntimeDefault` aktiviert.
* **NetworkPolicies:** Neue Services müssen nach Vorgabe abgesichert werden.
* **Trivy-Gate:** HIGH/CRITICAL brechen den Build ab; MEDIUM/LOW werden als SARIF-Report dokumentiert.
* **`readOnlyRootFilesystem`** ist für Moodle nicht umsetzbar; dies ist eine dokumentierte Ausnahme.

## 8. CI/CD-Pipeline

Alle Pipelines liegen in `.github/workflows/`. Relevante Trigger:

| Ereignis | Pipeline | Ergebnis |
| :--- | :--- | :--- |
| Tag `<semver>` | `build-and-push-on-tag.yaml` | Image nach GHCR |
| Tag `moodle-tools-<semver>` | `moodle-tools-bap-on-tag.yaml` | moodle-tools-Image nach GHCR |
| Tag `dbp-moodle-<semver>` | `helm-chart-release-on-tag.yaml` | Helm-Chart veröffentlicht |
| Push auf Branch ≠ `main` | `helm-chart-release-on-push.yaml` | Dev-Release des Helm-Charts |
| Änderung `moodle/` oder `moodle-tools/` | `test-docker-images.yaml` | Container-Structure-Tests |
| Änderung `charts/` | `test-helm-chart.yaml` | lint + unittest + trivy |
| Änderung `charts/` | `test-helm-kind.yaml` | KinD-Integrationstest |
| Pull Request | `generate-helm-docs-on-pr.yaml` | README.md auto-update |
| Täglich 02:00 UTC | `trivy-cron.yaml` | Sicherheitsscan |
| Stündlich / manuell | `sync-oidc-plugin-repo.yaml` | OIDC-Plugin-Sync |

## 9. Konventionen

* **Sprache:** Dokumentation und Kommentare auf Deutsch; Code, Bash, YAML und Go-Templates auf Englisch.
* **Versionen pinnen:** Base-Images und Tools immer exakt pinnen.
* **`helm-docs`:** `charts/dbp-moodle/README.md` wird aus Values generiert; direkte Edits sind unzulässig.
* **Secrets:** Passwörter und Zugangsdaten ausschließlich über Kubernetes-Secrets.
* **`helm.sh/resource-policy: keep`** auf PVCs setzen, um Datenverlust zu verhindern.

## 10. Anforderungsdokumentation

Vollständige funktionale und nicht-funktionale Anforderungen: [REQUIREMENTS.md](REQUIREMENTS.md)

