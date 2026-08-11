#!/bin/bash
set -euo pipefail
curl -fsS -m 10 --retry 3 -o /dev/null "https://hc-ping.com/REPLACE-ME-SEE-PRIVATE-NOTES"
