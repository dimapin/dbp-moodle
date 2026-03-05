# dbp-moodle

Dieses Repository enthält die Docker-Images und den Helm-Chart für die dBildungsplattform-Moodle-Instanz.

## Komponenten

| Komponente | Pfad | Beschreibung |
|---|---|---|
| [**moodle**](moodle/README.md) | `moodle/` | Zwei Docker-Images: PHP-FPM+Moodle und Apache |
| [**moodle-tools**](moodle-tools/README.md) | `moodle-tools/` | Minimales Hilfsimage für Kubernetes-CronJobs (Backup, Restore) |
| [**dbp-moodle**](charts/dbp-moodle/README.md) | `charts/dbp-moodle/` | Helm-Chart zum Deployen einer vollständigen Moodle-Instanz |

## Docker-Images

Das `moodle/`-Verzeichnis enthält zwei Dockerfiles, die zusammen betrieben werden:

### `Dockerfile` — PHP-FPM + Moodle
- Base-Image: `php:8.2.30-fpm-bookworm`
- Enthält: Moodle-Quellcode, PHP-Extensions, Plugins, PostgreSQL-Client
- Führt beim Start alle Moodle-Initialisierungen durch (DB-Setup, Plugins, Updates)
- Startet PHP-FPM im Vordergrund auf Port `9000` (TCP)

### `Dockerfile.apache` — Apache Webserver
- Base-Image: `debian:bookworm-slim`
- Enthält: Apache2 mit SSL und `proxy_fcgi`
- Proxied PHP-Requests an den PHP-FPM-Container (`PHP_FPM_HOST:PHP_FPM_PORT`)
- Ports: `8080` (HTTP), `8443` (HTTPS)

Beide Container teilen sich das Moodle-Datenverzeichnis (`/dbp-moodle/moodle`) über ein gemeinsames Volume (ReadWriteMany).

## Helm-Chart

Der Chart `charts/dbp-moodle` deployt eine vollständige Moodle-Instanz auf Kubernetes mit:

- Moodle (PHP-FPM + Apache)
- PostgreSQL (Bitnami, optional durch managed DB ersetzbar)
- Redis (Session-Store, optional)
- Etherpad-Lite (Kollaboration, optional)
- ClamAV (Virenscanner, optional)
- CronJob für `cron.php`
- Backup-CronJob mit S3/duply

```bash
helm dependency update charts/dbp-moodle
helm install moodle charts/dbp-moodle --values my-values.yaml
```

Details: [charts/dbp-moodle/README.md](charts/dbp-moodle/README.md)
