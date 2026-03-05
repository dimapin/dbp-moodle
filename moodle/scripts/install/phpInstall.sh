#!/bin/bash
# Copyright Broadcom, Inc. All Rights Reserved.
# SPDX-License-Identifier: APACHE-2.0

# shellcheck disable=SC1091

set -o errexit
set -o nounset
set -o pipefail
# set -o xtrace # Uncomment this line for debugging purposes

# Load libraries
. /scripts/libphp.sh
. /scripts/libfile.sh
. /scripts/libos.sh

# Load PHP-FPM environment variables
. /scripts/init/php/php-env.sh

BUILD_PACKAGES="libcurl4-openssl-dev libfreetype6-dev libicu-dev libjpeg62-turbo-dev \
  libldap2-dev libmariadb-dev libmemcached-dev libpng-dev libpq-dev libxml2-dev libxslt-dev \
  uuid-dev libbz2-dev libzip-dev zlib1g-dev libgmp-dev libssl-dev libreadline-dev \
  libsqlite3-dev libtidy-dev libjpeg-dev libwebp-dev libxpm-dev pkg-config"

apt-get update && apt-get install -y --no-install-recommends $BUILD_PACKAGES

# ZIP
docker-php-ext-configure zip --with-zip
docker-php-ext-install zip

docker-php-ext-install -j$(nproc) \
    bcmath bz2 calendar exif gmp iconv intl ldap mysqli opcache pcntl pdo pdo_mysql pgsql soap sockets tidy xsl

# GD.
docker-php-ext-configure gd --with-freetype=/usr/include/ --with-jpeg=/usr/include/
docker-php-ext-install -j$(nproc) gd

# Cleanup after source build
apt-get remove --purge -y $BUILD_PACKAGES
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*

# Copy the production php.ini template as the default php.ini
cp "${PHP_CONF_DIR}/php.ini-production" "$PHP_CONF_FILE"

chmod -R g+w "$PHP_CONF_DIR"
# Fix logging issue when running as root
! am_i_root || chmod o+w "$(readlink /dev/stdout)" "$(readlink /dev/stderr)"
