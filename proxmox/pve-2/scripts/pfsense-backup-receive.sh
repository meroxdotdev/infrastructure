#!/bin/sh
/usr/bin/scp -t /media/backups/pfsense/
find /media/backups/pfsense -name 'config-*.xml.gz' -mtime +30 -delete
