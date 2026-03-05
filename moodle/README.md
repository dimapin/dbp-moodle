# moodle

Zwei Docker-Images für den Split-Container-Betrieb von Moodle: ein PHP-FPM-Image mit Moodle-Logik und ein separates Apache-Image als Webserver.

## Images

### `Dockerfile` — PHP-FPM + Moodle

Base: `php:8.2.30-fpm-bookworm`

Enthält:
- Moodle (Version via `MOODLE_VERSION` Build-Arg, Default `4.5.8`)
- Alle PHP-Extensions (pgsql, gd, ldap, opcache, redis, ...)
- PostgreSQL-Client 13
- Plugins (via `downloadPlugins.sh`)
- Deutsche und englische Sprachpakete

**Startup-Ablauf:**
1. PHP-FPM konfigurieren und im Hintergrund starten
2. PostgreSQL-Client initialisieren
3. Moodle-Version prüfen, ggf. Update durchführen (inkl. Backup)
4. Moodle-Setup (DB-Initialisierung, Konfiguration)
5. `config.php` einspielen
6. Plugins installieren/aktualisieren
7. Background-PHP-FPM stoppen und im Vordergrund neu starten

**Port:** `9000` (PHP-FPM, TCP)

### `Dockerfile.apache` — Apache Webserver

Base: `debian:bookworm-slim`

Enthält:
- Apache 2.4 (gepinnter Debian-Snapshot, Version via `APACHE_VERSION`)
- Module: `proxy_fcgi`, `ssl`, `rewrite`, `deflate`, u.a.
- Selbstsigniertes SSL-Zertifikat (wird beim Start generiert, falls keines vorhanden)

**Startup-Ablauf:**
1. VirtualHost-Templates mit Laufzeit-Env-Variablen rendern (insb. `PHP_FPM_HOST`)
2. SSL-Zertifikat generieren (wenn nicht vorhanden)
3. Apache im Vordergrund starten

**Ports:** `8080` (HTTP), `8443` (HTTPS)

## Images bauen

```bash
# PHP-FPM + Moodle
docker build -f Dockerfile -t moodle-fpm .

# Apache
docker build -f Dockerfile.apache -t moodle-apache .
```

### Build-Argumente

| Argument | Default | Beschreibung |
|---|---|---|
| `MOODLE_VERSION` | `4.5.8` | Moodle-Version |
| `APACHE_VERSION` | `2.4.66-1~deb12u1` | Apache-Version (Debian-Snapshot) |
| `APACHE_DOWNLOAD_URL` | Debian-Snapshot-URL | Quelle für Apache-Pakete |
| `EXTRA_LOCALES` | `` | Zusätzliche Locales |
| `WITH_ALL_LOCALES` | `no` | Alle Locales aktivieren |

## Betrieb

### Gemeinsames Volume

Beide Container benötigen das Moodle-Datenverzeichnis als **ReadWriteMany**-Volume:

| Pfad | Inhalt |
|---|---|
| `/dbp-moodle/moodle` | Moodle-Quellcode (PHP-FPM schreibt, Apache liest statische Assets) |
| `/dbp-moodle/moodledata` | Moodle-Dateiablage, Sessions, Cache |

### Umgebungsvariablen (Auswahl)

**PHP-FPM + Moodle:**

| Variable | Default | Beschreibung |
|---|---|---|
| `MOODLE_DATABASE_HOST` | `moodle-postgres` | PostgreSQL-Host |
| `MOODLE_DATABASE_NAME` | `moodle` | Datenbankname |
| `MOODLE_DATABASE_USER` | `moodle` | Datenbanknutzer |
| `MOODLE_DATABASE_PASSWORD` | – | Datenbankpasswort |
| `MOODLE_PLUGINS` | – | Plugin-Liste im Format `name:fullname:path:state` |
| `PHP_FPM_LISTEN_ADDRESS` | `0.0.0.0:9000` | PHP-FPM Listenaddresse |
| `PHP_MEMORY_LIMIT` | `256M` | PHP-Speicherlimit |

**Apache:**

| Variable | Default | Beschreibung |
|---|---|---|
| `PHP_FPM_HOST` | `moodle-fpm` | Hostname des PHP-FPM-Containers |
| `PHP_FPM_PORT` | `9000` | Port des PHP-FPM-Containers |
| `APACHE_HTTP_PORT_NUMBER` | `8080` | HTTP-Port |
| `APACHE_HTTPS_PORT_NUMBER` | `8443` | HTTPS-Port |

### Lokaler Testbetrieb

```bash
docker network create moodle-net

# PHP-FPM + Moodle
docker run -d --name moodle-fpm --network moodle-net \
  -v moodle-data:/dbp-moodle \
  -e MOODLE_DATABASE_HOST=postgres \
  moodle-fpm

# Apache
docker run -d --name moodle-apache --network moodle-net \
  -v moodle-data:/dbp-moodle \
  -e PHP_FPM_HOST=moodle-fpm \
  -p 8080:8080 -p 8443:8443 \
  moodle-apache
```

## Skripte und Libraries

```
scripts/
├── install/          # Build-Zeit: PHP-Extensions, Apache, Moodle, Plugins herunterladen
├── init/
│   ├── apache/       # Apache-Konfiguration (apacheSetup.sh, Templates, Entrypoint)
│   ├── php/          # PHP-FPM-Konfiguration
│   ├── moodle/       # Moodle-Setup
│   ├── postgres/     # PostgreSQL-Client-Setup
│   ├── entrypoint.sh # PHP-FPM-Container-Entrypoint
│   ├── updateCheck.sh
│   └── pluginCheck.sh
libraries/            # Gemeinsame Bash-Bibliotheken (libapache.sh, libmoodle.sh, ...)
```
