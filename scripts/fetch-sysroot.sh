#!/usr/bin/env bash
# Fetch the C library for test images into sysroot/ (tools/add-glibc/fetch.sh,
# which says what and why). Does nothing if sysroot/ is complete.
set -euo pipefail
cd "$(dirname "$0")/.."
exec bash tools/add-glibc/fetch.sh sysroot
