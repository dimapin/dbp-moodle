# CLAUDE.md – dbp-moodle

Dieses Dokument gibt Claude Code den nötigen Kontext für die Arbeit in diesem Repository.

## Projektübersicht

**dbp-moodle** stellt Moodle LMS (v4.5.12, PHP 8.3.32-FPM) für die dBildungsplattform auf Kubernetes bereit.  
Chart-Version 1.6.2 · Helm ≥ 3.16.3 · Kubernetes ≥ 1.25 · Lizenz Apache-2.0.  
Das Repo enthält folgende Hauptkomponenten:

| Komponente | Pfad | Basis | Zweck |
|---|---|---|---|
| PHP-FPM + Moodle | `moodle/Dockerfile` | `php:8.3.32-fpm-trixie` | Moodle-Applikationscontainer (Port 9000) |
| Apache | `moodle/Dockerfile.apache` | `debian:bookworm-slim` (digest-gepinnt) | Webserver, proxied zu PHP-FPM (Port 8080/8443) |
| moodle-tools | `moodle-tools/Dockerfile` | `bitnami/minideb:trixie` (digest-gepinnt) | Hilfsimage für CronJobs (Backup, Restore), aktuell Tag `1.1.15` |
| Helm-Chart | `charts/dbp-moodle/` | – | Kubernetes-Deployment (inkl. Subcharts) |

> **Hinweis:** Seit Chart 1.6.0 laufen Moodle- und Tools-Image auf Debian 13 (Trixie). Das Apache-Image steht noch auf Debian 12 (Bookworm) und ist damit der letzte offene Punkt der Trixie-Migration.

Beide Moodle-Container teilen sich ein gemeinsames **ReadWriteMany**-Volume (StorageClass `nfs-client`, Standard 8 Gi):
- `/dbp-moodle/moodle` — Moodle-Quellcode
- `/dbp-moodle/moodledata` — Nutzerdaten, Sessions, Cache

## Häufige Aufgaben

### Docker-Images bauen

```bash
# PHP-FPM + Moodle
docker build -f moodle/Dockerfile -t moodle-fpm moodle/

# Apache
docker build -f moodle/Dockerfile.apache -t moodle-apache moodle/

# Tools-Image
docker build -f moodle-tools/Dockerfile -t moodle-tools moodle-tools/
```

### Lokal testen (Docker)

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

### Helm-Chart deployen

```bash
# Abhängigkeiten aktualisieren
helm dependency update charts/dbp-moodle

# Installieren
helm install moodle charts/dbp-moodle --values my-values.yaml

# Upgrade
helm upgrade moodle charts/dbp-moodle --values my-values.yaml
```

### Tests ausführen

```bash
# Helm lint
helm lint charts/dbp-moodle

# Helm Unit-Tests (BSI-Checks: SecurityContext, NetworkPolicy, RBAC, Ressourcelimits)
helm unittest charts/dbp-moodle

# Container-Structure-Tests (erfordert gebaute Images)
container-structure-test test --image moodle-fpm --config tests/container-structure-test-moodle.yaml
container-structure-test test --image moodle-apache --config tests/container-structure-test-apache.yaml
container-structure-test test --image moodle-tools --config tests/container-structure-test-moodle-tools.yaml

# Trivy-Konfigurationsscan
trivy config charts/dbp-moodle
```

### Helm-Docs regenerieren

```bash
helm-docs --chart-search-root charts/
```

## Wichtige Dateien

| Datei | Beschreibung |
|---|---|
| `moodle/scripts/install/downloadPlugins.sh` | Plugin-Download zur Build-Zeit |
| `moodle/scripts/init/entrypoint.sh` | Startup-Sequenz PHP-FPM-Container |
| `moodle/scripts/init/apache/entrypoint.sh` | Startup-Sequenz Apache-Container |
| `moodle/scripts/init/updateCheck.sh` | Moodle-Versionscheck beim Start |
| `moodle/scripts/init/pluginCheck.sh` | Plugin-Installations-/Update-Check |
| `moodle/scripts/libdbp.sh` | Projektspezifische Bash-Library |
| `moodle/libraries/` | Gemeinsame Bash-Libraries (`libmoodle.sh`, `libphp.sh`, ...) |
| `charts/dbp-moodle/values.yaml` | Alle Helm-Konfigurationswerte |
| `charts/dbp-moodle/values.schema.json` | JSON-Schema zur Values-Validierung |
| `charts/dbp-moodle/Chart.yaml` | Chart-Metadaten und Abhängigkeiten |
| `charts/dbp-moodle/CHANGELOG.md` | Chart-Änderungshistorie — bei jedem Release pflegen |
| `.trivyignore.yaml` | Dokumentierte BSI-Sicherheitsausnahmen mit Begründungen |
| `tests/kind-values.yaml` | Values für KinD-Integrationstests |

## Architektur-Entscheidungen

### Split-Container-Design
PHP-FPM und Apache laufen in **getrennten Containern**. Apache kennt den PHP-FPM-Host via `PHP_FPM_HOST`-Umgebungsvariable. Beide Container benötigen dasselbe Volume (`ReadWriteMany`).

### Plugins werden zur Build-Zeit installiert
Plugins werden in `downloadPlugins.sh` aus dem Moodle Marketplace heruntergeladen und ins Image gebacken — **nicht** zur Laufzeit. Reihenfolge ist abhängigkeitsgesteuert: `plugin_dependency_list` (z. B. `tool_certificate`, `qbehaviour_*`) wird vor `plugin_list` installiert. Plugin-Liste ist über `global.moodlePlugins` in den Helm-Values steuerbar.

`mod_booking` ist derzeit **nicht** im Image enthalten (über keine Bezugsquelle verfügbar, `download_booking` ist auskommentiert). `auth_oidc` wird als Sonderfall aus Branch `v_45` von `dBildungsplattform/dbp-moodle-plugin-oidc` gebaut.

### Cron läuft außerhalb der Haupt-Pods
`cron.php` wird in separaten **CronJob-Pods** ausgeführt, nicht innerhalb der Moodle-Container. Während Updates wird der Cron automatisch deaktiviert und danach reaktiviert.

### Update-Ablauf via Helm-Hooks
Pre-Update-Hook: Cron deaktivieren → Deployment herunterskalieren → Backup-Snapshot anlegen.  
Post-Update: Datenbankmigration → hochskalieren → Cron aktivieren.

## Sicherheitsregeln (BSI SYS.1.6)

- **Non-Root zwingend:** UID/GID 1001 in allen Containern
- **Keine Capabilities:** `capabilities.drop: [ALL]` in allen Deployments
- **Seccomp:** `RuntimeDefault` aktiviert
- **NetworkPolicies:** müssen für alle neuen Services angelegt werden
- **Trivy-Gate:** HIGH/CRITICAL bricht den Build ab (MEDIUM/LOW als SARIF-Report) — neue `.trivyignore.yaml`-Einträge brauchen eine BSI-konforme Begründung
- **`readOnlyRootFilesystem`** ist für Moodle nicht umsetzbar (dokumentierte Ausnahme KSV014/AVD-KSV-0014)
- **UID/GID 1001 statt > 10000** ist dokumentierte Ausnahme (KSV020/KSV021)

## CI/CD-Pipeline

Alle Pipelines liegen in `.github/workflows/`. Relevante Trigger:

| Ereignis | Pipeline | Ergebnis |
|---|---|---|
| Tag `<semver>` | `build-and-push-on-tag.yaml` | Image nach `ghcr.io/dbildungsplattform/moodle` |
| Tag `moodle-tools-<semver>` | `moodle-tools-bap-on-tag.yaml` | moodle-tools-Image nach GHCR |
| Tag `dbp-moodle-<semver>` | `helm-chart-release-on-tag.yaml` | Helm-Chart veröffentlicht |
| Push auf Branch ≠ `main` | `helm-chart-release-on-push.yaml` | Dev-Release des Helm-Charts |
| Änderung `moodle/` oder `moodle-tools/` | `test-docker-images.yaml` | Container-Structure-Tests (v1.19.3) |
| Änderung `charts/` | `test-helm-chart.yaml` | lint + unittest + trivy |
| Änderung `charts/` | `test-helm-kind.yaml` | KinD-Integrationstest |
| Pull Request | `generate-helm-docs-on-pr.yaml` | README.md auto-update |
| Täglich 02:00 UTC | `trivy-cron.yaml` | Sicherheitsscan des gesamten Repos |
| Stündlich / manuell | `sync-oidc-plugin-repo.yaml` | OIDC-Plugin-Sync |

## Konventionen

- **Sprache:** Dokumentation und Kommentare auf Deutsch; Code (Bash, YAML, Go-Templates) auf Englisch
- **Versionen pinnen:** Base-Images und Tools immer auf exakte Versionen pinnen (keine `latest`-Tags)
- **`helm-docs`:** `charts/dbp-moodle/README.md` wird aus Values generiert — direkte Edits werden überschrieben, stattdessen Kommentare in `values.yaml` anpassen
- **Secrets:** Passwörter und Zugangsdaten ausschließlich über Kubernetes-Secrets; keine Klartextwerte in Values
- **`helm.sh/resource-policy: keep`** auf PVCs setzen, um Datenverlust bei `helm uninstall` zu verhindern

## Anforderungsdokumentation

Vollständige funktionale und nicht-funktionale Anforderungen: [REQUIREMENTS.md](REQUIREMENTS.md)
