#!/bin/bash
set -euo pipefail

curl -fsSL https://pecl.php.net/get/redis-6.0.2.tgz -o /tmp/redis-6.0.2.tgz
tar -xzf /tmp/redis-6.0.2.tgz -C /tmp
rm /tmp/redis-6.0.2.tgz
cd /tmp/redis-6.0.2
phpize
./configure
make
make install
cd /
rm -rf /tmp/redis-6.0.2
