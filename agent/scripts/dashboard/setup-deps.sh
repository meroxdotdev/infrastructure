#!/bin/bash
# Install Python dependencies for dashboard scripts.
# Run once after fresh server install (as root or with sudo).

set -euo pipefail

pip3 install caldav --break-system-packages --quiet
echo "[setup-deps] caldav installed OK"
