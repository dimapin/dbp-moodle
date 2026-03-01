#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
# set -o xtrace # Uncomment this line for debugging purposes

# Load Moodle environment
. /scripts/init/moodle/moodle-env.sh

# Load libraries
. /scripts/liblog.sh
. /scripts/libwebserver.sh
. /scripts/libdbp.sh

# Load PHP environment (provides PHP_FPM_PID_FILE and PHP_FPM_CONF_FILE)
. /scripts/init/php/php-env.sh

update_in_progress_path="/dbp-moodle/moodledata/UpdateInProgress"

printSystemStatus() {
    if [[ -e $maintenance_html_path ]]; then
        MODULE=dbp warn "climaintenance.html file exists."
    fi
    if [[ -e $update_in_progress_path ]]; then
        MODULE=dbp warn "UpdateInProgress file exists."
    fi
    if [[ -e $update_failed_path ]]; then
        MODULE=dbp error "UpdateFailed file exists!"
    fi
    if [[ -e $plugin_state_failed_path ]]; then
        MODULE=dbp error "PluginsFailed file exists!"
    fi
}

startDbpMoodleSetup() {
    info "Starting dbp Moodle setup"
    /scripts/init/php/phpSetup.sh
    /scripts/init/postgres/postgresSetup.sh
    MODULE=dbp info "Initial Moodle setup finished"
}

MODULE=dbp info "Starting Moodle"

# Copy the dbp-php.ini to the conf.d directory to set new settings
cp /scripts/init/php/dbp-php.ini /usr/local/etc/php/conf.d/00-dbp-php.ini
cp /moodleconfig/01-dbp-php.ini /usr/local/etc/php/conf.d/01-dbp-php.ini

# Start the dbp Moodle dependency setup process
startDbpMoodleSetup

if [[ ! -f "$update_failed_path" ]]; then
    # At this point in time we did not enter the Moodle persist step yet and /opt/dbp-moodle/moodle contains the moodle image version which in case of the update, is the new moodle version
    MODULE=dbp info "Starting Moodle Update Check"
    if /scripts/init/updateCheck.sh; then
        MODULE=dbp info "Finished Update Check"
    else
        MODULE=dbp error "Update failed! Continuing with previously installed moodle.."
        touch "$update_failed_path"
    fi
else
    MODULE=dbp warn "Update failed previously. Skipping update check..."
fi


MODULE=dbp info "Start Moodle setup script after checking for proper version"
/scripts/init/moodle/moodleSetup.sh

MODULE=dbp info "Replacing config.php file with ours"
/bin/cp -p /moodleconfig/config-php/config.php /tmp/config.php
mv /tmp/config.php /dbp-moodle/moodle/config.php

if [ -f "/tmp/de.zip" ] || [ -f "/tmp/en.zip" ]; then
    mkdir -p /dbp-moodle/moodledata/lang
    if [ -d /dbp-moodle/moodledata/lang/de ]; then
        MODULE=dbp info "Update german language pack"
        rm -r /dbp-moodle/moodledata/lang/de
        unzip -q /tmp/de.zip -d /dbp-moodle/moodledata/lang
    fi
    if [ -d /dbp-moodle/moodledata/lang/en ]; then
        MODULE=dbp info "Update english language pack"
        rm -r /dbp-moodle/moodledata/lang/en
        unzip -q /tmp/en.zip -d /dbp-moodle/moodledata/lang
    fi
fi

upgrade_if_pending

if [[ ! -f "$update_failed_path" ]] && [[ ! -f "$plugin_state_failed_path" ]]; then
    MODULE=dbp info "Starting plugin installation"
    if /scripts/init/pluginCheck.sh; then
        MODULE=dbp info "Finished Plugin Install"
    else
        MODULE=dbp error "Plugin check failed! Continuing to start webserver with possibly compromised plugins"
        touch "$plugin_state_failed_path"
    fi
else
    MODULE=dbp warn "Update or Plugin check failed previously. Skipping plugin check..."
fi

MODULE=dbp info "Finished all preparations! Starting PHP-FPM in foreground"

# Stop background PHP-FPM (started during setup by phpSetup.sh) before taking over in foreground
if [ -f "$PHP_FPM_PID_FILE" ]; then
    kill "$(cat "$PHP_FPM_PID_FILE")" 2>/dev/null || true
    wait 2>/dev/null || true
fi

exec php-fpm -F --pid "$PHP_FPM_PID_FILE" -y "$PHP_FPM_CONF_FILE"