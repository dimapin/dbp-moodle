#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
# set -o xtrace # Uncomment this line for debugging purposes

# Load libraries
. /scripts/liblog.sh
. /scripts/libapache.sh
. /scripts/libfs.sh

# Load Apache environment (defines APACHE_VHOSTS_DIR, PHP_FPM_HOST, PHP_FPM_PORT, ...)
. /scripts/init/apache/apache-env.sh

MODULE=apache info "Starting Apache setup"

# Re-render VirtualHost templates with runtime env vars (especially PHP_FPM_HOST and PHP_FPM_PORT).
# apacheInstall.sh already ran these at build time with empty PHP_FPM_* values;
# this overwrites those placeholders with the actual runtime values.
template_dir="/scripts/init/apache/templates"
ensure_dir_exists "${APACHE_VHOSTS_DIR}"
envsubst < "${template_dir}/default.conf.tpl"     > "${APACHE_VHOSTS_DIR}/default.conf"
envsubst < "${template_dir}/default-ssl.conf.tpl" > "${APACHE_VHOSTS_DIR}/default-ssl.conf"

# Generate SSL cert, configure ports and security settings
/scripts/init/apache/apacheSetup.sh

MODULE=apache info "Starting Apache (PHP-FPM backend: ${PHP_FPM_HOST}:${PHP_FPM_PORT})"
exec apache2ctl -f "${APACHE_CONF_FILE}" -D FOREGROUND
