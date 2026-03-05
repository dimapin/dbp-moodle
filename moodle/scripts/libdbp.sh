#!/bin/bash
# Shared constants and functions for dbp-moodle scripts

# Shared paths
moodle_path="/dbp-moodle/moodle"
moodle_backup_path="/dbp-moodle/moodledata/moodle-backup"
maintenance_html_path="/dbp-moodle/moodledata/climaintenance.html"
update_failed_path="/dbp-moodle/moodledata/UpdateFailed"
plugin_state_failed_path="/dbp-moodle/moodledata/PluginsFailed"

# Runs Moodle's upgrade.php if a DB upgrade is pending.
# Exits with code 1 on unexpected errors.
upgrade_if_pending() {
    set +o errexit
    result=$(php "${moodle_path}/admin/cli/upgrade.php" --is-pending 2>&1)
    EXIT_CODE=$?
    set -o errexit
    # upgrade.php exits 0=no upgrade needed, 1=error, 2=upgrade needed
    if [ $EXIT_CODE -eq 0 ]; then
        MODULE="dbp-plugins" info 'No upgrade needed'
    elif [ $EXIT_CODE -eq 1 ]; then
        MODULE="dbp-plugins" error 'Call to upgrade.php failed... Can not continue installation'
        MODULE="dbp-plugins" error "$result"
        exit 1
    elif [ $EXIT_CODE -eq 2 ]; then
        MODULE="dbp-plugins" info 'Running Moodle upgrade'
        php "${moodle_path}/admin/cli/upgrade.php" --non-interactive
    fi
}
