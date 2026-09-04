#!/bin/sh
# Push pfSense config to R730xd (SAS pool, dedicated pfsense/ folder).
# Remote side (pve-2) auto-prunes copies older than 30 days on receipt.
set -e
TS=$(date +%Y-%m-%d_%H%M%S)
TMP=/tmp/config-$TS.xml.gz
gzip -c /cf/conf/config.xml > $TMP
scp -O -i /root/.ssh/pfsense-backup -o StrictHostKeyChecking=accept-new $TMP root@10.57.57.250:config-$TS.xml.gz
rm -f $TMP
