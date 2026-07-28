#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ "${1:-}" == "-v" || "${1:-}" == "-V" || "${1:-}" == "--version" ]]; then
    echo "Server version: Apache/2.4 (dbp-moodle wrapper)"
    exit 0
fi

exec /usr/sbin/apache2ctl "$@"
